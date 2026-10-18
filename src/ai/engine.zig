//! Background AI worker.
//!
//! One thread runs one request at a time. The UI thread `submit`s a job
//! (which cancels whatever is running: a new keystroke makes the old
//! suggestion useless), then polls `wakeFd` and calls `take` to collect
//! streamed text. Nothing here blocks the UI thread except a short mutex.
//!
//! When the endpoint is unreachable the engine marks itself offline and
//! stops trying suggestion requests for a while (5 s, doubling to 60 s);
//! explicit requests (explain) always try. Errors never surface as
//! dialogs: the UI shows a small status tag instead.

const std = @import("std");
const posix = std.posix;
const openai = @import("openai.zig");

pub const Kind = enum { suggest, explain };

pub const Status = enum(u8) {
    /// Nothing has failed (or the last request worked).
    ready,
    /// The last request failed; see `statusText`.
    offline,
};

pub const Options = struct {
    endpoint: []const u8,
    model: []const u8,
    /// Environment variable holding the API key ("" = none). Read at
    /// request time; the key is never copied into the config.
    api_key_env: []const u8 = "",
    timeout_ms: u32 = 5000,
};

pub const Update = struct {
    gen: u64,
    kind: Kind,
    /// All text streamed so far (owned by the caller).
    text: []u8,
    done: bool,
    failed: ?openai.Error,
};

const Job = struct {
    arena: std.heap.ArenaAllocator,
    gen: u64,
    kind: Kind,
    messages: []openai.Message,
    max_tokens: u32,
    /// Stop streaming after this many complete lines (0 = no limit).
    max_lines: usize,

    fn deinit(self: *Job) void {
        self.arena.deinit();
    }
};

pub const min_backoff_ms = 5_000;
pub const max_backoff_ms = 60_000;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    quit: bool = false,

    opts_arena: std.heap.ArenaAllocator,
    opts: Options,

    pending: ?Job = null,
    /// Generation of the newest submitted job (or cancel).
    gen: u64 = 0,
    cancel: openai.Cancel = .{},

    result: std.ArrayList(u8),
    result_gen: u64 = 0,
    result_kind: Kind = .suggest,
    result_done: bool = false,
    result_err: ?openai.Error = null,
    result_dirty: bool = false,

    wake_r: posix.fd_t,
    wake_w: posix.fd_t,

    status: Status = .ready,
    status_buf: [96]u8 = undefined,
    status_len: usize = 0,
    backoff_ms: u32 = 0,
    retry_at_ms: i64 = 0,
    /// Requests actually sent (tests).
    requests: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, opts: Options) !*Engine {
        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);
        const fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        self.* = .{
            .allocator = allocator,
            .opts_arena = std.heap.ArenaAllocator.init(allocator),
            .opts = undefined,
            .result = std.ArrayList(u8).init(allocator),
            .wake_r = fds[0],
            .wake_w = fds[1],
        };
        self.opts = try copyOptions(self.opts_arena.allocator(), opts);
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
        return self;
    }

    pub fn deinit(self: *Engine) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.quit = true;
            self.cancel.cancel();
            self.cond.signal();
        }
        if (self.thread) |th| th.join();
        if (self.pending) |*p| p.deinit();
        self.result.deinit();
        self.opts_arena.deinit();
        posix.close(self.wake_r);
        posix.close(self.wake_w);
        self.allocator.destroy(self);
    }

    fn copyOptions(a: std.mem.Allocator, o: Options) !Options {
        return .{
            .endpoint = try a.dupe(u8, o.endpoint),
            .model = try a.dupe(u8, o.model),
            .api_key_env = try a.dupe(u8, o.api_key_env),
            .timeout_ms = o.timeout_ms,
        };
    }

    /// New endpoint/model/... (config reload). Clears the offline state so
    /// the new settings are tried right away.
    pub fn setOptions(self: *Engine, opts: Options) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const copy = try copyOptions(arena.allocator(), opts);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.opts_arena.deinit();
        self.opts_arena = arena;
        self.opts = copy;
        self.status = .ready;
        self.backoff_ms = 0;
        self.retry_at_ms = 0;
    }

    /// Queue a request, replacing (and cancelling) any earlier one.
    /// Returns its generation, which `Update.gen` echoes.
    pub fn submit(self: *Engine, kind: Kind, messages: []const openai.Message, max_tokens: u32, max_lines: usize) !u64 {
        var job = Job{
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .gen = 0,
            .kind = kind,
            .messages = undefined,
            .max_tokens = max_tokens,
            .max_lines = max_lines,
        };
        errdefer job.deinit();
        const a = job.arena.allocator();
        job.messages = try a.alloc(openai.Message, messages.len);
        for (messages, job.messages) |m, *dst| dst.* = .{ .role = try a.dupe(u8, m.role), .content = try a.dupe(u8, m.content) };

        self.mutex.lock();
        defer self.mutex.unlock();
        self.gen += 1;
        job.gen = self.gen;
        if (self.pending) |*p| p.deinit();
        self.pending = job;
        self.cancel.cancel();
        self.cond.signal();
        return job.gen;
    }

    /// Drop the queued job and abort the running one (e.g. on a keystroke).
    pub fn cancelAll(self: *Engine) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.gen += 1;
        if (self.pending) |*p| p.deinit();
        self.pending = null;
        self.cancel.cancel();
        self.result_dirty = false;
    }

    /// Readable when `take` may have something.
    pub fn wakeFd(self: *const Engine) posix.fd_t {
        return self.wake_r;
    }

    /// Collect the latest streamed state of the newest job, if it changed.
    pub fn take(self: *Engine, allocator: std.mem.Allocator) !?Update {
        var drain: [64]u8 = undefined;
        while (true) {
            const n = posix.read(self.wake_r, &drain) catch break;
            if (n < drain.len) break;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.result_dirty or self.result_gen != self.gen) return null;
        self.result_dirty = false;
        return .{
            .gen = self.result_gen,
            .kind = self.result_kind,
            .text = try allocator.dupe(u8, self.result.items),
            .done = self.result_done,
            .failed = self.result_err,
        };
    }

    pub fn getStatus(self: *Engine) Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.status;
    }

    /// Why the engine is offline ("connection refused", "HTTP 404", ...).
    pub fn statusText(self: *Engine, buf: []u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(buf.len, self.status_len);
        @memcpy(buf[0..n], self.status_buf[0..n]);
        return buf[0..n];
    }

    fn wake(self: *Engine) void {
        _ = posix.write(self.wake_w, "x") catch {};
    }

    const Sink = struct {
        engine: *Engine,
        gen: u64,
        max_lines: usize,

        pub fn onDelta(s: Sink, text: []const u8) bool {
            const e = s.engine;
            e.mutex.lock();
            defer e.mutex.unlock();
            if (e.gen != s.gen or e.quit) return false;
            e.result.appendSlice(text) catch return false;
            e.result_dirty = true;
            e.wake();
            if (s.max_lines > 0 and std.mem.count(u8, e.result.items, "\n") >= s.max_lines) return false;
            return true;
        }
    };

    fn worker(self: *Engine) void {
        while (true) {
            var job: Job = undefined;
            var opts: Options = undefined;
            var opts_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer opts_arena.deinit();
            var skip_offline = false;
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                while (self.pending == null and !self.quit) self.cond.wait(&self.mutex);
                if (self.quit) return;
                job = self.pending.?;
                self.pending = null;
                self.cancel.reset();
                self.result.clearRetainingCapacity();
                self.result_gen = job.gen;
                self.result_kind = job.kind;
                self.result_done = false;
                self.result_err = null;
                self.result_dirty = false;
                opts = copyOptions(opts_arena.allocator(), self.opts) catch {
                    job.deinit();
                    continue;
                };
                skip_offline = job.kind == .suggest and self.status == .offline and std.time.milliTimestamp() < self.retry_at_ms;
            }
            defer job.deinit();

            var err: ?openai.Error = null;
            if (skip_offline) {
                err = error.Offline;
            } else {
                @atomicStore(u64, &self.requests, self.requests + 1, .seq_cst);
                const key: ?[]const u8 = if (opts.api_key_env.len > 0) posix.getenv(opts.api_key_env) else null;
                openai.chatStream(self.allocator, .{
                    .endpoint = opts.endpoint,
                    .model = opts.model,
                    .api_key = key,
                    .messages = job.messages,
                    .max_tokens = job.max_tokens,
                    .timeout_ms = opts.timeout_ms,
                }, &self.cancel, Sink{ .engine = self, .gen = job.gen, .max_lines = job.max_lines }) catch |e| {
                    err = e;
                };
            }

            self.mutex.lock();
            defer self.mutex.unlock();
            if (err) |e| if (e == error.Cancelled) continue;
            if (!skip_offline) self.noteOutcome(err);
            if (self.gen != job.gen) continue;
            self.result_done = true;
            self.result_err = err;
            self.result_dirty = true;
            self.wake();
        }
    }

    /// Update the offline state after a request (mutex held).
    fn noteOutcome(self: *Engine, err: ?openai.Error) void {
        const e = err orelse {
            self.status = .ready;
            self.backoff_ms = 0;
            self.status_len = 0;
            return;
        };
        self.status = .offline;
        self.backoff_ms = if (self.backoff_ms == 0) min_backoff_ms else @min(self.backoff_ms * 2, max_backoff_ms);
        self.retry_at_ms = std.time.milliTimestamp() + self.backoff_ms;
        const text = switch (e) {
            error.Offline => "endpoint unreachable",
            error.Timeout => "request timed out",
            error.BadEndpoint => "bad ai.endpoint",
            error.HttpStatus => std.fmt.bufPrint(&self.status_buf, "HTTP {d}", .{openai.last_status}) catch "HTTP error",
            error.ApiError => "the API returned an error",
            error.BadResponse => "unexpected response",
            error.OutOfMemory => "out of memory",
            error.Cancelled => unreachable,
        };
        if (text.ptr != &self.status_buf) std.mem.copyForwards(u8, &self.status_buf, text);
        self.status_len = text.len;
    }
};

// ------------------------------------------------------------------ tests

const mock = @import("mock_server.zig");
const t = std.testing;

fn waitDone(e: *Engine, gen: u64, timeout_ms: i64) !Update {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        var fds = [_]posix.pollfd{.{ .fd = e.wakeFd(), .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 50);
        if (try e.take(t.allocator)) |u| {
            if (u.gen == gen and u.done) return u;
            t.allocator.free(u.text);
        }
    }
    return error.TestTimeout;
}

const msgs = [_]openai.Message{.{ .role = "user", .content = "hi" }};

test "engine streams a suggestion from the mock server" {
    const replies = [_]mock.Reply{.{ .chunks = mock.sse(&.{ "git push", "\\ngit pull\\n", "git status\\n", "never" }) }};
    const srv = try mock.MockServer.start(t.allocator, &replies);
    defer srv.deinit();
    var buf: [64]u8 = undefined;
    const e = try Engine.init(t.allocator, .{ .endpoint = srv.url(&buf), .model = "m" });
    defer e.deinit();
    const g = try e.submit(.suggest, &msgs, 32, 2);
    const u = try waitDone(e, g, 3000);
    defer t.allocator.free(u.text);
    try t.expect(u.failed == null);
    // Stopped after two complete lines.
    try t.expectEqualStrings("git push\ngit pull\n", u.text);
    try t.expectEqual(Status.ready, e.getStatus());
}

test "engine: a new submit cancels the running request" {
    const replies = [_]mock.Reply{
        .{ .chunks = mock.sse(&.{ "slow", "er" }), .delay_ms = 1500 },
        .{ .chunks = mock.sse(&.{"fast"}) },
    };
    const srv = try mock.MockServer.start(t.allocator, &replies);
    defer srv.deinit();
    var buf: [64]u8 = undefined;
    const e = try Engine.init(t.allocator, .{ .endpoint = srv.url(&buf), .model = "m" });
    defer e.deinit();
    _ = try e.submit(.suggest, &msgs, 32, 0);
    std.time.sleep(150 * std.time.ns_per_ms);
    const start = std.time.milliTimestamp();
    const g2 = try e.submit(.suggest, &msgs, 32, 0);
    const u = try waitDone(e, g2, 3000);
    defer t.allocator.free(u.text);
    try t.expectEqualStrings("fast", u.text);
    try t.expect(std.time.milliTimestamp() - start < 1200);
}

test "engine: offline endpoint degrades with backoff, explain still tries" {
    // Grab a free port, then close it so nothing listens there.
    const srv = try mock.MockServer.start(t.allocator, &.{});
    var buf: [64]u8 = undefined;
    const url = try t.allocator.dupe(u8, srv.url(&buf));
    defer t.allocator.free(url);
    srv.deinit();
    const e = try Engine.init(t.allocator, .{ .endpoint = url, .model = "m" });
    defer e.deinit();
    const g1 = try e.submit(.suggest, &msgs, 32, 0);
    const r1 = try waitDone(e, g1, 3000);
    t.allocator.free(r1.text);
    try t.expectEqual(@as(?openai.Error, error.Offline), r1.failed);
    try t.expectEqual(Status.offline, e.getStatus());
    var sbuf: [96]u8 = undefined;
    try t.expectEqualStrings("endpoint unreachable", e.statusText(&sbuf));
    // Within the backoff window suggestion requests are not even sent.
    const g2 = try e.submit(.suggest, &msgs, 32, 0);
    const r2 = try waitDone(e, g2, 3000);
    t.allocator.free(r2.text);
    try t.expectEqual(@as(u64, 1), e.requests);
    // An explicit request is.
    const g3 = try e.submit(.explain, &msgs, 32, 0);
    const r3 = try waitDone(e, g3, 3000);
    t.allocator.free(r3.text);
    try t.expectEqual(@as(u64, 2), e.requests);
    // New options reset the offline state.
    try e.setOptions(.{ .endpoint = url, .model = "other" });
    try t.expectEqual(Status.ready, e.getStatus());
}

test "engine: the API key comes from the named environment variable" {
    const replies = [_]mock.Reply{.{ .chunks = mock.sse(&.{"ok"}) }};
    const srv = try mock.MockServer.start(t.allocator, &replies);
    defer srv.deinit();
    var buf: [64]u8 = undefined;
    // HOME is set in any sane test environment, so it stands in for a key variable here.
    const e = try Engine.init(t.allocator, .{ .endpoint = srv.url(&buf), .model = "m", .api_key_env = "HOME" });
    defer e.deinit();
    const g = try e.submit(.suggest, &msgs, 32, 0);
    const u = try waitDone(e, g, 3000);
    t.allocator.free(u.text);
    srv.mutex.lock();
    defer srv.mutex.unlock();
    const want = try std.fmt.allocPrint(t.allocator, "authorization: Bearer {s}", .{posix.getenv("HOME").?});
    defer t.allocator.free(want);
    try t.expect(std.ascii.indexOfIgnoreCase(srv.requests.items[0], want) != null);
}
