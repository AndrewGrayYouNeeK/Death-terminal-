//! Background work for plugins: HTTP requests and allowlisted programs.
//!
//! Each job runs on its own thread and never touches a plugin or its Lua
//! state; it only fills in a `Done` record and pushes it onto a `Queue`
//! shared with the host (reference counted, so a job that outlives the host
//! still has somewhere to put its result). The queue's pipe wakes the event
//! loop's poll.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const io = @import("../platform/io.zig");

const ca = std.heap.c_allocator;

pub const max_body = 1024 * 1024;
pub const max_output = 1024 * 1024;

pub const Kind = enum { http, exec };

/// A finished job. Memory is owned (c_allocator); free with `deinit`.
pub const Done = struct {
    id: u32,
    kind: Kind,
    /// Empty on success, else what went wrong ("timed out", "connection refused"...).
    err: []u8 = &.{},
    /// HTTP status, or the program's exit code (-1 if killed by a signal).
    status: i64 = 0,
    /// HTTP body, or the program's stdout.
    body: []u8 = &.{},
    stderr: []u8 = &.{},
    truncated: bool = false,

    pub fn deinit(self: *Done) void {
        ca.free(self.err);
        ca.free(self.body);
        ca.free(self.stderr);
    }
};

pub const Queue = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayListUnmanaged(Done) = .{},
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    wake: io.Wake,

    pub fn create() !*Queue {
        const q = try ca.create(Queue);
        errdefer ca.destroy(q);
        q.* = .{ .wake = try io.Wake.init() };
        return q;
    }

    pub fn retain(self: *Queue) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Queue) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.items.items) |*d| d.deinit();
        self.items.deinit(ca);
        self.wake.deinit();
        ca.destroy(self);
    }

    pub fn wakeFd(self: *const Queue) io.Fd {
        return self.wake.fd();
    }

    pub fn push(self: *Queue, done: Done) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.items.append(ca, done) catch {
            var d = done;
            d.deinit();
            return;
        };
        self.wake.signal();
    }

    /// Moves every finished job into `out` (caller frees each with deinit).
    pub fn take(self: *Queue, out: *std.ArrayList(Done)) void {
        self.wake.drain();
        self.mutex.lock();
        defer self.mutex.unlock();
        out.appendSlice(self.items.items) catch return;
        self.items.clearRetainingCapacity();
    }
};

fn errText(comptime fmt: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(ca, fmt, args) catch &.{};
}

// ---------------------------------------------------------------- http

pub const HttpRequest = struct {
    method: std.http.Method = .GET,
    url: []const u8,
    /// "Name: value" header lines.
    headers: []const std.http.Header = &.{},
    body: ?[]const u8 = null,
};

/// Starts `req` on a new thread (everything is copied first).
pub fn startHttp(q: *Queue, id: u32, req: HttpRequest) !void {
    const job = try ca.create(HttpJob);
    errdefer ca.destroy(job);
    job.* = .{ .q = q, .id = id, .arena = std.heap.ArenaAllocator.init(ca), .req = undefined };
    errdefer job.arena.deinit();
    const a = job.arena.allocator();
    const hs = try a.alloc(std.http.Header, req.headers.len);
    for (req.headers, hs) |h, *o| o.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
    job.req = .{
        .method = req.method,
        .url = try a.dupe(u8, req.url),
        .headers = hs,
        .body = if (req.body) |b| try a.dupe(u8, b) else null,
    };
    q.retain();
    errdefer q.release();
    const t = try std.Thread.spawn(.{}, HttpJob.run, .{job});
    t.detach();
}

const HttpJob = struct {
    q: *Queue,
    id: u32,
    arena: std.heap.ArenaAllocator,
    req: HttpRequest,

    fn run(self: *HttpJob) void {
        var done = Done{ .id = self.id, .kind = .http };
        self.fetch(&done);
        const q = self.q;
        self.arena.deinit();
        ca.destroy(self);
        q.push(done);
        q.release();
    }

    fn fetch(self: *HttpJob, done: *Done) void {
        var client = std.http.Client{ .allocator = ca };
        defer client.deinit();
        var body = std.ArrayList(u8).init(ca);
        defer body.deinit();
        const res = client.fetch(.{
            .location = .{ .url = self.req.url },
            .method = self.req.method,
            .payload = self.req.body,
            .extra_headers = self.req.headers,
            .redirect_behavior = .not_allowed,
            .response_storage = .{ .dynamic = &body },
            .max_append_size = max_body,
            .keep_alive = false,
        }) catch |err| {
            done.err = switch (err) {
                error.TooManyHttpRedirects => errText("redirects are not followed", .{}),
                error.StreamTooLong => errText("response larger than {d} KiB", .{max_body / 1024}),
                error.ConnectionRefused => errText("connection refused", .{}),
                error.UnknownHostName => errText("unknown host", .{}),
                else => errText("{s}", .{@errorName(err)}),
            };
            return;
        };
        done.status = @intFromEnum(res.status);
        done.body = body.toOwnedSlice() catch &.{};
    }
};

// ---------------------------------------------------------------- exec

pub const ExecRequest = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    stdin: ?[]const u8 = null,
    timeout_ms: u32 = 10_000,
};

pub fn startExec(q: *Queue, id: u32, req: ExecRequest) !void {
    const job = try ca.create(ExecJob);
    errdefer ca.destroy(job);
    job.* = .{ .q = q, .id = id, .arena = std.heap.ArenaAllocator.init(ca), .req = undefined };
    errdefer job.arena.deinit();
    const a = job.arena.allocator();
    const argv = try a.alloc([]const u8, req.argv.len);
    for (req.argv, argv) |s, *o| o.* = try a.dupe(u8, s);
    job.req = .{
        .argv = argv,
        .cwd = if (req.cwd) |d| try a.dupe(u8, d) else null,
        .stdin = if (req.stdin) |s| try a.dupe(u8, s) else null,
        .timeout_ms = req.timeout_ms,
    };
    q.retain();
    errdefer q.release();
    const t = try std.Thread.spawn(.{}, ExecJob.run, .{job});
    t.detach();
}

const ExecJob = struct {
    q: *Queue,
    id: u32,
    arena: std.heap.ArenaAllocator,
    req: ExecRequest,

    fn run(self: *ExecJob) void {
        var done = Done{ .id = self.id, .kind = .exec };
        self.exec(&done) catch |err| {
            if (done.err.len == 0) done.err = errText("{s}", .{switch (err) {
                error.FileNotFound => "program not found",
                error.AccessDenied => "permission denied",
                else => @errorName(err),
            }});
        };
        const q = self.q;
        self.arena.deinit();
        ca.destroy(self);
        q.push(done);
        q.release();
    }

    fn exec(self: *ExecJob, done: *Done) !void {
        var child = std.process.Child.init(self.req.argv, ca);
        child.stdin_behavior = if (self.req.stdin != null) .Pipe else .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        if (self.req.cwd) |d| {
            if (d.len > 0) child.cwd = d;
        }
        try child.spawn();
        if (child.stdin) |*sin| {
            sin.writeAll(self.req.stdin.?) catch {};
            sin.close();
            child.stdin = null;
        }
        var out = std.ArrayList(u8).init(ca);
        defer out.deinit();
        var err_out = std.ArrayList(u8).init(ca);
        defer err_out.deinit();
        if (builtin.os.tag == .windows) return self.execWindows(&child, done, &out, &err_out);
        const deadline = std.time.milliTimestamp() + self.req.timeout_ms;
        var fds = [2]posix.pollfd{
            .{ .fd = child.stdout.?.handle, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = child.stderr.?.handle, .events = posix.POLL.IN, .revents = 0 },
        };
        var open: usize = 2;
        var timed_out = false;
        while (open > 0) {
            const left = deadline - std.time.milliTimestamp();
            if (left <= 0) {
                timed_out = true;
                break;
            }
            _ = posix.poll(&fds, @intCast(@min(left, 1000))) catch break;
            for (&fds, 0..) |*f, i| {
                if (f.fd < 0 or f.revents == 0) continue;
                var buf: [8192]u8 = undefined;
                const n = posix.read(f.fd, &buf) catch 0;
                if (n == 0) {
                    f.fd = -1;
                    open -= 1;
                    continue;
                }
                const dst = if (i == 0) &out else &err_out;
                const room = max_output -| dst.items.len;
                if (n > room) done.truncated = true;
                dst.appendSlice(buf[0..@min(n, room)]) catch {};
            }
        }
        if (timed_out) {
            _ = child.kill() catch {};
            done.err = errText("timed out after {d} ms", .{self.req.timeout_ms});
        } else {
            const term = try child.wait();
            done.status = switch (term) {
                .Exited => |code| code,
                else => -1,
            };
        }
        done.body = try out.toOwnedSlice();
        done.stderr = try err_out.toOwnedSlice();
    }

    /// Windows: pipes can't be polled, so std's overlapped collectOutput
    /// reads both streams and a watchdog thread kills the child at the
    /// deadline.
    fn execWindows(self: *ExecJob, child: *std.process.Child, done: *Done, out: *std.ArrayList(u8), err_out: *std.ArrayList(u8)) !void {
        const Watchdog = struct {
            ev: std.Thread.ResetEvent = .{},
            fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            fn run(wd: *@This(), c: *std.process.Child, ms: u32) void {
                wd.ev.timedWait(@as(u64, ms) * std.time.ns_per_ms) catch {
                    wd.fired.store(true, .seq_cst);
                    _ = std.os.windows.kernel32.TerminateProcess(c.id, 1);
                };
            }
        };
        var wd = Watchdog{};
        const t = try std.Thread.spawn(.{}, Watchdog.run, .{ &wd, child, self.req.timeout_ms });
        child.collectOutput(out, err_out, max_output) catch |err| switch (err) {
            error.StdoutStreamTooLong, error.StderrStreamTooLong => done.truncated = true,
            else => {},
        };
        const term = child.wait() catch std.process.Child.Term{ .Unknown = 0 };
        wd.ev.set();
        t.join();
        if (wd.fired.load(.seq_cst)) {
            done.err = errText("timed out after {d} ms", .{self.req.timeout_ms});
        } else done.status = switch (term) {
            .Exited => |code| code,
            else => -1,
        };
        done.body = try out.toOwnedSlice();
        done.stderr = try err_out.toOwnedSlice();
    }
};

fn waitFor(q: *Queue, n: usize, out: *std.ArrayList(Done)) !void {
    const deadline = std.time.milliTimestamp() + 10_000;
    while (out.items.len < n) {
        if (std.time.milliTimestamp() > deadline) return error.Timeout;
        var pfd = [1]io.PollFd{io.pollFd(q.wakeFd(), io.POLL.IN)};
        _ = io.poll(&pfd, 100);
        q.take(out);
    }
}

test "exec jobs report output, exit codes and timeouts" {
    const q = try Queue.create();
    defer q.release();
    try startExec(q, 1, .{ .argv = &.{ "sh", "-c", "echo hi; echo err >&2; exit 3" } });
    try startExec(q, 2, .{ .argv = &.{ "sleep", "5" }, .timeout_ms = 100 });
    try startExec(q, 3, .{ .argv = &.{"/nonexistent/prog"} });
    var out = std.ArrayList(Done).init(std.testing.allocator);
    defer {
        for (out.items) |*d| d.deinit();
        out.deinit();
    }
    try waitFor(q, 3, &out);
    for (out.items) |d| switch (d.id) {
        1 => {
            try std.testing.expectEqual(@as(i64, 3), d.status);
            try std.testing.expectEqualStrings("hi\n", d.body);
            try std.testing.expectEqualStrings("err\n", d.stderr);
            try std.testing.expectEqual(@as(usize, 0), d.err.len);
        },
        2 => try std.testing.expect(std.mem.startsWith(u8, d.err, "timed out")),
        3 => try std.testing.expectEqualStrings("program not found", d.err),
        else => unreachable,
    };
}

test "http jobs fetch without following redirects" {
    const mock = @import("../ai/mock_server.zig");
    const srv = try mock.MockServer.start(std.testing.allocator, &.{
        .{ .content_type = "text/plain", .chunks = &.{"hello"} },
        .{ .head = "HTTP/1.1 302 Found\r\nLocation: http://example.com/\r\nContent-Length: 0\r\n\r\n" },
    });
    defer srv.deinit();
    const q = try Queue.create();
    defer q.release();
    var ub: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/x", .{srv.port});
    try startHttp(q, 7, .{ .url = url });
    var out = std.ArrayList(Done).init(std.testing.allocator);
    defer {
        for (out.items) |*d| d.deinit();
        out.deinit();
    }
    try waitFor(q, 1, &out);
    try startHttp(q, 8, .{ .url = url, .method = .POST, .body = "{}" });
    try waitFor(q, 2, &out);
    try std.testing.expectEqual(@as(i64, 200), out.items[0].status);
    try std.testing.expectEqualStrings("hello", out.items[0].body);
    const r = out.items[1];
    try std.testing.expect(r.err.len > 0 or r.status == 302);
}
