//! Cross-package integration tests for the OS boundary.
//!
//! These tests live outside every library module on purpose: they import `z_ts`,
//! `zts_tauri`, `zts_webview`, `zts_tauri_native` and `zts_runtime_native` together, which is the
//! exact composition an application performs. The old test graph compiled each module in its own
//! target, so it could not see that `zts_tauri_native` re-owned `zts_tauri` files (Zig rejects
//! that as "file exists in modules ...").
//!
//! Tests that need a display skip cleanly (`DisplayUnavailable`) so Linux developers without X11
//! still get the compile-time and headless half.

const std = @import("std");
const testing = std.testing;

const zts = @import("z_ts");
const core = @import("zts_core");
const tauri = @import("zts_tauri");
const webview = @import("zts_webview");
const native = @import("zts_tauri_native");
const runtime_native = @import("zts_runtime_native");

test "1. headless composition: NativeRuntime installs vtables and fails closed without a native handle" {
    const rt = try zts.DesktopRuntime.create(testing.allocator, testing.io, .{
        .backend = .headless_mock,
        .app = .{ .name = "boundary", .identifier = "jp.zts.boundary" },
    });
    defer rt.destroy();

    var native_rt: runtime_native.NativeRuntime = undefined;
    native_rt.init(rt);
    defer native_rt.deinit();

    try testing.expectEqual(native.menuBackend().vtable, rt.plugins.menu_state.backend.vtable);
    try testing.expectEqual(native.trayBackend().vtable, rt.plugins.tray_state.backend.vtable);
    try testing.expectEqual(native.dialogBackend().vtable, native_rt.dialog_state.backend.vtable);
    try testing.expectEqual(native.clipboardBackend().vtable, native_rt.clipboard_state.backend.vtable);

    const win = try native_rt.openWindow(.{ .label = "main", .initial_url = "about:blank" });
    // HeadlessMock has no OS handle, so menu registration must fail without failing the window.
    try testing.expectEqual(@as(usize, 0), native_rt.registeredCount());
    try testing.expectEqual(@as(usize, 1), native_rt.menu_failures);

    try native_rt.closeWindow(win);
}

test "2. native composition: a window is registered, its menu attaches, and close unregisters it" {
    // The Arena sysroot ships a WebKit that cannot spawn `WebKitNetworkProcess` under Xvfb
    // (permission denied), and the abort is not catchable. CI uses the system WebKit and must
    // NOT set this variable; the guard exists only for restricted local sandboxes.
    if (std.c.getenv("ZTS_SKIP_NATIVE_WEBKIT") != null) return error.SkipZigTest;

    const rt = zts.DesktopRuntime.create(testing.allocator, testing.io, .{
        .backend = .native,
        .app = .{ .name = "boundary", .identifier = "jp.zts.boundary" },
    }) catch |err| switch (err) {
        // `.native` with `-Dgtk=false` has no backend at all; a headless session has no display.
        error.DisplayUnavailable, error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer rt.destroy();
    defer native.resetForTesting();

    var native_rt: runtime_native.NativeRuntime = undefined;
    native_rt.init(rt);
    defer native_rt.deinit();

    const win = try native_rt.openWindow(.{
        .label = "main",
        .initial_url = "", // blank: no navigation, hence no WebKit network process
        .size = .wh(320, 200),
        .visible = true,
    });
    try testing.expectEqual(@as(usize, 1), native_rt.registeredCount());

    const snapshot = tauri.menu.Snapshot{ .entries = &.{
        .{ .kind = .submenu, .id = "file", .text = "_File", .depth = 0 },
        .{ .kind = .item, .id = "quit", .text = "E_xit", .depth = 1 },
    } };
    try native.menuBackend().applyWindowMenu("main", snapshot);

    // GTK keeps the bar as a widget packed into `GtkWindow → GtkBox`; Cocoa/Win32 install the
    // menu on the NSWindow/HWND and expose no comparable handle.
    if (webview.has_native_gtk) {
        try testing.expect(native.menuBarFor("main") != null);
    }

    try native_rt.closeWindow(win);
    try testing.expectEqual(@as(usize, 0), native_rt.registeredCount());
    // Programmatic close must reach `DesktopRuntime.onWindowClosed` on every backend; otherwise
    // `WindowRegistry` and the native menu registry keep a dead window (the pre-fix GTK/macOS
    // behaviour).
    try testing.expect(rt.plugins.windows.resolveId("main", core.WindowId.invalid) == null);
}

test "3. native tray: a rejected menu does not leave a half-registered icon behind" {
    const bad = tauri.menu.Snapshot{
        .entries = &.{
            // depth 1 without a parent submenu: every backend rejects this snapshot.
            .{ .kind = .item, .id = "x", .text = "X", .depth = 1 },
        },
    };

    // Give the tray a real PNG instead of the platform placeholder. A minimal sysroot without
    // the Adwaita icon cache otherwise makes GTK abort while resolving "image-missing".
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const png_bytes = try webview.png.testImage(testing.allocator, 16, 16);
    defer testing.allocator.free(png_bytes);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tray.png", .data = png_bytes });
    const icon_path = try tmp.dir.realPathFileAlloc(testing.io, "tray.png", testing.allocator);
    defer testing.allocator.free(icon_path);
    const options = tauri.tray.TrayIconOptions{ .icon = .{ .image = .{ .path = icon_path } } };

    var backend = native.trayBackend();
    backend.create("zts-boundary-tray", options, bad) catch |err| switch (err) {
        error.Unavailable => return error.SkipZigTest, // stub backend or no display
        error.Failed, error.OutOfMemory => {
            try testing.expect(!native.trayPresent("zts-boundary-tray"));
            native.resetForTesting();
            return;
        },
        else => return err,
    };

    // If a backend ever accepts the invalid snapshot, clean up and fail loudly.
    backend.remove("zts-boundary-tray") catch {};
    native.resetForTesting();
    return error.TestUnexpectedResult;
}
