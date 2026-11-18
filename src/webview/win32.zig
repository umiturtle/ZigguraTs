//! Minimal, auditable Win32 + COM bindings for the Windows backend.
//!
//! Why hand-written instead of `@cImport` / `addTranslateC`?
//! - Zig 0.17 removed `@cImport`; `addTranslateC` on `<windows.h>` costs tens of seconds on every
//!   cold CI container.
//! - Only ~120 symbols are actually needed, and every one below is named exactly as in the SDK so
//!   `grep`-based audits and diffing against MSDN stay trivial.
//!
//! Everything here is `extern "user32"` / `"kernel32"` / … so the linker resolves the DLL imports
//! directly: **no import library, no `windows.lib` shim, no `libc`**.
//!
//! The file is compiled on every OS (the declarations are inert), but the `comptime` guard at the
//! bottom keeps accidental non-Windows *use* of the helpers out of the build.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// Scalar types (Windows SDK spellings, with the same width/rank)
// ---------------------------------------------------------------------------

/// `winapi` inside a Windows binary, the C convention everywhere else.
///
/// `.winapi` is a *target* calling convention: it only exists for Windows targets, so declaring it
/// unconditionally would make this file (and its allocator/conversion tests) unanalyzable on Linux
/// and on `aarch64-macos`. Every entry point below is x86-64/arm64 `extern "C"` compatible, and the
/// only consumer is the Windows backend (`windows.zig`), which is itself Windows-only at runtime.
pub const CC: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const BOOL = i32;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub const UINT = u32;
pub const DWORD = u32;
pub const ULONG = u32;
pub const LONG = i32;
pub const ATOM = u16;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const HRESULT = i32;
pub const LSTATUS = i32;

pub const HINSTANCE = *anyopaque;
pub const HMODULE = *anyopaque;
pub const HWND = *anyopaque;
pub const HICON = *anyopaque;
pub const HCURSOR = *anyopaque;
pub const HBRUSH = *anyopaque;
pub const HMENU = *anyopaque;
pub const HKEY = *anyopaque;
pub const HANDLE = *anyopaque;
pub const HDC = *anyopaque;
pub const HGLOBAL = *anyopaque;

/// `LPCWSTR`
pub const W = [*:0]const u16;
/// `LPWSTR` (caller-owned UTF-16 buffer)
pub const WStr = [*:0]u16;

pub const ERROR_SUCCESS: LSTATUS = 0;
pub const REG_SZ: DWORD = 1;
pub const REG_EXPAND_SZ: DWORD = 2;
pub const REG_DWORD: DWORD = 4;
pub const KEY_QUERY_VALUE: DWORD = 0x0001;
pub const KEY_WOW64_32KEY: DWORD = 0x0200;
pub const KEY_WOW64_64KEY: DWORD = 0x0100;
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x8000_0001);
pub const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x8000_0002);
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFF_FFFF;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub const LOAD_WITH_ALTERED_SEARCH_PATH: DWORD = 0x0000_0008;
pub const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: DWORD = 0x0000_0002;

// ---------------------------------------------------------------------------
// Window messages, styles & flags (only what the backend touches)
// ---------------------------------------------------------------------------

pub const WM_CREATE = 0x0001;
pub const WM_DESTROY = 0x0002;
pub const WM_MOVE = 0x0003;
pub const WM_SIZE = 0x0005;
pub const WM_ACTIVATE = 0x0006;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_CLOSE = 0x0010;
pub const WM_QUIT = 0x0012;
pub const WM_PAINT = 0x000F;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_SETCURSOR = 0x0020;
pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_NCCREATE = 0x0081;
pub const WM_NCDESTROY = 0x0082;
pub const WM_NCCALCSIZE = 0x0083;
pub const WM_NCHITTEST = 0x0084;
pub const WM_NCLBUTTONDOWN = 0x00A1;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_ENTERSIZEMOVE = 0x0231;
pub const WM_EXITSIZEMOVE = 0x0232;
pub const WM_GETDPISCALEDSIZE = 0x02E4;

pub const WS_OVERLAPPED = 0x0000_0000;
pub const WS_POPUP = 0x8000_0000;
pub const WS_CHILD = 0x4000_0000;
pub const WS_MINIMIZE = 0x2000_0000;
pub const WS_VISIBLE = 0x1000_0000;
pub const WS_DISABLED = 0x0800_0000;
pub const WS_CLIPSIBLINGS = 0x0400_0000;
pub const WS_CLIPCHILDREN = 0x0200_0000;
pub const WS_MAXIMIZE = 0x0100_0000;
pub const WS_CAPTION = 0x00C0_0000;
pub const WS_BORDER = 0x0080_0000;
pub const WS_SYSMENU = 0x0008_0000;
pub const WS_THICKFRAME = 0x0004_0000;
pub const WS_MINIMIZEBOX = 0x0002_0000;
pub const WS_MAXIMIZEBOX = 0x0001_0000;

pub const WS_EX_TOPMOST = 0x0000_0008;
pub const WS_EX_TRANSPARENT = 0x0000_0020;
pub const WS_EX_APPWINDOW = 0x0004_0000;
pub const WS_EX_LAYERED = 0x0008_0000;
pub const WS_EX_NOREDIRECTIONBITMAP = 0x0020_0000;

pub const WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
pub const WS_POPUPWINDOW = WS_POPUP | WS_BORDER | WS_SYSMENU;

pub const SW_HIDE = 0;
pub const SW_SHOWNORMAL = 1;
pub const SW_SHOWMINIMIZED = 2;
pub const SW_MAXIMIZE = 3;
pub const SW_SHOW = 5;
pub const SW_MINIMIZE = 6;
pub const SW_RESTORE = 9;

pub const GWL_STYLE: i32 = -16;
pub const GWL_EXSTYLE: i32 = -20;
pub const GWLP_USERDATA: i32 = -21;
pub const GWLP_WNDPROC: i32 = -4;

/// `HWND_TOP` is the null handle (`0`), which Zig's non-optional pointers cannot express.
pub const HWND_TOP: ?HWND = null;
pub const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

/// `SetWindowDisplayAffinity` values (Windows 7+ / Windows 10 2004+).
pub const HWND_BOTTOM: HWND = @ptrFromInt(1);
pub const WS_EX_TOOLWINDOW: DWORD = 0x0000_0080;
pub const WDA_NONE: DWORD = 0x0000_0000;
pub const WDA_EXCLUDEFROMCAPTURE: DWORD = 0x0000_0011;

pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;
pub const SWP_FRAMECHANGED = 0x0020;
pub const SWP_SHOWWINDOW = 0x0040;

pub const PM_NOREMOVE = 0x0000;
pub const PM_REMOVE = 0x0001;
pub const QS_ALLINPUT = 0x04FF;
pub const MWMO_INPUTAVAILABLE = 0x0004;
pub const WAIT_OBJECT_0 = 0;
pub const WAIT_TIMEOUT = 258;

pub const CS_VREDRAW = 0x0001;
pub const CS_HREDRAW = 0x0002;
pub const CS_OWNDC = 0x0020;
pub const IDC_ARROW: usize = 32512;
/// Cursor identities for `LoadCursorW` (`winuser.h` `IDC_*`). `CROSS` is `IDC_CROSS` (32515),
/// while `IDC_SIZENWSE`/`IDC_SIZENESW` cover the diagonal resize arrows tao maps.
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
pub const IDC_APPSTARTING: usize = 32650;
pub const IDC_HELP: usize = 32651;
pub const COLOR_WINDOW = 5;

pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x8000_0000));
pub const SM_CXSCREEN = 0;
pub const SM_CYSCREEN = 1;
pub const SM_CXSMICON = 49;
pub const SM_CYSMICON = 50;

/// `FlashWindowEx` flags (`winuser.h`).
pub const FLASHW_STOP: u32 = 0x0000;
pub const FLASHW_CAPTION: u32 = 0x0001;
pub const FLASHW_TRAY: u32 = 0x0002;
pub const FLASHW_ALL: u32 = FLASHW_CAPTION | FLASHW_TRAY;
pub const FLASHW_TIMER: u32 = 0x0004;
pub const FLASHW_TIMERNOFG: u32 = 0x000C;

/// `ITaskbarList3` progress states (`shobjidl_core.h` `TBPFLAG`).
pub const TBPF_NOPROGRESS: i32 = 0x0;
pub const TBPF_INDETERMINATE: i32 = 0x1;
pub const TBPF_NORMAL: i32 = 0x2;
pub const TBPF_ERROR: i32 = 0x4;
pub const TBPF_PAUSED: i32 = 0x8;

/// `CLSCTX_SERVER` — in-process, local and remote servers (used by `CoCreateInstance`).
pub const CLSCTX_SERVER: DWORD = 0x15;

pub const HTCLIENT = 1;
pub const HTCAPTION = 2;

pub const LWA_ALPHA = 0x0000_0002;

pub const DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;
pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
pub const DWMWA_WINDOW_CORNER_PREFERENCE = 33;
/// `DWMWA_SYSTEMBACKDROP_TYPE` (Windows 11 22H2+). Older builds reject the attribute, which the
/// backend treats exactly like the dark-mode attribute: silently ignored.
pub const DWMWA_SYSTEMBACKDROP_TYPE = 38;
pub const DWMWCP_ROUND = 2;

/// `DWM_SYSTEMBACKDROP_TYPE` values.
pub const DWMSBT_AUTO = 0;
pub const DWMSBT_NONE = 1;
pub const DWMSBT_MAINWINDOW = 2;
pub const DWMSBT_TRANSIENTWINDOW = 3;
pub const DWMSBT_TABBEDWINDOW = 4;

/// `ACCENT_STATE` for the undocumented-but-stable `SetWindowCompositionAttribute` accent policy.
pub const ACCENT_DISABLED: u32 = 0;
pub const ACCENT_ENABLE_BLURBEHIND: u32 = 3;
/// `WINDOWCOMPOSITIONATTRIB::WCA_ACCENT_POLICY`.
pub const WCA_ACCENT_POLICY: u32 = 19;

/// `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
/// `PROCESS_PER_MONITOR_DPI_AWARE`
pub const PROCESS_PER_MONITOR_DPI_AWARE: u32 = 2;

pub const COINIT_APARTMENTTHREADED: u32 = 0x2;
pub const COINIT_DISABLE_OLE1DDE: u32 = 0x4;
pub const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x8001_0106));

// ---------------------------------------------------------------------------
// Structs
// ---------------------------------------------------------------------------

pub const POINT = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const RECT = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub inline fn width(self: RECT) i32 {
        return self.right - self.left;
    }

    pub inline fn height(self: RECT) i32 {
        return self.bottom - self.top;
    }
};

pub const SIZE = extern struct {
    cx: i32 = 0,
    cy: i32 = 0,
};

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: UINT = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
    /// `DWORD lPrivate` only exists under `#ifdef _MAC`; the SDK layout on x64/arm64 is 8 bytes
    /// *shorter*, but Windows zero-fills the caller's struct only up to `sizeof(MSG)`. Declaring
    /// the field keeps our struct >= the SDK's, which is the safe direction.
    lPrivate: DWORD = 0,
};

/// `CREATESTRUCTW` — read-only in `WM_NCCREATE`; `lpCreateParams` is the `*WinWindow` passed to
/// `CreateWindowExW`.
pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque = null,
    hInstance: ?HINSTANCE = null,
    hMenu: ?HMENU = null,
    hwndParent: ?HWND = null,
    cy: i32 = 0,
    cx: i32 = 0,
    y: i32 = 0,
    x: i32 = 0,
    style: LONG = 0,
    lpszName: ?W = null,
    lpszClass: ?W = null,
    dwExStyle: DWORD = 0,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT = .{},
    ptMaxSize: POINT = .{},
    ptMaxPosition: POINT = .{},
    ptMinTrackSize: POINT = .{},
    ptMaxTrackSize: POINT = .{},
};

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: ?*const fn (HWND, UINT, WPARAM, LPARAM) callconv(CC) LRESULT = null,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?W = null,
    lpszClassName: ?W = null,
    hIconSm: ?HICON = null,
};

pub const SYSTEM_INFO = extern struct {
    processor_architecture: u16,
    reserved: u16,
    page_size: DWORD,
    minimum_application_address: *anyopaque,
    maximum_application_address: *anyopaque,
    active_processor_mask: usize,
    number_of_processors: DWORD,
    processor_type: DWORD,
    allocation_granularity: DWORD,
    processor_level: u16,
    processor_revision: u16,
};

/// `FLASHWINFO` — parameter block for `FlashWindowEx`.
pub const FLASHWINFO = extern struct {
    cbSize: u32 = @sizeOf(FLASHWINFO),
    hwnd: ?HWND = null,
    dwFlags: u32 = 0,
    uCount: u32 = 0,
    dwTimeout: u32 = 0,
};

/// `MARGINS` — parameter block for `DwmExtendFrameIntoClientArea`.
pub const MARGINS = extern struct {
    cxLeftWidth: i32 = 0,
    cxRightWidth: i32 = 0,
    cyTopHeight: i32 = 0,
    cyBottomHeight: i32 = 0,
};

/// `ACCENT_POLICY` — payload of `WCA_ACCENT_POLICY`. The API is undocumented but its layout has
/// been stable since Windows 10; `SetWindowCompositionAttribute` is resolved dynamically so a
/// missing export simply means "no blur" on that build.
pub const ACCENT_POLICY = extern struct {
    AccentState: u32 = ACCENT_DISABLED,
    AccentFlags: u32 = 0,
    GradientColor: u32 = 0,
    AnimationId: u32 = 0,
};

/// `WINDOWCOMPOSITIONATTRIBDATA`.
pub const WINDOWCOMPOSITIONATTRIBDATA = extern struct {
    Attrib: u32 = WCA_ACCENT_POLICY,
    pvData: ?*anyopaque = null,
    cbData: usize = 0,
};

pub const SetWindowCompositionAttributeFn =
    *const fn (HWND, *WINDOWCOMPOSITIONATTRIBDATA) callconv(CC) BOOL;

/// `GUID` / `CLSID` / `IID` (`guiddef.h`). Same 128-bit layout as `com.Guid`; the COM constants
/// below are spelled out as literals so no SDK header or import library is required.
pub const GUID = extern struct {
    d1: u32,
    d2: u16,
    d3: u16,
    d4: [8]u8,
};

pub const CLSID_TaskbarList = GUID{
    .d1 = 0x56FDF344,
    .d2 = 0xFD6D,
    .d3 = 0x11D0,
    .d4 = .{ 0x95, 0x8A, 0x00, 0x60, 0x97, 0xC9, 0xA0, 0x90 },
};

pub const IID_ITaskbarList3 = GUID{
    .d1 = 0xEA1AFB91,
    .d2 = 0x9E28,
    .d3 = 0x4B86,
    .d4 = .{ 0x90, 0xE9, 0x9E, 0x9F, 0x8A, 0x5E, 0xEF, 0xAF },
};

/// `ITaskbarList3` (`shobjidl_core.h`), 21 vtable slots. Only the progress / overlay methods are
/// typed; the rest keep the slot offsets ABI-exact.
pub const ITaskbarList3 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ITaskbarList3, *const GUID, *?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ITaskbarList3) callconv(CC) u32,
        Release: *const fn (*ITaskbarList3) callconv(CC) u32,
        HrInit: *const fn (*ITaskbarList3) callconv(CC) HResult,
        AddTab: *const fn (*ITaskbarList3, HWND) callconv(CC) HResult,
        DeleteTab: *const fn (*ITaskbarList3, HWND) callconv(CC) HResult,
        ActivateTab: *const fn (*ITaskbarList3, HWND) callconv(CC) HResult,
        SetActiveAlt: *const fn (*ITaskbarList3, HWND) callconv(CC) HResult,
        MarkFullscreenWindow: *const fn (*ITaskbarList3, HWND, BOOL) callconv(CC) HResult,
        SetProgressValue: *const fn (*ITaskbarList3, HWND, u64, u64) callconv(CC) HResult,
        SetProgressState: *const fn (*ITaskbarList3, HWND, i32) callconv(CC) HResult,
        RegisterTab: *const fn (*ITaskbarList3, HWND, HWND) callconv(CC) HResult,
        UnregisterTab: *const fn (*ITaskbarList3, HWND) callconv(CC) HResult,
        SetTabOrder: *const fn (*ITaskbarList3, HWND, HWND) callconv(CC) HResult,
        SetTabActive: *const fn (*ITaskbarList3, HWND, HWND, DWORD) callconv(CC) HResult,
        ThumbBarAddButtons: *const fn (*ITaskbarList3, HWND, UINT, ?*anyopaque) callconv(CC) HResult,
        ThumbBarUpdateButtons: *const fn (*ITaskbarList3, HWND, UINT, ?*anyopaque) callconv(CC) HResult,
        ThumbBarSetImageList: *const fn (*ITaskbarList3, HWND, ?*anyopaque) callconv(CC) HResult,
        SetOverlayIcon: *const fn (*ITaskbarList3, HWND, ?HICON, ?W) callconv(CC) HResult,
        SetThumbnailTooltip: *const fn (*ITaskbarList3, HWND, ?W) callconv(CC) HResult,
        SetThumbnailClip: *const fn (*ITaskbarList3, HWND, ?*RECT) callconv(CC) HResult,
    };
};

// GDI objects used to synthesise the numeric taskbar overlay icon.
pub const HBITMAP = *anyopaque;
pub const HFONT = *anyopaque;

pub const RGBQUAD = extern struct {
    rgbBlue: u8 = 0,
    rgbGreen: u8 = 0,
    rgbRed: u8 = 0,
    rgbReserved: u8 = 0,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32 = 0,
    biHeight: i32 = 0,
    biPlanes: u16 = 1,
    biBitCount: u16 = 0,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER = .{},
    bmiColors: [1]RGBQUAD = .{.{}},
};

pub const BI_RGB: u32 = 0;
pub const DIB_RGB_COLORS: UINT = 0;
pub const FW_BOLD: i32 = 700;
pub const DEFAULT_CHARSET: DWORD = 1;
pub const CLEARTYPE_QUALITY: DWORD = 5;
pub const DEFAULT_PITCH: DWORD = 0;
pub const TRANSPARENT: i32 = 1;
pub const DT_CENTER: UINT = 0x0000_0001;
pub const DT_VCENTER: UINT = 0x0000_0004;
pub const DT_SINGLELINE: UINT = 0x0000_0020;

pub const ICONINFO = extern struct {
    fIcon: BOOL = TRUE,
    xHotspot: DWORD = 0,
    yHotspot: DWORD = 0,
    hbmMask: ?HBITMAP = null,
    hbmColor: ?HBITMAP = null,
};

// ---------------------------------------------------------------------------
// user32.dll
// ---------------------------------------------------------------------------

pub extern "user32" fn RegisterClassExW(cls: *const WNDCLASSEXW) callconv(CC) ATOM;
pub extern "user32" fn UnregisterClassW(name: W, instance: ?HINSTANCE) callconv(CC) BOOL;
pub extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: W,
    window_name: W,
    style: DWORD,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?HWND,
    menu: ?HMENU,
    instance: ?HINSTANCE,
    param: ?*anyopaque,
) callconv(CC) ?HWND;
pub extern "user32" fn DestroyWindow(hwnd: HWND) callconv(CC) BOOL;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(CC) LRESULT;
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd: i32) callconv(CC) BOOL;
pub extern "user32" fn UpdateWindow(hwnd: HWND) callconv(CC) BOOL;
pub extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(CC) BOOL;
pub extern "user32" fn EnableWindow(hwnd: HWND, enable: BOOL) callconv(CC) BOOL;
pub extern "user32" fn SetWindowDisplayAffinity(hwnd: HWND, affinity: DWORD) callconv(CC) BOOL;
pub extern "user32" fn SetWindowTextW(hwnd: HWND, text: W) callconv(CC) BOOL;
pub extern "user32" fn GetWindowTextW(hwnd: HWND, buf: [*]u16, max: i32) callconv(CC) i32;
pub extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: i32) callconv(CC) isize;
pub extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: i32, value: isize) callconv(CC) isize;
pub extern "user32" fn SetWindowPos(
    hwnd: HWND,
    insert_after: ?HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: UINT,
) callconv(CC) BOOL;
pub extern "user32" fn GetClientRect(hwnd: HWND, out: *RECT) callconv(CC) BOOL;
pub extern "user32" fn GetWindowRect(hwnd: HWND, out: *RECT) callconv(CC) BOOL;
pub extern "user32" fn AdjustWindowRectEx(out: *RECT, style: DWORD, menu: BOOL, ex_style: DWORD) callconv(CC) BOOL;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(CC) UINT;
pub extern "user32" fn SetProcessDpiAwarenessContext(ctx: isize) callconv(CC) BOOL;
pub extern "user32" fn GetSystemMetrics(index: i32) callconv(CC) i32;
pub extern "user32" fn LoadCursorW(instance: ?HINSTANCE, name: usize) callconv(CC) ?HCURSOR;
pub extern "user32" fn SetCursor(cursor: ?HCURSOR) callconv(CC) ?HCURSOR;
pub extern "user32" fn SetFocus(hwnd: HWND) callconv(CC) ?HWND;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(CC) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(CC) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(CC) BOOL;
pub extern "user32" fn SetCapture(hwnd: HWND) callconv(CC) ?HWND;
pub extern "user32" fn SendMessageW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(CC) LRESULT;
pub extern "user32" fn PostMessageW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(CC) BOOL;
pub extern "user32" fn PostQuitMessage(exit_code: i32) callconv(CC) void;
pub extern "user32" fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT, remove: UINT) callconv(CC) BOOL;
pub extern "user32" fn GetMessageW(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT) callconv(CC) BOOL;
pub extern "user32" fn TranslateMessage(msg: *const MSG) callconv(CC) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(CC) LRESULT;
pub extern "user32" fn MsgWaitForMultipleObjectsEx(
    count: DWORD,
    handles: *const HANDLE,
    milliseconds: DWORD,
    wake_mask: DWORD,
    flags: DWORD,
) callconv(CC) DWORD;
pub extern "user32" fn MessageBoxW(hwnd: ?HWND, text: W, caption: W, kind: UINT) callconv(CC) i32;
pub extern "user32" fn GetDC(hwnd: ?HWND) callconv(CC) ?HDC;
pub extern "user32" fn ReleaseDC(hwnd: ?HWND, dc: HDC) callconv(CC) i32;
pub extern "user32" fn InvalidateRect(hwnd: HWND, rect: ?*const RECT, erase: BOOL) callconv(CC) BOOL;
pub extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, key: u32, alpha: u8, flags: DWORD) callconv(CC) BOOL;
pub extern "user32" fn ClientToScreen(hwnd: HWND, point: *POINT) callconv(CC) BOOL;
pub extern "user32" fn SetCursorPos(x: i32, y: i32) callconv(CC) BOOL;
pub extern "user32" fn ClipCursor(rect: ?*const RECT) callconv(CC) BOOL;
pub extern "user32" fn ShowCursor(show: BOOL) callconv(CC) i32;
pub extern "user32" fn GetActiveWindow() callconv(CC) ?HWND;
pub extern "user32" fn IsIconic(hwnd: HWND) callconv(CC) BOOL;
pub extern "user32" fn FlashWindowEx(info: *const FLASHWINFO) callconv(CC) BOOL;
pub extern "user32" fn FillRect(dc: HDC, rect: *const RECT, brush: HBRUSH) callconv(CC) i32;
pub extern "user32" fn DrawTextW(dc: HDC, text: [*]const u16, count: i32, rect: *RECT, format: UINT) callconv(CC) i32;
pub extern "user32" fn CreateIconIndirect(info: *const ICONINFO) callconv(CC) ?HICON;
pub extern "user32" fn DestroyIcon(icon: HICON) callconv(CC) BOOL;

// ---------------------------------------------------------------------------
// kernel32.dll
// ---------------------------------------------------------------------------

pub extern "kernel32" fn GetModuleHandleW(name: ?W) callconv(CC) ?HMODULE;
pub extern "kernel32" fn GetModuleHandleExW(flags: DWORD, name: ?W, out: *?HMODULE) callconv(CC) BOOL;
pub extern "kernel32" fn GetLastError() callconv(CC) DWORD;
pub extern "kernel32" fn LoadLibraryExW(path: W, file: ?HANDLE, flags: DWORD) callconv(CC) ?HMODULE;
pub extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(CC) BOOL;
pub extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(CC) ?*const anyopaque;
pub extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual_reset: BOOL, initial_state: BOOL, name: ?W) callconv(CC) ?HANDLE;
pub extern "kernel32" fn SetEvent(event: HANDLE) callconv(CC) BOOL;
pub extern "kernel32" fn ResetEvent(event: HANDLE) callconv(CC) BOOL;
pub extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(CC) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW(name: W, buf: [*]u16, size: DWORD) callconv(CC) DWORD;
pub extern "kernel32" fn GetFileAttributesW(path: W) callconv(CC) DWORD;
pub extern "kernel32" fn GetCurrentThreadId() callconv(CC) DWORD;
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(CC) void;
pub extern "kernel32" fn GetTickCount64() callconv(CC) u64;
pub extern "kernel32" fn GetSystemInfo(out: *SYSTEM_INFO) callconv(CC) void;

// ---------------------------------------------------------------------------
// gdi32.dll (numeric taskbar overlay icon)
// ---------------------------------------------------------------------------

pub extern "gdi32" fn CreateCompatibleDC(dc: ?HDC) callconv(CC) ?HDC;
pub extern "gdi32" fn CreateDIBSection(
    dc: ?HDC,
    info: *const BITMAPINFO,
    usage: UINT,
    bits: *?*anyopaque,
    section: ?HANDLE,
    offset: DWORD,
) callconv(CC) ?HBITMAP;
pub extern "gdi32" fn SelectObject(dc: HDC, obj: *anyopaque) callconv(CC) *anyopaque;
pub extern "gdi32" fn DeleteObject(obj: *anyopaque) callconv(CC) BOOL;
pub extern "gdi32" fn DeleteDC(dc: HDC) callconv(CC) BOOL;
pub extern "gdi32" fn CreateBitmap(
    width: i32,
    height: i32,
    planes: UINT,
    bits_per_pixel: UINT,
    bits: ?*const anyopaque,
) callconv(CC) ?HBITMAP;
pub extern "gdi32" fn CreateFontW(
    height: i32,
    width: i32,
    escapement: i32,
    orientation: i32,
    weight: i32,
    italic: DWORD,
    underline: DWORD,
    strike_out: DWORD,
    charset: DWORD,
    out_precision: DWORD,
    clip_precision: DWORD,
    quality: DWORD,
    pitch_and_family: DWORD,
    face_name: W,
) callconv(CC) ?HFONT;
pub extern "gdi32" fn SetBkMode(dc: HDC, mode: i32) callconv(CC) i32;
pub extern "gdi32" fn SetTextColor(dc: HDC, color: u32) callconv(CC) u32;

/// `RGB(r, g, b)` — the byte order `COLORREF` / GDI expects.
pub inline fn rgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

// ---------------------------------------------------------------------------
// ole32.dll / shlwapi.dll / dwmapi.dll
// ---------------------------------------------------------------------------

pub extern "ole32" fn CoCreateInstance(
    clsid: *const GUID,
    outer: ?*anyopaque,
    cls_context: DWORD,
    iid: *const GUID,
    out: *?*anyopaque,
) callconv(CC) HResult;

pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, co_init: u32) callconv(CC) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(CC) void;
pub extern "ole32" fn CoTaskMemFree(mem: ?*anyopaque) callconv(CC) void;

/// `SHCreateMemStream` builds a COM `IStream` over a byte buffer — used for WebView2 response
/// bodies so Zig never has to implement `IStream` by hand.
pub extern "shlwapi" fn SHCreateMemStream(init: ?[*]const u8, cb_init: u32) callconv(CC) ?*anyopaque;

pub extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: HWND,
    attribute: u32,
    value: *const anyopaque,
    size: u32,
) callconv(CC) i32;

/// `DwmExtendFrameIntoClientArea` — extending by one pixel is the standard way to give a
/// borderless (`WS_POPUP`) window the DWM frame shadow; all-zero margins disable the extension.
pub extern "dwmapi" fn DwmExtendFrameIntoClientArea(hwnd: HWND, margins: *const MARGINS) callconv(CC) i32;

// ---------------------------------------------------------------------------
// advapi32.dll (registry: WebView2 runtime discovery)
// ---------------------------------------------------------------------------

pub extern "advapi32" fn RegOpenKeyExW(
    key: HKEY,
    sub_key: W,
    options: DWORD,
    sam: DWORD,
    out: *?HKEY,
) callconv(CC) LSTATUS;
pub extern "advapi32" fn RegQueryValueExW(
    key: HKEY,
    value_name: W,
    reserved: ?*DWORD,
    kind: *DWORD,
    data: ?[*]u8,
    size: *DWORD,
) callconv(CC) LSTATUS;
pub extern "advapi32" fn RegCloseKey(key: HKEY) callconv(CC) LSTATUS;

// ---------------------------------------------------------------------------
// COM `IStream` (only `Read` + `Release` are ever called; the rest keep the ABI layout)
// ---------------------------------------------------------------------------

pub const HResult = i32;

pub const IStream = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: ?*const anyopaque,
        AddRef: ?*const anyopaque,
        Release: *const fn (*IStream) callconv(CC) u32,
        Read: *const fn (*IStream, buffer: [*]u8, to_read: u32, read: ?*u32) callconv(CC) HResult,
        Write: ?*const anyopaque,
        Seek: ?*const anyopaque,
        SetSize: ?*const anyopaque,
        CopyTo: ?*const anyopaque,
        Commit: ?*const anyopaque,
        Revert: ?*const anyopaque,
        LockRegion: ?*const anyopaque,
        UnlockRegion: ?*const anyopaque,
        Stat: ?*const anyopaque,
        Clone: ?*const anyopaque,
    };
};

comptime {
    // IUnknown(3) + Read/Write/Seek/SetSize/CopyTo/Commit/Revert/LockRegion/UnlockRegion/Stat/Clone
    std.debug.assert(@sizeOf(IStream.VTable) == 14 * @sizeOf(*anyopaque));
    // IUnknown(3) + ITaskbarList(5) + ITaskbarList2(1) + ITaskbarList3(12).
    std.debug.assert(@sizeOf(ITaskbarList3.VTable) == 21 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(GUID) == 16);
    std.debug.assert(@sizeOf(FLASHWINFO) == 32);
    std.debug.assert(@sizeOf(ACCENT_POLICY) == 16);
    // BOOL + two DWORDs + two pointers, 8-byte aligned on x64/arm64.
    std.debug.assert(@sizeOf(ICONINFO) == 32);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub inline fn loword(value: LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(value)));
}

pub inline fn hiword(value: LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(value)) >> 16);
}

pub inline fn makeIntAtom(lo: u16, hi: u16) WPARAM {
    return (@as(usize, hi) << 16) | lo;
}

/// Converts a UTF-8 slice into a NUL-terminated UTF-16 buffer owned by `allocator`.
///
/// The buffer is allocated with the **exact** UTF-16 length (`calcUtf16LeLen`) rather than an
/// upper bound: `Allocator.free` derives the byte count from `slice.len`, so returning a
/// shorter-than-allocated sub-slice would make every `free` corrupt the allocator's metadata
/// (that was the `free of invalid memory` panic on the Windows runner).
pub fn toWide(allocator: std.mem.Allocator, utf8: []const u8) error{ OutOfMemory, InvalidUtf8 }![:0]u16 {
    const len = std.unicode.calcUtf16LeLen(utf8) catch return error.InvalidUtf8;
    const buf = try allocator.allocSentinel(u16, len, 0);
    errdefer allocator.free(buf);
    _ = std.unicode.utf8ToUtf16Le(buf, utf8) catch {
        // `calcUtf16LeLen` already validated the input; this is unreachable in practice.
        return error.InvalidUtf8;
    };
    return buf;
}

/// Frees a COM-owned `LPWSTR`. Kept behind an OS check so the UTF-16 conversion helpers above stay
/// linkable (and testable) on hosts that have no `ole32.dll`.
fn freeWideString(wide: [*:0]const u16) void {
    if (builtin.os.tag == .windows) {
        CoTaskMemFree(@ptrCast(@constCast(wide)));
    }
}

/// Converts a NUL-terminated UTF-16 string into UTF-8 (allocated). Frees `wide` via CoTaskMem if
/// `free_wide` is set (WebView2 getters hand back CoTaskMem strings).
pub fn fromWide(
    allocator: std.mem.Allocator,
    wide: [*:0]const u16,
    free_wide: bool,
) error{ OutOfMemory, InvalidUtf16 }![]u8 {
    defer if (free_wide) freeWideString(wide);
    const units = std.mem.span(wide);
    return std.unicode.utf16LeToUtf8Alloc(allocator, units) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf16,
    };
}

test "toWide / fromWide round-trip ASCII, BMP and astral code points" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{ "hello", "Z-Ts ウィンドウ", "emoji 🚀 ok", "" };
    for (cases) |case| {
        const wide = try toWide(a, case);
        defer a.free(wide);
        const back = try fromWide(a, wide.ptr, false);
        defer a.free(back);
        try std.testing.expectEqualStrings(case, back);
    }
}

test "toWide rejects invalid UTF-8 instead of writing a truncated string" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidUtf8, toWide(a, "\xff\xfe"));
}

test "loword / hiword split the packed WM_DPICHANGED coordinates" {
    const value: LPARAM = @bitCast((@as(usize, 192) << 16) | @as(usize, 144));
    try std.testing.expectEqual(@as(u16, 144), loword(value));
    try std.testing.expectEqual(@as(u16, 192), hiword(value));
}
