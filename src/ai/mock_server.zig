//! Tiny scripted HTTP server for tests (one thread, serves `replies` in
//! order, records each request). Not used by the terminal itself.

const std = @import("std");

pub const Reply = struct {
    status: u16 = 200,
    content_type: []const u8 = "text/event-stream",
    chunks: []const []const u8 = &.{},
    /// Pause before each chunk.
    delay_ms: u32 = 0,
    /// Accept, read the request, then never answer (until the client gives up).
    hang: bool = false,
};

pub const MockServer = struct {
    allocator: std.mem.Allocator,
    server: std.net.Server,
    port: u16,
    thread: ?std.Thread = null,
    replies: []const Reply,
    mutex: std.Thread.Mutex = .{},
    /// Raw requests (headers + body), owned.
    requests: std.ArrayList([]u8),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    conn_threads: std.ArrayList(std.Thread),

    pub fn start(allocator: std.mem.Allocator, replies: []const Reply) !*MockServer {
        const self = try allocator.create(MockServer);
        errdefer allocator.destroy(self);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        var server = try addr.listen(.{ .reuse_address = true });
        errdefer server.deinit();
        self.* = .{
            .allocator = allocator,
            .server = server,
            .port = server.listen_address.getPort(),
            .replies = replies,
            .requests = std.ArrayList([]u8).init(allocator),
            .conn_threads = std.ArrayList(std.Thread).init(allocator),
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn deinit(self: *MockServer) void {
        self.stop.store(true, .seq_cst);
        // Wake accept() with a throwaway connection.
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |s| s.close() else |_| {}
        if (self.thread) |t| t.join();
        for (self.conn_threads.items) |th| th.join();
        self.conn_threads.deinit();
        self.server.deinit();
        for (self.requests.items) |r| self.allocator.free(r);
        self.requests.deinit();
        self.allocator.destroy(self);
    }

    pub fn url(self: *const MockServer, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/v1", .{self.port}) catch unreachable;
    }

    pub fn requestCount(self: *MockServer) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.requests.items.len;
    }

    fn run(self: *MockServer) void {
        var i: usize = 0;
        while (!self.stop.load(.seq_cst)) {
            const conn = self.server.accept() catch return;
            if (self.stop.load(.seq_cst)) {
                conn.stream.close();
                return;
            }
            const reply = if (self.replies.len == 0) Reply{} else self.replies[@min(i, self.replies.len - 1)];
            i += 1;
            // One thread per connection so a slow reply doesn't hold up the next.
            const th = std.Thread.spawn(.{}, serveClose, .{ self, conn.stream, reply }) catch {
                conn.stream.close();
                continue;
            };
            self.mutex.lock();
            defer self.mutex.unlock();
            self.conn_threads.append(th) catch th.join();
        }
    }

    fn serveClose(self: *MockServer, stream: std.net.Stream, reply: Reply) void {
        self.serve(stream, reply) catch {};
        stream.close();
    }

    fn serve(self: *MockServer, stream: std.net.Stream, reply: Reply) !void {
        var req = std.ArrayList(u8).init(self.allocator);
        defer req.deinit();
        var buf: [4096]u8 = undefined;
        // Read headers, then Content-Length bytes of body.
        var body_needed: ?usize = null;
        var header_end: usize = 0;
        while (true) {
            if (body_needed) |n| if (req.items.len >= header_end + n) break;
            const got = try stream.read(&buf);
            if (got == 0) break;
            try req.appendSlice(buf[0..got]);
            if (body_needed == null) {
                if (std.mem.indexOf(u8, req.items, "\r\n\r\n")) |he| {
                    header_end = he + 4;
                    body_needed = 0;
                    var lines = std.mem.splitSequence(u8, req.items[0..he], "\r\n");
                    while (lines.next()) |l| {
                        if (std.ascii.startsWithIgnoreCase(l, "content-length:")) {
                            body_needed = std.fmt.parseInt(usize, std.mem.trim(u8, l["content-length:".len..], " "), 10) catch 0;
                        }
                    }
                }
            }
        }
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.requests.append(try self.allocator.dupe(u8, req.items));
        }
        if (reply.hang) {
            // Hold the connection until the client closes it.
            while ((stream.read(&buf) catch 0) > 0) {}
            return;
        }
        var w = stream.writer();
        try w.print("HTTP/1.1 {d} X\r\ncontent-type: {s}\r\nconnection: close\r\n\r\n", .{ reply.status, reply.content_type });
        for (reply.chunks) |ch| {
            if (reply.delay_ms > 0) {
                // Sleep in slices so a closed client or deinit ends it early.
                var left = reply.delay_ms;
                while (left > 0 and !self.stop.load(.seq_cst)) {
                    const step = @min(left, 20);
                    std.time.sleep(@as(u64, step) * std.time.ns_per_ms);
                    left -= step;
                }
            }
            w.writeAll(ch) catch return;
        }
    }
};

/// An SSE body streaming `parts` as deltas, then [DONE].
pub fn sse(comptime parts: []const []const u8) []const []const u8 {
    const result = comptime blk: {
        var out: []const []const u8 = &.{};
        for (parts) |p| out = out ++ [_][]const u8{"data: {\"choices\":[{\"delta\":{\"content\":\"" ++ p ++ "\"}}]}\n\n"};
        break :blk out ++ [_][]const u8{"data: [DONE]\n\n"};
    };
    return result;
}
