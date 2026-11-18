//! Windows native clipboard via the Win32 clipboard API
//! (`OpenClipboard` / `GetClipboardData` / `SetClipboardData`, `CF_UNICODETEXT`).
//!
//! `write_secret` additionally sets the `ExcludeClipboardContentFromMonitorProcessing` and
//! `CanIncludeInClipboardHistory = 0` formats so Windows 10+ clipboard history skips the payload.

const std = @import("std");
const cstr = @import("../native_cstr.zig");
const Allocator = std.mem.Allocator;

const clipboard = @import("zts_tauri").clipboard;
const win = @import("../native_win32.zig");

const Error = clipboard.ClipboardError;

const CALL: std.builtin.CallingConvention = .winapi;
const HANDLE = ?*anyopaque;
const HWND = ?*anyopaque;
const BOOL = c_int;

const CF_UNICODETEXT: u32 = 13;
const GMEM_MOVEABLE: u32 = 0x0002;
/// Synthetic format registered by name; returns the atom (`0` on failure).
const EXCLUDE_MONITOR_TARGET = "ExcludeClipboardContentFromMonitorProcessing";
const CAN_INCLUDE_HISTORY = "CanIncludeInClipboardHistory";

extern "c" fn OpenClipboard(hwnd: HWND) BOOL;
extern "c" fn CloseClipboard() BOOL;
extern "c" fn EmptyClipboard() BOOL;
extern "c" fn GetClipboardData(format: u32) HANDLE;
extern "c" fn SetClipboardData(format: u32, mem: HANDLE) HANDLE;
extern "c" fn RegisterClipboardFormatW(name: [*:0]const u16) u32;
extern "c" fn GlobalAlloc(flags: u32, bytes: usize) HANDLE;
extern "c" fn GlobalSize(mem: HANDLE) usize;
extern "c" fn GlobalLock(mem: HANDLE) ?*anyopaque;
extern "c" fn GlobalUnlock(mem: HANDLE) BOOL;
extern "c" fn GlobalFree(mem: HANDLE) HANDLE;
extern "c" fn Sleep(milliseconds: u32) void;

const OpenError = error{Unavailable};

/// `OpenClipboard` fails while another process owns the clipboard; retry briefly before giving up.
fn open(retries: usize) OpenError!void {
    var attempt: usize = 0;
    while (attempt <= retries) : (attempt += 1) {
        if (OpenClipboard(null) != 0) return;
        Sleep(5);
    }
    return error.Unavailable;
}

fn readTextImpl(_: ?*anyopaque, allocator: Allocator) Error![]const u8 {
    try open(10);
    defer _ = CloseClipboard();

    const handle = GetClipboardData(CF_UNICODETEXT) orelse return "";
    const locked = GlobalLock(handle) orelse return error.Failed;
    defer _ = GlobalUnlock(handle);

    const wide: [*:0]const u16 = @ptrCast(@alignCast(locked));
    return win.utf16ZToUtf8(allocator, wide) catch error.OutOfMemory;
}

/// Copies `text` into a `GMEM_MOVEABLE` block and hands ownership to the clipboard.
fn setUnicodeText(text: []const u8, allocator: Allocator) Error!void {
    const wide = win.utf8ToUtf16ZAlloc(allocator, text) catch return error.OutOfMemory;
    defer allocator.free(wide);

    const bytes = (wide.len + 1) * @sizeOf(u16);
    const handle = GlobalAlloc(GMEM_MOVEABLE, bytes) orelse return error.OutOfMemory;
    const locked = GlobalLock(handle) orelse {
        _ = GlobalFree(handle);
        return error.Failed;
    };
    const dst: [*]u16 = @ptrCast(@alignCast(locked));
    @memcpy(dst[0 .. wide.len + 1], wide[0 .. wide.len + 1]);
    _ = GlobalUnlock(handle);

    // After a successful `SetClipboardData` the system owns `handle` — never free it.
    if (SetClipboardData(CF_UNICODETEXT, handle) == null) {
        _ = GlobalFree(handle);
        return error.Failed;
    }
}

fn writeTextImpl(_: ?*anyopaque, text: []const u8) Error!void {
    const alloc = std.heap.c_allocator;
    try open(10);
    defer _ = CloseClipboard();

    if (EmptyClipboard() == 0) return error.Failed;
    try setUnicodeText(text, alloc);
}

/// Reads a decimal field from a CF_HTML header (`StartFragment:`, `EndFragment:`, …).
fn cfHtmlOffset(raw: []const u8, key: []const u8) ?usize {
    const index = std.mem.indexOf(u8, raw, key) orelse return null;
    const rest = raw[index + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse return null;
    const text = std.mem.trim(u8, rest[0..end], " \t");
    if (text.len == 0) return null;
    return std.fmt.parseInt(usize, text, 10) catch null;
}

/// Extracts the HTML fragment described by a CF_HTML payload.
///
/// Returning the whole block (header included) would make Windows disagree with GTK/macOS,
/// whose clipboard APIs hand back the fragment only. Invalid offsets fall back to the raw
/// text rather than panicking on attacker-controlled clipboard data.
fn cfHtmlFragment(raw: []const u8) []const u8 {
    if (raw.len == 0) return raw;
    const start = cfHtmlOffset(raw, "StartFragment:") orelse return raw;
    const end = cfHtmlOffset(raw, "EndFragment:") orelse return raw;
    // `start == end == 0` is what a producer that omits the offsets writes; slicing it would
    // silently return an empty string, so fall back to the whole payload.
    if (start >= end or end > raw.len) return raw;
    return raw[start..end];
}

fn readHtmlImpl(_: ?*anyopaque, allocator: Allocator) Error![]const u8 {
    const alloc = std.heap.c_allocator;
    const name_z = cstr.allocZ(alloc, "HTML Format") catch return error.OutOfMemory;
    defer alloc.free(name_z);
    var wide_name: [64:0]u16 = undefined;
    for (name_z, 0..) |c, i| wide_name[i] = c;
    wide_name[name_z.len] = 0;

    try open(10);
    defer _ = CloseClipboard();

    const format = RegisterClipboardFormatW(&wide_name);
    if (format == 0) return error.Failed;
    const handle = GetClipboardData(format) orelse return "";
    // `GlobalSize` is the ONLY safe bound: the block is usually far smaller than 1 MiB, and
    // scanning a fixed 1 MiB window reads past the allocation (the pre-fix code did that).
    const size = GlobalSize(handle);
    if (size == 0) return error.Failed;
    const locked = GlobalLock(handle) orelse return error.Failed;
    defer _ = GlobalUnlock(handle);

    const bytes: [*]const u8 = @ptrCast(locked);
    const view = bytes[0..size];
    const len = std.mem.indexOfScalar(u8, view, 0) orelse view.len;
    return allocator.dupe(u8, cfHtmlFragment(view[0..len])) catch error.OutOfMemory;
}

fn writeHtmlImpl(_: ?*anyopaque, html: []const u8, alt_text: ?[]const u8) Error!void {
    const alloc = std.heap.c_allocator;

    // Minimal `HTML Format` payload (the same header Chromium writes).
    const fragment_start_placeholder = "<!--StartFragment-->";
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    payload.writer.print(
        "Version:0.9\r\nStartHTML:{d:0>10}\r\nEndHTML:{d:0>10}\r\nStartFragment:{d:0>10}\r\nEndFragment:{d:0>10}\r\n",
        .{ 0, 0, 0, 0 },
    ) catch return error.OutOfMemory;
    const header_len = payload.written().len;
    payload.writer.writeAll(fragment_start_placeholder) catch return error.OutOfMemory;
    payload.writer.writeAll(html) catch return error.OutOfMemory;
    payload.writer.writeAll("<!--EndFragment-->") catch return error.OutOfMemory;

    const start_fragment = header_len + fragment_start_placeholder.len;
    const end_fragment = start_fragment + html.len;
    const end_html = payload.written().len;

    var final: std.Io.Writer.Allocating = .init(alloc);
    defer final.deinit();
    final.writer.print(
        "Version:0.9\r\nStartHTML:{d:0>10}\r\nEndHTML:{d:0>10}\r\nStartFragment:{d:0>10}\r\nEndFragment:{d:0>10}\r\n",
        .{ header_len, end_html, start_fragment, end_fragment },
    ) catch return error.OutOfMemory;
    final.writer.writeAll(payload.written()[header_len..]) catch return error.OutOfMemory;

    const body = final.written();

    const name_z = cstr.allocZ(alloc, "HTML Format") catch return error.OutOfMemory;
    defer alloc.free(name_z);
    var wide_name: [64:0]u16 = undefined;
    for (name_z, 0..) |c, i| wide_name[i] = c;
    wide_name[name_z.len] = 0;

    try open(10);
    defer _ = CloseClipboard();
    if (EmptyClipboard() == 0) return error.Failed;

    const format = RegisterClipboardFormatW(&wide_name);
    if (format == 0) return error.Failed;

    const handle = GlobalAlloc(GMEM_MOVEABLE, body.len + 1) orelse return error.OutOfMemory;
    const locked = GlobalLock(handle) orelse {
        _ = GlobalFree(handle);
        return error.Failed;
    };
    const dst: [*]u8 = @ptrCast(locked);
    @memcpy(dst[0..body.len], body);
    dst[body.len] = 0;
    _ = GlobalUnlock(handle);

    if (SetClipboardData(format, handle) == null) {
        _ = GlobalFree(handle);
        return error.Failed;
    }

    // The contract is HTML **plus** its plain-text fallback; a browser or editor that does not
    // read `HTML Format` still gets the text. `EmptyClipboard` already ran above, so setting a
    // second format here is legal.
    const fallback = if (alt_text) |alt| if (alt.len > 0) alt else html else html;
    try setUnicodeText(fallback, alloc);
}

fn clearImpl(_: ?*anyopaque) Error!void {
    try open(10);
    defer _ = CloseClipboard();
    if (EmptyClipboard() == 0) return error.Failed;
}

fn setExclusionFormats(allocator: Allocator) Error!void {
    const alloc = allocator;
    const bytes = alloc.alloc(u8, 1) catch return error.OutOfMemory;
    defer alloc.free(bytes);
    bytes[0] = 0;

    for ([_][]const u8{ EXCLUDE_MONITOR_TARGET, CAN_INCLUDE_HISTORY }) |name| {
        const name_z = cstr.allocZ(alloc, name) catch return error.OutOfMemory;
        defer alloc.free(name_z);
        var wide: [80:0]u16 = undefined;
        for (name_z, 0..) |c, i| wide[i] = c;
        wide[name_z.len] = 0;

        const format = RegisterClipboardFormatW(&wide);
        if (format == 0) continue;

        const handle = GlobalAlloc(GMEM_MOVEABLE, bytes.len) orelse continue;
        const locked = GlobalLock(handle) orelse {
            _ = GlobalFree(handle);
            continue;
        };
        const dst: [*]u8 = @ptrCast(locked);
        @memcpy(dst[0..bytes.len], bytes);
        _ = GlobalUnlock(handle);
        if (SetClipboardData(format, handle) == null) _ = GlobalFree(handle);
    }
}

fn writeSecretImpl(_: ?*anyopaque, text: []const u8) Error!void {
    const alloc = std.heap.c_allocator;
    try open(10);
    defer _ = CloseClipboard();

    if (EmptyClipboard() == 0) return error.Failed;
    try setUnicodeText(text, alloc);
    try setExclusionFormats(alloc);
}

const vtable = clipboard.Backend.VTable{
    .read_text = readTextImpl,
    .write_text = writeTextImpl,
    .read_html = readHtmlImpl,
    .write_html = writeHtmlImpl,
    .clear = clearImpl,
    .write_secret = writeSecretImpl,
};

pub fn backend() clipboard.Backend {
    return .{ .vtable = &vtable };
}

test "Win32 clipboard HTML round-trips a short payload without reading past the block" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    backend().writeHtml("<b>hi</b>", "hi") catch |err| switch (err) {
        error.Unavailable => return error.SkipZigTest, // no interactive window station
        else => return err,
    };
    const html = try backend().readHtml(arena.allocator());
    try std.testing.expectEqualStrings("<b>hi</b>", html);
    const text = try backend().readText(arena.allocator());
    try std.testing.expectEqualStrings("hi", text);
}

test "Win32 clipboard round-trips text and resets on clear" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    backend().writeText("zts clipboard こんにちは") catch |err| switch (err) {
        error.Unavailable => return error.SkipZigTest, // no interactive window station
        else => return err,
    };
    const text = try backend().readText(arena.allocator());
    try std.testing.expectEqualStrings("zts clipboard こんにちは", text);

    try backend().clear();
    const cleared = try backend().readText(arena.allocator());
    try std.testing.expectEqualStrings("", cleared);
}
