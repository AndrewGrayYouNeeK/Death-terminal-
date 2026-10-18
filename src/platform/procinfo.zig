//! "Is something other than the shell running in this terminal?" (for the
//! close confirmation), per platform.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Linux / macOS: the terminal's foreground process group, if it isn't the
/// shell's, named via /proc (Linux) or proc_name (macOS).
pub fn foregroundProgram(fd: posix.fd_t, shell: posix.pid_t, buf: []u8) ?[]const u8 {
    const pgrp = tcgetpgrp(fd) orelse return null;
    if (pgrp == shell or pgrp <= 0) return null;
    return processName(pgrp, buf) orelse "a program";
}

fn tcgetpgrp(fd: posix.fd_t) ?posix.pid_t {
    if (builtin.os.tag == .linux) {
        var pgrp: posix.pid_t = 0;
        const rc = std.os.linux.ioctl(fd, std.os.linux.T.IOCGPGRP, @intFromPtr(&pgrp));
        if (std.os.linux.E.init(rc) != .SUCCESS) return null;
        return pgrp;
    }
    const r = c_tcgetpgrp(fd);
    return if (r < 0) null else r;
}

const c_tcgetpgrp = @extern(*const fn (c_int) callconv(.C) c_int, .{ .name = "tcgetpgrp" });
extern "c" fn proc_name(pid: c_int, buf: [*]u8, size: u32) c_int;

fn processName(pid: posix.pid_t, buf: []u8) ?[]const u8 {
    if (builtin.os.tag.isDarwin()) {
        const n = proc_name(pid, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(u32))));
        return if (n > 0) buf[0..@intCast(n)] else null;
    }
    var pb: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/proc/{d}/comm", .{pid}) catch return null;
    const f = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer f.close();
    const n = f.read(buf) catch return null;
    const name = std.mem.trimRight(u8, buf[0..n], "\n");
    return if (name.len == 0) null else name;
}

/// Windows: the newest direct child of the shell process (ConPTY has no
/// foreground process group), by executable name without ".exe".
pub fn childProgram(shell: std.os.windows.HANDLE, buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    const w = std.os.windows;
    const Snap = struct {
        const PROCESSENTRY32W = extern struct {
            dwSize: w.DWORD,
            cntUsage: w.DWORD,
            th32ProcessID: w.DWORD,
            th32DefaultHeapID: usize,
            th32ModuleID: w.DWORD,
            cntThreads: w.DWORD,
            th32ParentProcessID: w.DWORD,
            pcPriClassBase: i32,
            dwFlags: w.DWORD,
            szExeFile: [260]u16,
        };
        extern "kernel32" fn CreateToolhelp32Snapshot(flags: w.DWORD, pid: w.DWORD) callconv(w.WINAPI) w.HANDLE;
        extern "kernel32" fn Process32FirstW(snap: w.HANDLE, e: *PROCESSENTRY32W) callconv(w.WINAPI) w.BOOL;
        extern "kernel32" fn Process32NextW(snap: w.HANDLE, e: *PROCESSENTRY32W) callconv(w.WINAPI) w.BOOL;
        extern "kernel32" fn GetProcessId(h: w.HANDLE) callconv(w.WINAPI) w.DWORD;
    };
    const shell_id = Snap.GetProcessId(shell);
    if (shell_id == 0) return null;
    const snap = Snap.CreateToolhelp32Snapshot(0x2, 0); // TH32CS_SNAPPROCESS
    if (snap == w.INVALID_HANDLE_VALUE) return null;
    defer w.CloseHandle(snap);
    var e = std.mem.zeroes(Snap.PROCESSENTRY32W);
    e.dwSize = @sizeOf(Snap.PROCESSENTRY32W);
    var found: ?[]const u8 = null;
    var ok = Snap.Process32FirstW(snap, &e) != 0;
    while (ok) : (ok = Snap.Process32NextW(snap, &e) != 0) {
        if (e.th32ParentProcessID != shell_id) continue;
        const name16 = std.mem.sliceTo(&e.szExeFile, 0);
        var tmp: [780]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&tmp, name16) catch continue;
        var name = tmp[0..n];
        if (std.ascii.endsWithIgnoreCase(name, ".exe")) name = name[0 .. name.len - 4];
        // conhost.exe hosts the pseudo console itself; not a "program".
        if (std.ascii.eqlIgnoreCase(name, "conhost") or std.ascii.eqlIgnoreCase(name, "OpenConsole")) continue;
        const len = @min(name.len, buf.len);
        @memcpy(buf[0..len], name[0..len]);
        found = buf[0..len];
    }
    return found;
}
