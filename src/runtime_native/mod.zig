//! `zts_runtime_native` — the optional bridge between `z_ts.DesktopRuntime` and the OS backends.
//!
//! `z_ts` deliberately has **zero** GTK / Cocoa / Win32 imports: an app that only needs the
//! headless mock, the HTTP bridge or a WASM build must not link a desktop toolkit. The native
//! implementations therefore live in `zts_tauri_native`, and this package is the only place that
//! puts them together with `DesktopRuntime`:
//!
//! ```zig
//! const rt = try zts.DesktopRuntime.create(alloc, io, .{ .backend = .native, ... });
//! defer rt.destroy();
//!
//! var native_rt: zts_runtime_native.NativeRuntime = undefined;
//! native_rt.init(rt);                 // installs menu/tray + dialog/clipboard backends
//! defer native_rt.deinit();           // unregisters menu windows before the engine goes away
//!
//! const win = try rt.openWindow(.{ .label = "main", .initial_url = "tauri://localhost/" });
//! // The window observer registered `main` with the native menu backend automatically.
//! ```
//!
//! `DesktopRuntime` calls `WindowObserver.onOpen` for every window (including the ones created
//! from JavaScript through `plugin:window|create`), so no application-level label bookkeeping is
//! needed. `NativeRuntime.closeWindow()` unregisters the menu before closing; `deinit()` does the
//! same for every window it still knows about.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zts = @import("z_ts");
const core = @import("zts_core");
const rpc = @import("zts_rpc");
const tauri = @import("zts_tauri");
const native = @import("zts_tauri_native");

/// `@tauri-apps/plugin-dialog` / `plugin-clipboard-manager` command namespaces, ready to merge
/// into the application schema.
///
/// ```zig
/// const Full = zts_runtime_native.withNativePlugins(MySchema);
/// ```
pub const PluginSchema = rpc.Schema(.{
    .dialog = tauri.dialog.Commands,
    .clipboard = tauri.clipboard.Commands,
});

/// Merges `app` with the native dialog/clipboard namespaces and the Tauri core plugins.
///
/// `app` may be a `rpc.Schema(...)` type or a struct literal (`.{ .ns = Cmds }`), matching
/// `tauri.withCorePlugins`.
pub fn withNativePlugins(comptime app: anytype) type {
    if (@TypeOf(app) == type) {
        return tauri.withCorePlugins(rpc.merge(.{ app, PluginSchema }));
    }
    return tauri.withCorePlugins(rpc.merge(.{ rpc.Schema(app), PluginSchema }));
}

/// A `DesktopRuntime` with the native backends installed and window lifecycle wired.
pub const NativeRuntime = struct {
    /// The runtime this wrapper is attached to. It must outlive `self`.
    rt: *zts.DesktopRuntime,
    /// Allocator that owns `menu_windows` keys (the runtime's allocator).
    allocator: Allocator,
    /// State for `plugin:dialog|*` (`tauri.dialog.Commands`).
    dialog_state: tauri.dialog.DialogState,
    /// State for `plugin:clipboard-manager|*` (`tauri.clipboard.Commands`).
    clipboard_state: tauri.clipboard.ClipboardState,
    /// label → window id for every window registered with the native menu backend.
    menu_windows: std.StringHashMapUnmanaged(core.WindowId) = .empty,
    /// Successful registrations (introspection; the integration test asserts it).
    menu_registrations: usize = 0,
    /// Windows that could not be registered (stub backend, no display, embedded widget, …).
    menu_failures: usize = 0,

    /// Installs the native backends and starts observing windows.
    ///
    /// Call this **after** `DesktopRuntime.create()` and **before** opening windows. Windows that
    /// already exist can be registered explicitly with `registerWindow()`.
    pub fn init(self: *NativeRuntime, rt: *zts.DesktopRuntime) void {
        self.* = .{
            .rt = rt,
            .allocator = rt.allocator,
            .dialog_state = tauri.dialog.DialogState.init(rt.allocator, rt.io, native.dialogBackend()),
            .clipboard_state = tauri.clipboard.ClipboardState.init(rt.allocator, native.clipboardBackend()),
        };
        _ = rt.plugins.withMenuBackend(native.menuBackend());
        _ = rt.plugins.withTrayBackend(native.trayBackend());
        rt.setWindowObserver(.{
            .ctx = self,
            .onOpen = onOpen,
            .onClose = onClose,
        });
    }

    /// Detaches the observer and unregisters every menu window this wrapper registered.
    ///
    /// Call before `rt.destroy()` (or after it: unregistering only forgets labels, it never
    /// re-enters the destroyed toolkit).
    pub fn deinit(self: *NativeRuntime) void {
        self.rt.setWindowObserver(.{});
        var it = self.menu_windows.iterator();
        while (it.next()) |entry| {
            native.unregisterMenuWindow(entry.key_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.menu_windows.deinit(self.allocator);
        self.menu_windows = .empty;
    }

    /// Opens a window through the runtime; the observer registers it for menus.
    pub fn openWindow(self: *NativeRuntime, spec: core.WindowSpec) !core.WindowId {
        return self.rt.openWindow(spec);
    }

    /// Registers an already-open window (for windows created before `init()`).
    pub fn registerWindow(self: *NativeRuntime, label: []const u8, id: core.WindowId) bool {
        return self.register(label, id);
    }

    /// Unregisters the menu and closes the window.
    pub fn closeWindow(self: *NativeRuntime, id: core.WindowId) core.HostError!void {
        self.forgetWindow(id);
        return self.rt.host().closeWindow(id);
    }

    /// How many windows currently have a native menu registration.
    pub fn registeredCount(self: *const NativeRuntime) usize {
        return self.menu_windows.count();
    }

    fn register(self: *NativeRuntime, label: []const u8, id: core.WindowId) bool {
        // Window labels are unique in `WindowRegistry`; a duplicate here would leak the old key
        // (StringHashMap keeps the first key on overwrite).
        if (self.menu_windows.get(label) != null) {
            self.menu_failures += 1;
            return false;
        }
        const handle = self.rt.engine.nativeHandle(id) orelse {
            self.menu_failures += 1;
            return false;
        };
        if (!native.registerMenuWindow(label, handle)) {
            self.menu_failures += 1;
            return false;
        }
        const key = self.allocator.dupe(u8, label) catch {
            native.unregisterMenuWindow(label);
            self.menu_failures += 1;
            return false;
        };
        self.menu_windows.put(self.allocator, key, id) catch {
            self.allocator.free(key);
            native.unregisterMenuWindow(label);
            self.menu_failures += 1;
            return false;
        };
        self.menu_registrations += 1;
        return true;
    }

    fn forgetWindow(self: *NativeRuntime, id: core.WindowId) void {
        var found: ?[]const u8 = null;
        var it = self.menu_windows.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.eql(id)) {
                found = entry.key_ptr.*;
                break;
            }
        }
        const label = found orelse return;
        _ = self.menu_windows.fetchRemove(label);
        native.unregisterMenuWindow(label);
        self.allocator.free(label);
    }

    fn onOpen(ctx: ?*anyopaque, id: core.WindowId, spec: core.WindowSpec) void {
        const self: *NativeRuntime = @ptrCast(@alignCast(ctx orelse return));
        _ = self.register(spec.label, id);
    }

    fn onClose(ctx: ?*anyopaque, id: core.WindowId) void {
        const self: *NativeRuntime = @ptrCast(@alignCast(ctx orelse return));
        self.forgetWindow(id);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "NativeRuntime installs the native vtables on a headless runtime" {
    const rt = try zts.DesktopRuntime.create(testing.allocator, testing.io, .{
        .backend = .headless_mock,
        .app = .{ .name = "boundary", .identifier = "jp.zts.boundary" },
    });
    defer rt.destroy();

    var native_rt: NativeRuntime = undefined;
    native_rt.init(rt);
    defer native_rt.deinit();

    try testing.expectEqual(native.menuBackend().vtable, rt.plugins.menu_state.backend.vtable);
    try testing.expectEqual(native.trayBackend().vtable, rt.plugins.tray_state.backend.vtable);

    // The headless engine has no native handle: the window still opens, but there is no menu.
    const win = try native_rt.openWindow(.{ .label = "main" });
    try testing.expectEqual(@as(usize, 0), native_rt.registeredCount());
    try testing.expectEqual(@as(usize, 1), native_rt.menu_failures);

    try native_rt.closeWindow(win);
}
