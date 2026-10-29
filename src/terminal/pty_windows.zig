//! Windows pseudo console (ConPTY, Windows 10 1809+).
//!
//! The shell runs attached to a pseudo console fed by two pipes. A reader
//! thread copies the console's output pipe into a loopback socket so the
//! event loop can `poll` it like a pty master (see platform/io.zig); a
//! waiter thread closes the pseudo console when the shell exits, which
//! flushes the last output and ends the stream (read returns 0, like EIO on
//! a Unix pty).

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const k32 = windows.kernel32;
const io = @import("../platform/io.zig");
const pty = @import("pty.zig");

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const HPCON = *anyopaque;
const COORD = extern struct { X: i16, Y: i16 };

const CreatePseudoConsoleFn = *const fn (COORD, HANDLE, HANDLE, DWORD, *HPCON) callconv(windows.WINAPI) windows.HRESULT;
const ResizePseudoConsoleFn = *const fn (HPCON, COORD) callconv(windows.WINAPI) windows.HRESULT;
const ClosePseudoConsoleFn = *const fn (HPCON) callconv(windows.WINAPI) void;

extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: DWORD, flags: DWORD, size: *usize) callconv(windows.WINAPI) windows.BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: DWORD, attr: usize, value: ?*anyopaque, size: usize, prev: ?*anyopaque, ret: ?*usize) callconv(windows.WINAPI) windows.BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(windows.WINAPI) void;
extern "kernel32" fn CreateEventW(attrs: ?*windows.SECURITY_ATTRIBUTES, manual: windows.BOOL, initial: windows.BOOL, name: ?[*:0]const u16) callconv(windows.WINAPI) ?HANDLE;
extern "kernel32" fn SetEvent(h: HANDLE) callconv(windows.WINAPI) windows.BOOL;

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
const STARTF_USESTDHANDLES: DWORD = 0x00000100;

const STARTUPINFOEXW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

const Api = struct {
    create: CreatePseudoConsoleFn,
    resize: ResizePseudoConsoleFn,
    close: ClosePseudoConsoleFn,
};

fn loadApi() ?Api {
    const kernel = k32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll")) orelse return null;
    const c = k32.GetProcAddress(kernel, "CreatePseudoConsole") orelse return null;
    const r = k32.GetProcAddress(kernel, "ResizePseudoConsole") orelse return null;
    const x = k32.GetProcAddress(kernel, "ClosePseudoConsole") orelse return null;
    return .{ .create = @ptrCast(c), .resize = @ptrCast(r), .close = @ptrCast(x) };
}

/// Shared with the reader / waiter threads, so it lives on the heap.
const Inner = struct {
    api: Api,
    hpc: ?HPCON = null,
    /// We write keys here; the console reads the other end.
    in_write: ?HANDLE = null,
    in_read: ?HANDLE = null,
    /// The console writes output here; the reader thread drains it.
    out_read: ?HANDLE = null,
    out_write: ?HANDLE = null,
    process: ?HANDLE = null,
    /// Loop side (polled, read) and thread side of the output socket pair.
    sock_loop: io.Fd = io.none,
    sock_thread: io.Fd = io.none,
    cancel: ?HANDLE = null,
    reader: ?std.Thread = null,
    waiter: ?std.Thread = null,
    pc_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    loop_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    exit_code: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    rows: u16 = 24,
    cols: u16 = 80,

    fn closePc(self: *Inner) void {
        if (self.pc_closed.swap(true, .seq_cst)) return;
        if (self.hpc) |h| self.api.close(h);
    }
};

pub const WinPty = struct {
    inner: *Inner,
    /// The shell's process handle (posix.pid_t is a HANDLE on Windows).
    child_pid: ?std.posix.pid_t = null,

    const alloc = std.heap.page_allocator;

    pub fn open() !WinPty {
        const api = loadApi() orelse return error.ConPtyUnavailable;
        io.ensureSockets();
        const inner = try alloc.create(Inner);
        errdefer alloc.destroy(inner);
        inner.* = .{ .api = api };
        errdefer closeHandles(inner);

        var sa = windows.SECURITY_ATTRIBUTES{ .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = windows.FALSE };
        var r: HANDLE = undefined;
        var w: HANDLE = undefined;
        try windows.CreatePipe(&r, &w, &sa);
        inner.in_read = r;
        inner.in_write = w;
        try windows.CreatePipe(&r, &w, &sa);
        inner.out_read = r;
        inner.out_write = w;
        const pair = try io.socketPair();
        inner.sock_loop = pair[0];
        inner.sock_thread = pair[1];
        // The reader must not block when the UI is inside ResizePseudoConsole
        // and therefore not reading this socket. A full socket plus a full
        // ConPTY pipe is the maximize deadlock.
        io.setNonBlocking(inner.sock_thread) catch {};
        inner.cancel = CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse return error.Unexpected;
        return .{ .inner = inner };
    }

    pub fn fd(self: WinPty) io.Fd {
        return self.inner.sock_loop;
    }

    pub fn setWindowSize(self: WinPty, rows: u16, cols: u16) !void {
        const in = self.inner;
        in.rows = @max(1, rows);
        in.cols = @max(1, cols);
        if (in.hpc) |h| {
            if (in.pc_closed.load(.seq_cst)) return;
            if (in.api.resize(h, .{ .X = @intCast(in.cols), .Y = @intCast(in.rows) }) < 0) return error.IoctlFailed;
        }
    }

    pub fn spawnShell(self: *WinPty, allocator: std.mem.Allocator, opts: pty.ShellOptions) !void {
        const in = self.inner;
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var hpc: HPCON = undefined;
        if (in.api.create(.{ .X = @intCast(in.cols), .Y = @intCast(in.rows) }, in.in_read.?, in.out_write.?, 0, &hpc) < 0)
            return error.CreatePseudoConsoleFailed;
        in.hpc = hpc;
        // The console holds its own references now.
        windows.CloseHandle(in.in_read.?);
        in.in_read = null;
        windows.CloseHandle(in.out_write.?);
        in.out_write = null;

        var attr_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        const attrs = try arena.alignedAlloc(u8, 16, attr_size);
        if (InitializeProcThreadAttributeList(attrs.ptr, 1, 0, &attr_size) == 0) return error.Unexpected;
        defer DeleteProcThreadAttributeList(attrs.ptr);
        if (UpdateProcThreadAttribute(attrs.ptr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(HPCON), null, null) == 0)
            return error.Unexpected;

        var si = std.mem.zeroes(STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        // No std handles: the child must use the pseudo console, not
        // whatever our own stdin/stdout happen to be.
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        si.lpAttributeList = attrs.ptr;

        const cmdline = try commandLine(arena, opts);
        const cmd_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, cmdline);
        const env_w = try envBlock(arena, opts.env);
        const cwd_w: ?[:0]u16 = if (opts.cwd.len > 0) blk: {
            const dir = try expandHome(arena, opts.cwd);
            std.fs.accessAbsolute(dir, .{}) catch {
                std.debug.print("deathterminal: cannot change to {s}, staying in the current directory\n", .{dir});
                break :blk null;
            };
            break :blk try std.unicode.wtf8ToWtf16LeAllocZ(arena, dir);
        } else null;

        var pi: windows.PROCESS_INFORMATION = undefined;
        if (k32.CreateProcessW(
            null,
            cmd_w.ptr,
            null,
            null,
            windows.FALSE,
            CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT,
            env_w.ptr,
            if (cwd_w) |c| c.ptr else null,
            @ptrCast(&si.StartupInfo),
            &pi,
        ) == 0) {
            std.debug.print("deathterminal: cannot run {s}\n", .{cmdline});
            return error.SpawnFailed;
        }
        windows.CloseHandle(pi.hThread);
        in.process = pi.hProcess;
        self.child_pid = pi.hProcess;

        in.reader = try std.Thread.spawn(.{}, readerMain, .{in});
        in.waiter = try std.Thread.spawn(.{}, waiterMain, .{in});
    }

    pub fn write(self: WinPty, data: []const u8) !usize {
        const h = self.inner.in_write orelse return error.BrokenPipe;
        var n: DWORD = 0;
        const len: DWORD = @intCast(@min(data.len, 1 << 20));
        if (k32.WriteFile(h, data.ptr, len, &n, null) == 0) return error.BrokenPipe;
        if (n == 0) return error.WouldBlock;
        return n;
    }

    pub fn read(self: WinPty, buffer: []u8) !usize {
        return io.read(self.inner.sock_loop, buffer);
    }

    /// Exit code once the shell is gone (read returned 0).
    pub fn exitCode(self: WinPty) u32 {
        return self.inner.exit_code.load(.seq_cst);
    }

    pub fn close(self: *WinPty) void {
        const in = self.inner;
        if (in.cancel) |c| _ = SetEvent(c);
        // Stop accepting output first so the reader never blocks on a full
        // socket while the console is shutting down.
        in.loop_closed.store(true, .seq_cst);
        io.close(in.sock_loop);
        in.sock_loop = io.none;
        in.closePc();
        if (in.waiter) |t| t.join();
        if (in.reader) |t| t.join();
        closeHandles(in);
        alloc.destroy(in);
    }

    fn closeHandles(in: *Inner) void {
        inline for (.{ "in_write", "in_read", "out_read", "out_write", "process", "cancel" }) |f| {
            if (@field(in, f)) |h| windows.CloseHandle(h);
            @field(in, f) = null;
        }
        io.close(in.sock_loop);
        in.sock_loop = io.none;
        io.close(in.sock_thread);
        in.sock_thread = io.none;
    }

    /// Bytes the reader will hold when the UI socket is full. A maximized
    /// console repaints well under this, so ResizePseudoConsole can finish
    /// while the window thread is still inside that call.
    const stash_cap: usize = 8 * 1024 * 1024;

    fn flushStash(in: *Inner, stash: *std.ArrayList(u8)) void {
        while (stash.items.len > 0) {
            const n = io.write(in.sock_thread, stash.items) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return,
            };
            if (n == 0) return;
            std.mem.copyForwards(u8, stash.items[0 .. stash.items.len - n], stash.items[n..]);
            stash.shrinkRetainingCapacity(stash.items.len - n);
        }
    }

    fn readerMain(in: *Inner) void {
        var stash = std.ArrayList(u8).init(alloc);
        defer stash.deinit();
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            flushStash(in, &stash);
            var n: DWORD = 0;
            if (k32.ReadFile(in.out_read.?, &buf, buf.len, &n, null) == 0 or n == 0) break;
            // Keep draining even after the loop went away, so a closing
            // console never blocks on a full pipe.
            if (in.loop_closed.load(.seq_cst)) continue;
            if (stash.items.len < stash_cap) stash.appendSlice(buf[0..n]) catch {};
            flushStash(in, &stash);
        }
        flushStash(in, &stash);
        // End of stream: the loop's read returns 0.
        _ = windows.ws2_32.shutdown(in.sock_thread, 1);
    }

    fn waiterMain(in: *Inner) void {
        const handles = [2]HANDLE{ in.process.?, in.cancel.? };
        const r = k32.WaitForMultipleObjects(2, &handles, windows.FALSE, windows.INFINITE);
        if (r == windows.WAIT_OBJECT_0) {
            var code: DWORD = 0;
            if (k32.GetExitCodeProcess(in.process.?, &code) != 0) in.exit_code.store(code, .seq_cst);
            // Flushes the last output, then ends the output pipe.
            in.closePc();
        }
    }
};

/// The default shell: pwsh (PowerShell 7), Windows PowerShell, %COMSPEC%.
pub fn defaultShell(arena: std.mem.Allocator) ![]const u8 {
    if (try findInPath(arena, "pwsh.exe")) |p| return p;
    if (try findInPath(arena, "powershell.exe")) |p| return p;
    if (std.process.getEnvVarOwned(arena, "COMSPEC")) |c| return c else |_| {}
    return "cmd.exe";
}

fn findInPath(arena: std.mem.Allocator, exe: []const u8) !?[]const u8 {
    const path = std.process.getEnvVarOwned(arena, "PATH") catch return null;
    var it = std.mem.tokenizeScalar(u8, path, ';');
    while (it.next()) |dir| {
        const full = try std.fs.path.join(arena, &.{ dir, exe });
        std.fs.accessAbsolute(full, .{}) catch continue;
        return full;
    }
    return null;
}

fn expandHome(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0 or path[0] != '~' or (path.len > 1 and path[1] != '/' and path[1] != '\\')) return path;
    const home = std.process.getEnvVarOwned(arena, "USERPROFILE") catch return path;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ home, path[1..] });
}

/// Program and arguments as one command line, quoted the way
/// CommandLineToArgvW / the MSVC runtime parse it.
fn commandLine(arena: std.mem.Allocator, opts: pty.ShellOptions) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    const program = if (opts.program.len > 0) try expandHome(arena, opts.program) else try defaultShell(arena);
    try quoteArg(&out, program);
    for (opts.args) |a| {
        try out.append(' ');
        try quoteArg(&out, a);
    }
    return out.items;
}

pub fn quoteArg(out: *std.ArrayList(u8), arg: []const u8) !void {
    const needs = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") != null;
    if (!needs) return out.appendSlice(arg);
    try out.append('"');
    var backslashes: usize = 0;
    for (arg) |ch| {
        if (ch == '\\') {
            backslashes += 1;
            continue;
        }
        if (ch == '"') {
            try out.appendNTimes('\\', backslashes * 2 + 1);
        } else {
            try out.appendNTimes('\\', backslashes);
        }
        backslashes = 0;
        try out.append(ch);
    }
    try out.appendNTimes('\\', backslashes * 2);
    try out.append('"');
}

/// Our environment with the terminal identity overrides and `extra`
/// (NAME=value) applied, as a UTF-16 environment block.
fn envBlock(arena: std.mem.Allocator, extra: []const []const u8) ![]u16 {
    var map = try std.process.getEnvMap(arena);
    for (pty.ChildEnv.overrides) |kv| try putKv(&map, kv);
    for (extra) |kv| try putKv(&map, kv);
    return std.process.createWindowsEnvBlock(arena, &map);
}

fn putKv(map: *std.process.EnvMap, kv: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return;
    try map.put(kv[0..eq], kv[eq + 1 ..]);
}

test "windows argument quoting" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try quoteArg(&out, "plain");
    try out.append('|');
    try quoteArg(&out, "two words");
    try out.append('|');
    try quoteArg(&out, "say \"hi\"");
    try out.append('|');
    try quoteArg(&out, "C:\\dir with space\\");
    try out.append('|');
    try quoteArg(&out, "");
    try std.testing.expectEqualStrings("plain|\"two words\"|\"say \\\"hi\\\"\"|\"C:\\dir with space\\\\\"|\"\"", out.items);
}
