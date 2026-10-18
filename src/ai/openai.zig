//! Chat client with SSE streaming. Ollama, llama.cpp, vLLM, LM Studio and
//! OpenAI speak `{endpoint}/chat/completions`. `api.x.ai` and `us.api.x.ai`
//! (Grok 4.7, the model Grok Bot uses) speak `{endpoint}/responses`:
//! `reasoning.effort`, live search off, and `store: false`. Reasoning
//! text is never treated as the answer. Plain HTTP/1.1 JSON over
//! std.http.Client; https works through std's TLS.
//!
//! Blocking by design: it runs on the AI worker thread. `Cancel` aborts an
//! in-flight request from another thread by shutting the socket down, and
//! a receive timeout bounds every read. On Windows neither reaches std's
//! ReadFile, so the connection goes through a relay (net/relay.zig) that
//! enforces both.
const builtin = @import("builtin");

const std = @import("std");
const posix = std.posix;
const dial = @import("../net/dial.zig");
const Relay = @import("../net/relay.zig").Relay;
const use_relay = builtin.os.tag == .windows;

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub const Api = enum { chat, responses };

pub const Request = struct {
    /// Base URL ending in the API root, e.g. "http://localhost:11434/v1"
    /// or "https://api.x.ai/v1".
    endpoint: []const u8,
    model: []const u8,
    /// Sent as "Authorization: Bearer ..." when set.
    api_key: ?[]const u8 = null,
    messages: []const Message,
    /// Visible-token budget. On the Responses API the request adds a
    /// reasoning allowance, because `max_output_tokens` counts both.
    max_tokens: u32 = 64,
    temperature: f32 = 0.2,
    /// Whole request deadline. xAI hosts wait at least 15s, because
    /// grok-4.7 reasons before the first visible token.
    timeout_ms: u32 = 5000,
    /// "" = "low" on the Responses API, omitted for chat/completions.
    /// Otherwise "low", "medium", "high" or "xhigh".
    reasoning: []const u8 = "",
    /// null = pick from the endpoint host. Tests set this to force a path.
    api: ?Api = null,
};

/// Grok's current API. Chat completions stays the path for every other host.
pub fn usesResponsesApi(endpoint: []const u8) bool {
    const base = std.mem.trimRight(u8, endpoint, "/");
    const uri = std.Uri.parse(base) catch return false;
    const host_c = uri.host orelse return false;
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const host = host_c.toRawMaybeAlloc(fba.allocator()) catch return false;
    return std.ascii.eqlIgnoreCase(host, "api.x.ai") or std.ascii.eqlIgnoreCase(host, "us.api.x.ai");
}

fn resolveApi(req: Request) Api {
    return req.api orelse if (usesResponsesApi(req.endpoint)) .responses else .chat;
}

/// grok-4.7 thinks before it emits text. A 5s ghost-text timeout dies in
/// that gap, so xAI hosts get a floor. A longer `ai.timeout_ms` still wins.
const xai_min_timeout_ms: u32 = 15_000;
const grok_reasoning_allowance: u32 = 1024;

fn effectiveTimeout(req: Request) u32 {
    if (usesResponsesApi(req.endpoint) and req.timeout_ms < xai_min_timeout_ms) return xai_min_timeout_ms;
    return req.timeout_ms;
}

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
        // Windows: the relay sees `cancelled` and ends the stream. A
        // shutdown() under a blocked ReadFile makes Wine fail that read with
        // ERROR_IO_PENDING, which std treats as unreachable.
        if (use_relay) return;
        if (self.fd) |fd| dial.shutdownSocket(fd, .both);
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

/// POST `{endpoint}/chat/completions`, or `{endpoint}/responses` on
/// api.x.ai and us.api.x.ai. `stream: true`. `sink.onDelta` may return
/// false to stop early. Servers that ignore `stream` and answer with
/// plain JSON are handled too.
pub fn chatStream(allocator: std.mem.Allocator, req: Request, cancel: *Cancel, sink: anytype) Error!void {
    const api = resolveApi(req);
    const timeout_ms = effectiveTimeout(req);
    var url_buf: [1024]u8 = undefined;
    const base = std.mem.trimRight(u8, req.endpoint, "/");
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ base, if (api == .responses) "/responses" else "/chat/completions" }) catch return error.BadEndpoint;
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
    const deadline = std.time.milliTimestamp() + timeout_ms;

    // Our own connection, so name lookup and connect obey the deadline
    // (std.http would block in tcpConnectToHost).
    var relay: ?*Relay = null;
    defer if (relay) |rl| rl.finish();
    const conn = try openConnection(&client, uri, timeout_ms, deadline, cancel, &relay);

    var r = client.open(.POST, uri, .{
        .connection = conn,
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
    setTimeout(fd, timeout_ms);

    r.transfer_encoding = .{ .content_length = body.len };
    r.send() catch |err| return mapErr(err, cancel, deadline);
    r.writeAll(body) catch |err| return mapErr(err, cancel, deadline);
    r.finish() catch |err| return mapErr(err, cancel, deadline);
    r.wait() catch |err| return mapErr(err, cancel, deadline);
    if (r.response.status != .ok) {
        last_status = @intFromEnum(r.response.status);
        return error.HttpStatus;
    }
    // Trust text/event-stream; anything else (missing, or a proxy that
    // relabels the stream as JSON) is decided by the first body byte.
    var sse: ?bool = if (r.response.content_type) |ct| (if (std.mem.indexOf(u8, ct, "event-stream") != null) true else null) else null;

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
        if (n == 0) {
            // A relay that gave up ends the stream early; that's not success.
            if (relay) |rl| switch (rl.why()) {
                .timeout => return error.Timeout,
                .cancelled => return error.Cancelled,
                .closed, .none => {},
            };
            break;
        }
        if (sse == null) sse = sniffSse(buf[0..n]);
        if (sse == true) {
            if (whole.items.len > 0) {
                // Leading whitespace held back while sniffing.
                _ = try parser.feed(whole.items, sink);
                whole.clearRetainingCapacity();
            }
            if (!try parser.feed(buf[0..n], sink)) return;
        } else {
            if (whole.items.len + n > 1024 * 1024) return error.BadResponse;
            try whole.appendSlice(buf[0..n]);
        }
    }
    if (cancel.isCancelled()) return error.Cancelled;
    if (sse == true) {
        _ = try parser.feed("\n", sink);
        return;
    }
    // Non-streaming reply.
    try handlePayload(allocator, whole.items, sink);
}

/// null while `data` is only whitespace; true for an SSE body ("data:",
/// "event:", "id:", ": comment"), false for anything else (JSON).
fn sniffSse(data: []const u8) ?bool {
    const t = std.mem.trimLeft(u8, data, " \t\r\n");
    if (t.len == 0) return null;
    return t[0] != '{' and t[0] != '[';
}

fn cancelCheck(ctx: *anyopaque) bool {
    const c: *Cancel = @ptrCast(@alignCast(ctx));
    return c.isCancelled();
}

/// Connect (and for https, handshake) within the deadline and register
/// the connection with `client`'s pool, which closes it when the request
/// is done.
fn openConnection(client: *std.http.Client, uri: std.Uri, timeout_ms: u32, deadline: i64, cancel: *Cancel, relay_out: *?*Relay) Error!*std.http.Client.Connection {
    const Conn = std.http.Client.Connection;
    const protocol: Conn.Protocol = if (std.ascii.eqlIgnoreCase(uri.scheme, "http"))
        .plain
    else if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        .tls
    else
        return error.BadEndpoint;
    var host_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&host_buf);
    const host_c = uri.host orelse return error.BadEndpoint;
    var host = host_c.toRawMaybeAlloc(fba.allocator()) catch return error.BadEndpoint;
    // "[::1]" -> "::1"
    if (host.len > 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    const port: u16 = uri.port orelse if (protocol == .tls) 443 else 80;

    const left = deadline - std.time.milliTimestamp();
    if (left <= 0) return error.Timeout;
    const fd = dial.connect(host, port, @intCast(left), .{ .ctx = cancel, .f = cancelCheck }) catch |err| return switch (err) {
        error.Timeout => error.Timeout,
        error.Cancelled => error.Cancelled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Offline,
    };
    // The socket std will use (and close): the real one, or the relay's end.
    var std_fd = fd;
    var fd_owned = true;
    errdefer if (fd_owned) dial.closeSocket(std_fd);
    if (use_relay) {
        // The relay owns the real socket from here; std gets `theirs`.
        fd_owned = false;
        const rl = Relay.start(client.allocator, fd, deadline, cancel, cancelCheck) catch return error.OutOfMemory;
        relay_out.* = rl;
        std_fd = rl.theirs;
        fd_owned = true;
    }
    if (!cancel.attach(std_fd)) return error.Cancelled;
    defer cancel.detach();
    setTimeout(std_fd, timeout_ms);
    const stream = std.net.Stream{ .handle = std_fd };

    const allocator = client.allocator;
    const node = try allocator.create(std.http.Client.ConnectionPool.Node);
    errdefer allocator.destroy(node);
    node.* = .{ .data = .{
        .stream = stream,
        .tls_client = undefined,
        .protocol = protocol,
        .host = try allocator.dupe(u8, host),
        .port = port,
    } };
    errdefer allocator.free(node.data.host);
    if (protocol == .tls) {
        {
            client.ca_bundle_mutex.lock();
            defer client.ca_bundle_mutex.unlock();
            if (client.next_https_rescan_certs) {
                client.ca_bundle.rescan(allocator) catch return error.BadEndpoint;
                client.next_https_rescan_certs = false;
            }
        }
        const tls = try allocator.create(std.crypto.tls.Client);
        errdefer allocator.destroy(tls);
        tls.* = std.crypto.tls.Client.init(stream, client.ca_bundle, host) catch {
            if (cancel.isCancelled()) return error.Cancelled;
            if (std.time.milliTimestamp() >= deadline - 20) return error.Timeout;
            return error.BadResponse;
        };
        tls.allow_truncation_attacks = true;
        node.data.tls_client = tls;
    }
    client.connection_pool.addUsed(node);
    fd_owned = false;
    return &node.data;
}

fn setTimeout(fd: posix.socket_t, ms: u32) void {
    if (@import("builtin").os.tag == .windows) {
        // Winsock takes the timeout as a DWORD of milliseconds.
        const v: u32 = ms;
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&v)) catch {};
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&v)) catch {};
        return;
    }
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

fn reasoningEffort(req: Request, buf: *[8]u8) []const u8 {
    const raw = if (req.reasoning.len == 0) "low" else req.reasoning;
    const n = @min(raw.len, buf.len);
    for (raw[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

fn buildBody(allocator: std.mem.Allocator, req: Request) ![]u8 {
    if (resolveApi(req) == .responses) return buildResponsesBody(allocator, req);
    return buildChatBody(allocator, req);
}

fn buildChatBody(allocator: std.mem.Allocator, req: Request) ![]u8 {
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

fn buildResponsesBody(allocator: std.mem.Allocator, req: Request) ![]u8 {
    var effort_buf: [8]u8 = undefined;
    const effort = reasoningEffort(req, &effort_buf);
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try std.json.stringify(.{
        .model = req.model,
        .input = req.messages,
        .stream = true,
        .max_output_tokens = req.max_tokens +| grok_reasoning_allowance,
        .reasoning = .{ .effort = effort },
        // The server default is to search. That would ship the command
        // line to the web; suggestions stay on the prompt we already sent.
        .search_parameters = .{ .mode = "off" },
        .store = false,
        .prompt_cache_key = "deathterminal",
    }, .{}, out.writer());
    return out.toOwnedSlice();
}

const TextPart = struct {
    type: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

const OutputItem = struct {
    type: ?[]const u8 = null,
    content: []const TextPart = &.{},
};

const Chunk = struct {
    type: ?[]const u8 = null,
    delta: ?[]const u8 = null,
    choices: []const struct {
        delta: ?struct {
            content: ?[]const u8 = null,
        } = null,
        message: ?struct { content: ?[]const u8 = null } = null,
        text: ?[]const u8 = null,
    } = &.{},
    output: []const OutputItem = &.{},
    @"error": ?std.json.Value = null,
};

fn emit(sink: anytype, text: []const u8) bool {
    if (text.len == 0) return true;
    return sink.onDelta(text);
}

fn handlePayload(allocator: std.mem.Allocator, payload: []const u8, sink: anytype) Error!void {
    const parsed = std.json.parseFromSlice(Chunk, allocator, payload, .{ .ignore_unknown_fields = true }) catch return error.BadResponse;
    defer parsed.deinit();
    const v = parsed.value;
    if (v.@"error" != null) return error.ApiError;
    if (v.type) |ty| {
        if (std.mem.eql(u8, ty, "error") or std.mem.eql(u8, ty, "response.failed")) return error.ApiError;
        if (std.mem.eql(u8, ty, "response.output_text.delta")) {
            if (v.delta) |t| if (!emit(sink, t)) return;
            return;
        }
        // Reasoning summaries, encrypted reasoning, completed events.
        if (std.mem.startsWith(u8, ty, "response.")) return;
    }
    if (v.choices.len > 0) {
        const ch = v.choices[0];
        const text = if (ch.delta) |d| d.content else if (ch.message) |m| m.content else ch.text;
        if (text) |t| if (!emit(sink, t)) return;
        return;
    }
    for (v.output) |item| {
        if (item.type) |ty| if (!std.mem.eql(u8, ty, "message")) continue;
        for (item.content) |part| {
            if (part.type) |ty| if (!std.mem.eql(u8, ty, "output_text")) continue;
            if (part.text) |t| if (!emit(sink, t)) return;
        }
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
                // grok-4.7's completed event carries encrypted reasoning and
                // can dwarf a suggestion. Drop the overflow; visible deltas
                // are small, and a truncated JSON line would not parse.
                if (self.line.items.len < 256 * 1024) try self.line.append(b);
                continue;
            }
            const truncated = self.line.items.len >= 256 * 1024;
            const line = std.mem.trimRight(u8, self.line.items, "\r");
            defer self.line.clearRetainingCapacity();
            if (truncated) continue;
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

test "x.ai hosts use the Responses API; other hosts stay on chat completions" {
    try std.testing.expect(usesResponsesApi("https://api.x.ai/v1"));
    try std.testing.expect(usesResponsesApi("https://api.x.ai/v1/"));
    try std.testing.expect(usesResponsesApi("https://US.API.X.AI/v1"));
    try std.testing.expect(usesResponsesApi("https://us.api.x.ai/v1"));
    try std.testing.expect(!usesResponsesApi("http://localhost:11434/v1"));
    try std.testing.expect(!usesResponsesApi("https://api.openai.com/v1"));
    try std.testing.expect(!usesResponsesApi("https://openrouter.ai/api/v1"));

    const msgs = [_]Message{.{ .role = "user", .content = "git st" }};
    const body = try buildBody(std.testing.allocator, .{
        .endpoint = "https://api.x.ai/v1",
        .model = "grok-4.7",
        .messages = &msgs,
        .max_tokens = 64,
        .reasoning = "Low",
    });
    defer std.testing.allocator.free(body);
    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer v.deinit();
    const obj = v.value.object;
    try std.testing.expect(obj.get("messages") == null);
    try std.testing.expect(obj.get("temperature") == null);
    try std.testing.expect(obj.get("max_tokens") == null);
    try std.testing.expectEqualStrings("grok-4.7", obj.get("model").?.string);
    try std.testing.expect(obj.get("stream").?.bool);
    try std.testing.expect(!obj.get("store").?.bool);
    try std.testing.expectEqualStrings("deathterminal", obj.get("prompt_cache_key").?.string);
    try std.testing.expectEqualStrings("off", obj.get("search_parameters").?.object.get("mode").?.string);
    try std.testing.expectEqualStrings("low", obj.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expectEqual(@as(i64, 64 + grok_reasoning_allowance), obj.get("max_output_tokens").?.integer);
    try std.testing.expectEqualStrings("git st", obj.get("input").?.array.items[0].object.get("content").?.string);
}

test "sse parser: grok reasoning is not the suggestion" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    const c = Collect{ .out = &out };
    const body =
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking \"}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"git \"}}]}\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"nope\"}\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"status\"}\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"git status\"}]}]}}\n" ++
        "data: [DONE]\n";
    try std.testing.expect(!try p.feed(body, c));
    try std.testing.expectEqualStrings("git status", out.items);

    var whole = std.ArrayList(u8).init(std.testing.allocator);
    defer whole.deinit();
    const json =
        \\{"object":"response","output":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"secret"}]},{"type":"message","content":[{"type":"output_text","text":"ls -la"}]}]}
    ;
    try handlePayload(std.testing.allocator, json, Collect{ .out = &whole });
    try std.testing.expectEqualStrings("ls -la", whole.items);
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

test "chatStream: xAI Responses API stream, reasoning excluded" {
    const stream_body = "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"think\"}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"git \"}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"status\"}\n\n" ++
        "data: {\"type\":\"response.completed\"}\n\n" ++
        "data: [DONE]\n\n";
    const replies = [_]mock.Reply{.{ .chunks = &.{stream_body} }};
    var srv = try mock.MockServer.start(std.testing.allocator, &replies);
    defer srv.deinit();
    var ub: [64]u8 = undefined;
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    var cancel = Cancel{};
    var req = testRequest(srv.url(&ub), &.{.{ .role = "user", .content = "hi" }});
    req.api = .responses;
    req.model = "grok-4.7";
    req.reasoning = "low";
    try chatStream(std.testing.allocator, req, &cancel, Collect{ .out = &out });
    try std.testing.expectEqualStrings("git status", out.items);
    const raw = srv.requests.items[0];
    try std.testing.expect(std.mem.indexOf(u8, raw, "POST /v1/responses HTTP/1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"model\":\"grok-4.7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"effort\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"mode\":\"off\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"max_tokens\"") == null);
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

test "chatStream: servers that close the connection after each reply" {
    const json = "{\"choices\":[{\"message\":{\"content\":\"git status\"}}]}";
    const stream_body = "data: {\"choices\":[{\"delta\":{\"content\":\"git \"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"status\"}}]}\n\ndata: [DONE]\n\n";
    const replies = [_]mock.Reply{
        // HTTP/1.0 with Content-Length (Python's http.server and friends).
        .{ .head = std.fmt.comptimePrint("HTTP/1.0 200 OK\r\nServer: BaseHTTP/0.6\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{json.len}), .chunks = &.{json} },
        // HTTP/1.0 streaming, body ends at close.
        .{ .head = "HTTP/1.0 200 OK\r\nContent-Type: text/event-stream\r\n\r\n", .chunks = &.{stream_body} },
        // HTTP/1.1 + Connection: close + Content-Length.
        .{ .head = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\n\r\n", .{stream_body.len}), .chunks = &.{stream_body} },
        // An SSE body labelled as JSON (some proxies rewrite the type).
        .{ .head = "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n", .chunks = &.{stream_body} },
        // No Content-Type at all.
        .{ .head = "HTTP/1.0 200 OK\r\n\r\n", .chunks = &.{stream_body} },
    };
    var srv = try mock.MockServer.start(std.testing.allocator, &replies);
    defer srv.deinit();
    var ub: [64]u8 = undefined;
    const url = srv.url(&ub);
    const msgs = [_]Message{.{ .role = "user", .content = "x" }};
    var cancel = Cancel{};
    for (replies, 0..) |_, i| {
        var out = std.ArrayList(u8).init(std.testing.allocator);
        defer out.deinit();
        chatStream(std.testing.allocator, testRequest(url, &msgs), &cancel, Collect{ .out = &out }) catch |err| {
            std.debug.print("reply {d}: {s}\n", .{ i, @errorName(err) });
            return err;
        };
        std.testing.expectEqualStrings("git status", out.items) catch |err| {
            std.debug.print("reply {d}\n", .{i});
            return err;
        };
    }
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

test "chatStream: connect phase obeys the timeout (unroutable host, slow DNS)" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    var cancel = Cancel{};
    const msgs = [_]Message{.{ .role = "user", .content = "x" }};
    var req = testRequest("http://192.0.2.1:9/v1", &msgs);
    req.timeout_ms = 300;
    const start = std.time.milliTimestamp();
    const r = chatStream(std.testing.allocator, req, &cancel, Collect{ .out = &out });
    try std.testing.expect(r == error.Timeout or r == error.Offline);
    try std.testing.expect(std.time.milliTimestamp() - start < 1000);

    const saved = dial.lookup;
    dial.lookup = struct {
        fn f(host: []const u8, port: u16, o: *dial.AddrList) anyerror!void {
            _ = host;
            _ = port;
            _ = o;
            std.time.sleep(700 * std.time.ns_per_ms);
            return error.UnknownHostName;
        }
    }.f;
    defer dial.lookup = saved;
    req = testRequest("http://never-resolves.invalid/v1", &msgs);
    req.timeout_ms = 200;
    try std.testing.expectError(error.Timeout, chatStream(std.testing.allocator, req, &cancel, Collect{ .out = &out }));
    std.time.sleep(800 * std.time.ns_per_ms);
}
