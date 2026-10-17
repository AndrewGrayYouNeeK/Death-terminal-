//! Minimal OpenAI-compatible chat/completions client with SSE streaming
//! (Ollama, llama.cpp server, vLLM, LM Studio, OpenAI, ...). Plain
//! HTTP/1.1 JSON over std.http.Client; https works through std's TLS.
//!
//! Blocking by design: it runs on the AI worker thread. `Cancel` aborts an
//! in-flight request from another thread by shutting the socket down, and
//! a receive timeout bounds every read.

const std = @import("std");
const posix = std.posix;

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub const Request = struct {
    /// Base URL ending in the API root, e.g. "http://localhost:11434/v1".
    endpoint: []const u8,
    model: []const u8,
    /// Sent as "Authorization: Bearer ..." when set.
    api_key: ?[]const u8 = null,
    messages: []const Message,
    max_tokens: u32 = 64,
    temperature: f32 = 0.2,
    /// Whole request deadline (connect excluded, see docs/AI.md).
    timeout_ms: u32 = 5000,
};

pub const Error = error{
    Cancelled,
    /// Nothing listening / host unreachable / name lookup failed.
    Offline,
    Timeout,
    BadEndpoint,
    HttpStatus,
    BadResponse,
    ApiError,
} || std.mem.Allocator.Error;

/// Shared between the worker and whoever wants to cancel it.
pub const Cancel = struct {
    mutex: std.Thread.Mutex = .{},
    fd: ?posix.socket_t = null,
    cancelled: bool = false,

    pub fn cancel(self: *Cancel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelled = true;
        if (self.fd) |fd| posix.shutdown(fd, .both) catch {};
    }

    pub fn reset(self: *Cancel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelled = false;
        self.fd = null;
    }

    pub fn isCancelled(self: *Cancel) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancelled;
    }

    fn attach(self: *Cancel, fd: posix.socket_t) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cancelled) return false;
        self.fd = fd;
        return true;
    }

    fn detach(self: *Cancel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.fd = null;
    }
};

/// Status code of the last `HttpStatus` failure (for logs).
pub threadlocal var last_status: u16 = 0;

/// POST {endpoint}/chat/completions with stream=true and call
/// `sink.onDelta(text)` for every content fragment. `sink.onDelta` may
/// return false to stop early. Servers that ignore `stream` and answer
/// with plain JSON are handled too.
pub fn chatStream(allocator: std.mem.Allocator, req: Request, cancel: *Cancel, sink: anytype) Error!void {
    var url_buf: [1024]u8 = undefined;
    const base = std.mem.trimRight(u8, req.endpoint, "/");
    const url = std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{base}) catch return error.BadEndpoint;
    const uri = std.Uri.parse(url) catch return error.BadEndpoint;

    const body = try buildBody(allocator, req);
    defer allocator.free(body);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var header_buf: [16 * 1024]u8 = undefined;
    var auth_buf: [512]u8 = undefined;
    var auth: std.http.Client.Request.Headers.Value = .omit;
    if (req.api_key) |k| if (k.len > 0) {
        auth = .{ .override = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{k}) catch return error.BadEndpoint };
    };
    if (cancel.isCancelled()) return error.Cancelled;
    const deadline = std.time.milliTimestamp() + req.timeout_ms;

    var r = client.open(.POST, uri, .{
        .server_header_buffer = &header_buf,
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "DeathTerminal" },
            .accept_encoding = .omit,
            .authorization = auth,
        },
        .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream, application/json" }},
    }) catch |err| return mapErr(err, cancel, deadline);
    defer r.deinit();
    const fd = r.connection.?.stream.handle;
    if (!cancel.attach(fd)) return error.Cancelled;
    defer cancel.detach();
    setTimeout(fd, req.timeout_ms);

    r.transfer_encoding = .{ .content_length = body.len };
    r.send() catch |err| return mapErr(err, cancel, deadline);
    r.writeAll(body) catch |err| return mapErr(err, cancel, deadline);
    r.finish() catch |err| return mapErr(err, cancel, deadline);
    r.wait() catch |err| return mapErr(err, cancel, deadline);
    if (r.response.status != .ok) {
        last_status = @intFromEnum(r.response.status);
        return error.HttpStatus;
    }
    const sse = if (r.response.content_type) |ct| std.mem.indexOf(u8, ct, "event-stream") != null else false;

    var parser = SseParser.init(allocator);
    defer parser.deinit();
    var whole = std.ArrayList(u8).init(allocator);
    defer whole.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const left = deadline - std.time.milliTimestamp();
        if (left <= 0) return error.Timeout;
        setTimeout(fd, @intCast(left));
        const n = r.read(&buf) catch |err| return mapErr(err, cancel, deadline);
        if (n == 0) break;
        if (sse) {
            if (!try parser.feed(buf[0..n], sink)) return;
        } else {
            if (whole.items.len + n > 1024 * 1024) return error.BadResponse;
            try whole.appendSlice(buf[0..n]);
        }
    }
    if (cancel.isCancelled()) return error.Cancelled;
    if (sse) {
        _ = try parser.feed("\n", sink);
        return;
    }
    // Non-streaming reply.
    try handlePayload(allocator, whole.items, sink);
}

fn setTimeout(fd: posix.socket_t, ms: u32) void {
    const tv = posix.timeval{ .tv_sec = @intCast(ms / 1000), .tv_usec = @intCast((ms % 1000) * 1000) };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
}

fn mapErr(err: anyerror, cancel: *Cancel, deadline: i64) Error {
    if (cancel.isCancelled()) return error.Cancelled;
    // A receive timeout surfaces as EAGAIN, which some std paths report
    // as UnexpectedReadFailure.
    if (std.time.milliTimestamp() >= deadline - 20) return error.Timeout;
    return switch (err) {
        error.WouldBlock, error.ConnectionTimedOut => error.Timeout,
        error.ConnectionRefused, error.NetworkUnreachable, error.UnknownHostName, error.TemporaryNameServerFailure, error.NameServerFailure, error.HostLacksNetworkAddresses, error.AddressNotAvailable => error.Offline,
        error.UnsupportedUriScheme, error.UriMissingHost, error.InvalidFormat => error.BadEndpoint,
        error.OutOfMemory => error.OutOfMemory,
        else => blk: {
            std.log.debug("ai: request failed: {s}", .{@errorName(err)});
            break :blk error.BadResponse;
        },
    };
}

fn buildBody(allocator: std.mem.Allocator, req: Request) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try std.json.stringify(.{
        .model = req.model,
        .messages = req.messages,
        .stream = true,
        .max_tokens = req.max_tokens,
        .temperature = req.temperature,
    }, .{}, out.writer());
    return out.toOwnedSlice();
}

const Chunk = struct {
    choices: []const struct {
        delta: ?struct { content: ?[]const u8 = null } = null,
        message: ?struct { content: ?[]const u8 = null } = null,
        text: ?[]const u8 = null,
    } = &.{},
    @"error": ?std.json.Value = null,
};

fn handlePayload(allocator: std.mem.Allocator, payload: []const u8, sink: anytype) Error!void {
    const parsed = std.json.parseFromSlice(Chunk, allocator, payload, .{ .ignore_unknown_fields = true }) catch return error.BadResponse;
    defer parsed.deinit();
    if (parsed.value.@"error" != null) return error.ApiError;
    for (parsed.value.choices) |ch| {
        const text = if (ch.delta) |d| d.content else if (ch.message) |m| m.content else ch.text;
        if (text) |t| if (t.len > 0) {
            if (!sink.onDelta(t)) return;
        };
        break; // first choice only
    }
}

/// Splits a text/event-stream body into `data:` payloads.
pub const SseParser = struct {
    allocator: std.mem.Allocator,
    line: std.ArrayList(u8),
    done: bool = false,

    pub fn init(allocator: std.mem.Allocator) SseParser {
        return .{ .allocator = allocator, .line = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *SseParser) void {
        self.line.deinit();
    }

    /// Returns false once the stream is finished ([DONE] or sink stop).
    pub fn feed(self: *SseParser, data: []const u8, sink: anytype) Error!bool {
        if (self.done) return false;
        for (data) |b| {
            if (b != '\n') {
                if (self.line.items.len > 256 * 1024) return error.BadResponse;
                try self.line.append(b);
                continue;
            }
            const line = std.mem.trimRight(u8, self.line.items, "\r");
            defer self.line.clearRetainingCapacity();
            if (!std.mem.startsWith(u8, line, "data:")) continue; // comments, event:, id:
            const payload = std.mem.trim(u8, line["data:".len..], " ");
            if (std.mem.eql(u8, payload, "[DONE]")) {
                self.done = true;
                return false;
            }
            var stop = false;
            const Wrap = struct {
                inner: @TypeOf(sink),
                stop: *bool,
                pub fn onDelta(w: @This(), t: []const u8) bool {
                    const keep = w.inner.onDelta(t);
                    if (!keep) w.stop.* = true;
                    return keep;
                }
            };
            try handlePayload(self.allocator, payload, Wrap{ .inner = sink, .stop = &stop });
            if (stop) {
                self.done = true;
                return false;
            }
        }
        return true;
    }
};

// ------------------------------------------------------------------ tests

const Collect = struct {
    out: *std.ArrayList(u8),
    limit: usize = std.math.maxInt(usize),
    pub fn onDelta(self: Collect, t: []const u8) bool {
        self.out.appendSlice(t) catch return false;
        return self.out.items.len < self.limit;
    }
};

test "sse parser: deltas across chunk boundaries, comments, [DONE]" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    const c = Collect{ .out = &out };
    try std.testing.expect(try p.feed(": keepalive\n\ndata: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\ndata: {\"choi", c));
    try std.testing.expect(try p.feed("ces\":[{\"delta\":{\"content\":\"git \"}}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"status\"}}]}\n\n", c));
    try std.testing.expect(!try p.feed("data: [DONE]\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n", c));
    try std.testing.expectEqualStrings("git status", out.items);
}

test "sse parser: error payload and garbage" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.ApiError, p.feed("data: {\"error\":{\"message\":\"model not found\"}}\n", Collect{ .out = &out }));
    var q = SseParser.init(std.testing.allocator);
    defer q.deinit();
    try std.testing.expectError(error.BadResponse, q.feed("data: {not json\n", Collect{ .out = &out }));
}

test "request body is valid JSON with stream=true" {
    const msgs = [_]Message{ .{ .role = "system", .content = "s \"q\"" }, .{ .role = "user", .content = "u\n" } };
    const body = try buildBody(std.testing.allocator, .{ .endpoint = "x", .model = "m", .messages = &msgs, .max_tokens = 7 });
    defer std.testing.allocator.free(body);
    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer v.deinit();
    try std.testing.expect(v.value.object.get("stream").?.bool);
    try std.testing.expectEqual(@as(i64, 7), v.value.object.get("max_tokens").?.integer);
    try std.testing.expectEqualStrings("s \"q\"", v.value.object.get("messages").?.array.items[0].object.get("content").?.string);
}

// ------------------------------------------------- against a mock server

const mock = @import("mock_server.zig");

fn testRequest(url: []const u8, msgs: []const Message) Request {
    return .{ .endpoint = url, .model = "tiny", .messages = msgs, .timeout_ms = 2000 };
}

test "chatStream: streams deltas from a mock server" {
    const replies = [_]mock.Reply{.{ .chunks = mock.sse(&.{ "git ", "push", " origin main" }) }};
    var srv = try mock.MockServer.start(std.testing.allocator, &replies);
    defer srv.deinit();
    var ub: [64]u8 = undefined;
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    var cancel = Cancel{};
    var req = testRequest(srv.url(&ub), &.{.{ .role = "user", .content = "hi" }});
    req.api_key = "sk-test-key";
    try chatStream(std.testing.allocator, req, &cancel, Collect{ .out = &out });
    try std.testing.expectEqualStrings("git push origin main", out.items);
    const raw = srv.requests.items[0];
    errdefer std.debug.print("raw request:\n{s}\n", .{raw});
    try std.testing.expect(std.mem.startsWith(u8, raw, "POST /v1/chat/completions HTTP/1.1"));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(raw, "authorization: Bearer sk-test-key") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"model\":\"tiny\"") != null);
}

test "chatStream: plain JSON reply, HTTP errors, refused connection" {
    const replies = [_]mock.Reply{
        .{ .content_type = "application/json", .chunks = &.{"{\"choices\":[{\"message\":{\"content\":\"ls -la\"}}]}"} },
        .{ .status = 404, .content_type = "application/json", .chunks = &.{"{\"error\":\"no such model\"}"} },
    };
    var srv = try mock.MockServer.start(std.testing.allocator, &replies);
    var ub: [64]u8 = undefined;
    const url = srv.url(&ub);
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    var cancel = Cancel{};
    const msgs = [_]Message{.{ .role = "user", .content = "x" }};
    try chatStream(std.testing.allocator, testRequest(url, &msgs), &cancel, Collect{ .out = &out });
    try std.testing.expectEqualStrings("ls -la", out.items);
    try std.testing.expectError(error.HttpStatus, chatStream(std.testing.allocator, testRequest(url, &msgs), &cancel, Collect{ .out = &out }));
    try std.testing.expectEqual(@as(u16, 404), last_status);
    srv.deinit();
    // Server gone: connection refused degrades to an error, no crash.
    try std.testing.expectError(error.Offline, chatStream(std.testing.allocator, testRequest(url, &msgs), &cancel, Collect{ .out = &out }));
    try std.testing.expectError(error.BadEndpoint, chatStream(std.testing.allocator, testRequest("ftp://x/v1", &msgs), &cancel, Collect{ .out = &out }));
}

test "chatStream: timeout and cancel from another thread" {
    const replies = [_]mock.Reply{.{ .hang = true }};
    var srv = try mock.MockServer.start(std.testing.allocator, &replies);
    defer srv.deinit();
    var ub: [64]u8 = undefined;
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    var cancel = Cancel{};
    const msgs = [_]Message{.{ .role = "user", .content = "x" }};
    var req = testRequest(srv.url(&ub), &msgs);
    req.timeout_ms = 150;
    const t0 = std.time.milliTimestamp();
    try std.testing.expectError(error.Timeout, chatStream(std.testing.allocator, req, &cancel, Collect{ .out = &out }));
    try std.testing.expect(std.time.milliTimestamp() - t0 < 1500);

    req.timeout_ms = 10_000;
    const Killer = struct {
        fn run(c: *Cancel) void {
            std.time.sleep(100 * std.time.ns_per_ms);
            c.cancel();
        }
    };
    const th = try std.Thread.spawn(.{}, Killer.run, .{&cancel});
    const t1 = std.time.milliTimestamp();
    try std.testing.expectError(error.Cancelled, chatStream(std.testing.allocator, req, &cancel, Collect{ .out = &out }));
    th.join();
    try std.testing.expect(std.time.milliTimestamp() - t1 < 2000);
}

test "chatStream: sink can stop the stream early" {
    const replies = [_]mock.Reply{.{ .chunks = mock.sse(&.{ "a", "b", "c", "d" }), .delay_ms = 5 }};
    var srv = try mock.MockServer.start(std.testing.allocator, &replies);
    defer srv.deinit();
    var ub: [64]u8 = undefined;
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    var cancel = Cancel{};
    try chatStream(std.testing.allocator, testRequest(srv.url(&ub), &.{.{ .role = "user", .content = "x" }}), &cancel, Collect{ .out = &out, .limit = 2 });
    try std.testing.expectEqualStrings("ab", out.items);
}
