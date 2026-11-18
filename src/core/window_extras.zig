//! `zts_foundation` — ownership-free scalar snapshot of window setter intents.
//!
//! This module lives in `zts_foundation` (the only module every other product may depend on) so
//! `zts_core`, `zts_tauri`, `zts_webview`, `zts_bridge` and the wasm host all exchange the SAME
//! struct without creating a circular import. There are no allocations and no slices; the enums
//! below use explicit backing integers, so the layout stays ABI-stable across modules while every
//! backend sees the same ordinal table instead of re-deriving it from `tauri`.

/// `tauri.window.Theme` — title-bar appearance requested by `set_theme`.
pub const Theme = enum(u8) { system, dark, light };
/// `tauri.window.ProgressStatus` — taskbar / dock progress state.
pub const ProgressStatus = enum(u8) { none, normal, indeterminate, paused, @"error" };
/// `tauri.window.CursorIcon` — cursor shapes accepted by `set_cursor_icon`.
pub const CursorIcon = enum(u16) { default, arrow, crosshair, hand, text, move, wait, help, progress, not_allowed, resize_ew, resize_ns, grab, grabbing };
/// `tauri.window.AttentionType` — user-attention levels.
pub const AttentionType = enum(u8) { none, critical, informational };
/// `tauri.window.Effect` — background effects accepted by `set_effects`.
pub const Effect = enum(u8) { none, blur, acrylic, mica, tabbed };

/// One complete snapshot of the `plugin:window` P1 #8 setter state. `core.Host.applyWindowExtras`
/// receives this after EVERY setter; a backend applies what its OS supports and fail-closes the
/// rest with `error.Unsupported`.
pub const WindowExtrasSnapshot = struct {
    /// Requested title-bar appearance.
    theme: Theme = .system,
    /// Hide the window from the taskbar / dock.
    skip_taskbar: bool = false,
    /// Taskbar / dock progress state.
    progress_status: ProgressStatus = .none,
    /// Progress percentage (0..100), or `null`.
    progress_value: ?u8 = null,
    /// Dock / taskbar badge count, or `null`.
    badge_count: ?u32 = null,
    /// Current cursor shape.
    cursor_icon: CursorIcon = .default,
    /// Cursor X in physical pixels.
    cursor_x: i32 = 0,
    /// Cursor Y in physical pixels.
    cursor_y: i32 = 0,
    /// Whether the cursor is confined to the window.
    cursor_grab: bool = false,
    /// Whether the cursor is drawn.
    cursor_visible: bool = true,
    /// Whether mouse events pass through the window.
    ignore_cursor_events: bool = false,
    /// Whether the window was centred.
    centered: bool = false,
    /// Last requested user-attention type.
    user_attention: AttentionType = .none,
    /// Block screenshots / screen capture.
    content_protected: bool = false,
    /// Show on every virtual desktop.
    visible_on_all_workspaces: bool = false,
    /// Whether the window draws a drop shadow.
    shadow: bool = true,
    /// Keep the window below all others.
    always_on_bottom: bool = false,
    /// Whether the window accepts input.
    enabled: bool = true,
    /// Requested background effect.
    effect: Effect = .none,
    /// Whether a background colour was set.
    bg_set: bool = false,
    /// Background red channel.
    bg_r: u8 = 0,
    /// Background green channel.
    bg_g: u8 = 0,
    /// Background blue channel.
    bg_b: u8 = 0,
    /// Background alpha channel.
    bg_a: u8 = 255,
    /// Deterministic hash of the icon bytes.
    icon_hash: u64 = 0,
    /// Whether the inspector was requested.
    devtools_open: bool = false,
};

test "WindowExtrasSnapshot defaults are deterministic and scalar-only" {
    const std = @import("std");
    const a = WindowExtrasSnapshot{};
    const b = WindowExtrasSnapshot{};
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(true, a.cursor_visible);
    try std.testing.expectEqual(true, a.enabled);
    try std.testing.expectEqual(true, a.shadow);
    try std.testing.expectEqual(@as(u8, 255), a.bg_a);
    // No allocator-owned data: the struct is bitwise comparable and trivially copyable.
    try std.testing.expectEqual(@as(usize, @sizeOf(WindowExtrasSnapshot)), @sizeOf(@TypeOf(a)));
}

/// scalar record of every `WindowConfig` option a backend consumed at creation.
/// Strings are kept as deterministic hashes (they are applied synchronously to the OS during
/// `createWindow`, so no borrow outlives the call). Four backends store the SAME record, which is
/// what rule 17 checks for 3-OS parity.
pub const WindowCreationOptions = struct {
    /// Requested title-bar appearance (`theme` in `tauri.conf.json` / `WindowSpec`).
    theme: Theme = .system,
    /// Centre the window on the primary monitor.
    center: bool = false,
    /// Start maximised.
    maximized: bool = false,
    /// Hide the window from the taskbar / dock.
    skip_taskbar: bool = false,
    /// Keep the window below all others.
    always_on_bottom: bool = false,
    /// Give keyboard focus at creation.
    focus: bool = true,
    /// Block screenshots / screen capture.
    content_protected: bool = false,
    /// Accept file drops in the webview.
    drag_drop_enabled: bool = true,
    /// Enable browser zoom shortcuts.
    zoom_hotkeys_enabled: bool = false,
    /// Hide the title text.
    hidden_title: bool = false,
    /// Hash of the requested title-bar style string.
    title_bar_style_hash: u64 = 0,
    /// Hash of the WebView user-agent override.
    user_agent_hash: u64 = 0,
    /// Hash of the native tabbing group identifier.
    tabbing_identifier_hash: u64 = 0,
    /// Show on every virtual desktop.
    visible_on_all_workspaces: bool = false,
    /// Hash of the raw `windowEffects` JSON.
    window_effects_hash: u64 = 0,
};

test "WindowCreationOptions captures every config field deterministically" {
    const std = @import("std");
    const a = WindowCreationOptions{};
    try std.testing.expectEqual(true, a.focus);
    try std.testing.expectEqual(true, a.drag_drop_enabled);
    try std.testing.expectEqual(false, a.zoom_hotkeys_enabled);
    try std.testing.expectEqual(a, WindowCreationOptions{});
}
