//! First-run AI check. No config file is required. The HTTP GET is
//! injectable so tests never need a real Ollama. Nothing here prints an
//! API key.

const std = @import("std");
const builtin = @import("builtin");
const dial = @import("../net/dial.zig");
const posix = std.posix;

pub const default_model = "qwen2.5-coder:0.5b";
pub const default_endpoint = "http://localhost:11434/v1";

pub const GetResult = struct {
    /// 0 means nothing accepted the connection.
    status: u16 = 0,
    body: []const u8 = "",

    pub fn deinit(self: GetResult, a: std.mem.Allocator) void {
        if (self.body.len == 0) return;
        a.free(@constCast(self.body));
    }
};

pub const State = enum {
    /// Local Ollama is not accepting connections.
    ollama_down,
    /// Ollama answered, and the configured model is not in /api/tags.
    model_missing,
    /// Ollama answered and the model is listed.
    ready,
    /// A non-Ollama endpoint did not answer.
    endpoint_down,
    /// A non-Ollama endpoint answered. This check does not know its models.
    endpoint_up,
};

pub fn isLocalOllama(endpoint: []const u8) bool {
    const uri = std.Uri.parse(endpoint) catch return false;
    const host_c = uri.host orelse return false;
    var host_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&host_buf);
    const raw = host_c.toRawMaybeAlloc(fba.allocator()) catch return false;
    const host = if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']') raw[1 .. raw.len - 1] else raw;
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1");
}

pub fn classify(endpoint: []const u8, model: []const u8, got: GetResult) State {
    const local = isLocalOllama(endpoint);
    if (got.status == 0) return if (local) .ollama_down else .endpoint_down;
    if (!local) return if (got.status >= 200 and got.status < 500) .endpoint_up else .endpoint_down;
    if (got.status != 200) return .ollama_down;
    if (modelListed(got.body, model)) return .ready;
    return .model_missing;
}

fn modelListed(body: []const u8, model: []const u8) bool {
    if (model.len == 0) return false;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, model)) |at| {
        const after = at + model.len;
        const end_ok = after >= body.len or !std.ascii.isAlphanumeric(body[after]);
        const before_ok = at == 0 or !std.ascii.isAlphanumeric(body[at - 1]);
        if (before_ok and end_ok) return true;
        i = after;
    }
    return false;
}

pub const Hint = struct {
    headline: []const u8,
    detail: []const u8,
};

/// One short hint. Slices point at `head` and `detail` when they need the model name.
pub fn hint(head: []u8, detail: []u8, endpoint: []const u8, model: []const u8, status: []const u8) Hint {
    const local = isLocalOllama(endpoint);
    const missing = std.mem.indexOf(u8, status, "model not found") != null or (local and std.mem.startsWith(u8, status, "HTTP 404"));
    if (missing and local) {
        return .{
            .headline = std.fmt.bufPrint(head, "AI offline. Model {s} is not installed.", .{model}) catch "AI offline. The model is not installed.",
            .detail = std.fmt.bufPrint(detail, "ollama pull {s}", .{model}) catch "ollama pull qwen2.5-coder:0.5b",
        };
    }
    if (local and (status.len == 0 or std.mem.eql(u8, status, "endpoint unreachable") or std.mem.eql(u8, status, "connection refused"))) {
        return .{
            .headline = "AI offline. Ollama is not running.",
            .detail = std.fmt.bufPrint(detail, "ollama pull {s}", .{model}) catch "ollama pull qwen2.5-coder:0.5b",
        };
    }
    return .{
        .headline = std.fmt.bufPrint(head, "AI offline ({s}).", .{if (status.len > 0) status else "no answer"}) catch "AI offline.",
        .detail = "deathterminal --ai-setup",
    };
}

pub const Report = struct {
    config_path: ?[]const u8 = null,
    config_errors: bool = false,
    endpoint: []const u8,
    model: []const u8,
    got: GetResult = .{},
    voice_key_set: bool = false,
};

pub fn writeReport(w: anytype, r: Report) !void {
    try w.writeAll("YouNeeK Death Terminal\n\n");
    if (r.config_path) |p| {
        try w.print("Config: {s}\n", .{p});
        if (r.config_errors) {
            try w.writeAll("That file has errors, so this check uses the defaults. The file is optional.\n");
        } else {
            try w.writeAll("Optional. Delete it and the built-in defaults still run.\n");
        }
    } else {
        try w.writeAll("Config: none. Optional. Defaults are in use (death theme, AI on).\n");
    }
    const state = classify(r.endpoint, r.model, r.got);
    switch (state) {
        .ollama_down => {
            try w.print("Ollama: not running ({s}).\n", .{r.endpoint});
            try w.print("Next: ollama pull {s}\n", .{r.model});
        },
        .model_missing => {
            try w.writeAll("Ollama: running.\n");
            try w.print("Model: {s} is not installed.\n", .{r.model});
            try w.print("Next: ollama pull {s}\n", .{r.model});
        },
        .ready => {
            try w.writeAll("Ollama: running.\n");
            try w.print("Model: {s} is installed.\n", .{r.model});
            try w.writeAll("Next: deathterminal --gui\n");
        },
        .endpoint_down => {
            try w.print("Endpoint: not reachable ({s}).\n", .{r.endpoint});
            try w.writeAll("Next: start that server, or point config.ai.endpoint at Ollama.\n");
        },
        .endpoint_up => {
            try w.print("Endpoint: answered ({s}).\n", .{r.endpoint});
            try w.writeAll("Model: not checked. This probe only lists models on local Ollama.\n");
            try w.writeAll("Next: deathterminal --gui\n");
        },
    }
    if (r.voice_key_set) {
        try w.writeAll("Voice: ELEVENLABS_API_KEY is set.\n");
    } else {
        try w.writeAll("Voice: ELEVENLABS_API_KEY is not set. Answers are not spoken.\n");
    }
}

/// GET `url`. Status 0 and an empty body means the connection failed.
/// The body is owned by `a` when `status != 0`.
pub fn httpGet(a: std.mem.Allocator, url: []const u8) !GetResult {
    const uri = std.Uri.parse(url) catch return .{};
    const host_c = uri.host orelse return .{};
    var host_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&host_buf);
    var host = host_c.toRawMaybeAlloc(fba.allocator()) catch return .{};
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    const port: u16 = uri.port orelse if (std.mem.eql(u8, uri.scheme, "https")) 443 else 80;
    if (!std.mem.eql(u8, uri.scheme, "http")) return .{};
    const fd = dial.connect(host, port, 2000, null) catch return .{};
    var stream = std.net.Stream{ .handle = fd };
    defer stream.close();
    setRecvTimeout(fd, 2000);
    var req_buf: [512]u8 = undefined;
    const path = if (uri.path.percent_encoded.len == 0) "/" else uri.path.percent_encoded;
    const req = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, host }) catch return .{};
    stream.writeAll(req) catch return .{};
    var body = std.ArrayList(u8).init(a);
    errdefer body.deinit();
    var buf: [2048]u8 = undefined;
    while (body.items.len < 64 * 1024) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break;
        body.appendSlice(buf[0..n]) catch break;
    }
    const raw = body.items;
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return .{ .status = 0, .body = try body.toOwnedSlice() };
    const status = parseStatus(raw[0..sep]);
    const rest = raw[sep + 4 ..];
    const owned = try a.dupe(u8, rest);
    body.deinit();
    return .{ .status = status, .body = owned };
}

fn parseStatus(head: []const u8) u16 {
    // "HTTP/1.1 200 OK"
    var it = std.mem.tokenizeAny(u8, head, " \r\n");
    _ = it.next() orelse return 0;
    const code = it.next() orelse return 0;
    return std.fmt.parseInt(u16, code, 10) catch 0;
}

fn setRecvTimeout(fd: posix.socket_t, ms: u32) void {
    if (builtin.os.tag == .windows) {
        const v: u32 = ms;
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&v)) catch {};
        return;
    }
    const tv = posix.timeval{ .tv_sec = @intCast(ms / 1000), .tv_usec = @intCast((ms % 1000) * 1000) };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

/// `http://host:port/api/tags` for an endpoint that ends in `/v1`.
pub fn tagsUrl(a: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    const uri = std.Uri.parse(endpoint) catch return error.BadEndpoint;
    const host_c = uri.host orelse return error.BadEndpoint;
    var host_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&host_buf);
    const host = host_c.toRawMaybeAlloc(fba.allocator()) catch return error.BadEndpoint;
    const port: u16 = uri.port orelse if (std.mem.eql(u8, uri.scheme, "https")) 443 else 80;
    const scheme = uri.scheme;
    if (port == 80 or port == 443) {
        return std.fmt.allocPrint(a, "{s}://{s}/api/tags", .{ scheme, host });
    }
    return std.fmt.allocPrint(a, "{s}://{s}:{d}/api/tags", .{ scheme, host, port });
}

const t = std.testing;

test "doctor: no config, Ollama down" {
    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();
    try writeReport(buf.writer(), .{
        .endpoint = default_endpoint,
        .model = default_model,
        .got = .{ .status = 0 },
        .voice_key_set = false,
    });
    const text = buf.items;
    try t.expect(std.mem.indexOf(u8, text, "Config: none") != null);
    try t.expect(std.mem.indexOf(u8, text, "optional") != null or std.mem.indexOf(u8, text, "Optional") != null);
    try t.expect(std.mem.indexOf(u8, text, "not running") != null);
    try t.expect(std.mem.indexOf(u8, text, "ollama pull qwen2.5-coder:0.5b") != null);
    try t.expect(std.mem.indexOf(u8, text, "ELEVENLABS_API_KEY is not set") != null);
    try t.expect(std.mem.indexOf(u8, text, "sk-") == null);
}

test "doctor: Ollama up, model missing, voice key set but not printed" {
    const body = "{\"models\":[{\"name\":\"llama3.2:latest\"}]}";
    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();
    try writeReport(buf.writer(), .{
        .config_path = "/tmp/config.lua",
        .endpoint = "http://127.0.0.1:11434/v1",
        .model = default_model,
        .got = .{ .status = 200, .body = body },
        .voice_key_set = true,
    });
    const text = buf.items;
    try t.expect(std.mem.indexOf(u8, text, "is not installed") != null);
    try t.expect(std.mem.indexOf(u8, text, "ollama pull qwen2.5-coder:0.5b") != null);
    try t.expect(std.mem.indexOf(u8, text, "ELEVENLABS_API_KEY is set") != null);
    try t.expect(std.mem.indexOf(u8, text, "secret-value") == null);
    try t.expectEqual(State.model_missing, classify("http://127.0.0.1:11434/v1", default_model, .{ .status = 200, .body = body }));
    const ready_body = "{\"models\":[{\"name\":\"qwen2.5-coder:0.5b\"}]}";
    try t.expectEqual(State.ready, classify(default_endpoint, default_model, .{ .status = 200, .body = ready_body }));
}

test "doctor: hint text for unreachable and missing model" {
    var head: [160]u8 = undefined;
    var detail: [160]u8 = undefined;
    const down = hint(&head, &detail, default_endpoint, default_model, "endpoint unreachable");
    try t.expect(std.mem.indexOf(u8, down.headline, "AI offline") != null);
    try t.expect(std.mem.indexOf(u8, down.headline, "not running") != null);
    try t.expect(std.mem.indexOf(u8, down.detail, "ollama pull qwen2.5-coder:0.5b") != null);
    const miss = hint(&head, &detail, "http://127.0.0.1:9/v1", default_model, "model not found");
    try t.expect(std.mem.indexOf(u8, miss.headline, "not installed") != null);
    try t.expect(std.mem.indexOf(u8, miss.detail, "ollama pull qwen2.5-coder:0.5b") != null);
}

test "doctor: GET /api/tags against a mock server" {
    const mock = @import("mock_server.zig");
    const replies = [_]mock.Reply{.{
        .status = 200,
        .content_type = "application/json",
        .chunks = &.{"{\"models\":[{\"name\":\"qwen2.5-coder:0.5b\"}]}"},
    }};
    const srv = try mock.MockServer.start(t.allocator, &replies);
    defer srv.deinit();
    const url = try std.fmt.allocPrint(t.allocator, "http://127.0.0.1:{d}/api/tags", .{srv.port});
    defer t.allocator.free(url);
    const got = try httpGet(t.allocator, url);
    defer got.deinit(t.allocator);
    try t.expectEqual(@as(u16, 200), got.status);
    try t.expectEqual(State.ready, classify("http://127.0.0.1:11434/v1", default_model, got));
    try t.expect(srv.requestCount() == 1);
}
