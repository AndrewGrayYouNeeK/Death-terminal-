//! Supabase Auth (GoTrue) over HTTPS: sign up, log in, refresh, password
//! reset and sign out. Only the public project URL and anon key are used.
//! All memory comes from the caller's arena.

const std = @import("std");
const build_options = @import("build_options");
const certs = @import("../share/certs.zig");

pub const Session = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    /// Unix seconds.
    expires_at: i64,
    email: []const u8 = "",
    user_id: []const u8 = "",
};

pub const Project = struct {
    url: []const u8 = build_options.supabase_url,
    anon_key: []const u8 = build_options.supabase_anon_key,
};

pub const Outcome = union(enum) {
    session: Session,
    /// Sign-up worked but the email address has to be confirmed first.
    confirm_email,
    /// The server answered with an error (4xx): bad password, etc.
    rejected: []const u8,
    /// No answer (offline, DNS, TLS) or a server error (5xx).
    unreachable_: []const u8,
};

const Response = struct { status: u16, body: []const u8 };

fn request(arena: std.mem.Allocator, project: Project, method: std.http.Method, path: []const u8, payload: ?[]const u8, bearer: ?[]const u8) !Response {
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ std.mem.trimRight(u8, project.url, "/"), path });
    var client = std.http.Client{ .allocator = arena };
    defer client.deinit();
    // Same CA roots as the share relay (std's macOS keychain scan aborts).
    certs.scan(&client.ca_bundle, arena) catch {};
    client.next_https_rescan_certs = false;

    var body = std.ArrayList(u8).init(arena);
    var hdr_buf: [16 * 1024]u8 = undefined;
    const auth: std.http.Client.Request.Headers.Value = if (bearer) |t|
        .{ .override = try std.fmt.allocPrint(arena, "Bearer {s}", .{t}) }
    else
        .omit;
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .server_header_buffer = &hdr_buf,
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .headers = .{
            .content_type = if (payload != null) .{ .override = "application/json" } else .default,
            .user_agent = .{ .override = "DeathTerminal" },
            .accept_encoding = .omit,
            .authorization = auth,
        },
        .extra_headers = &.{.{ .name = "apikey", .value = project.anon_key }},
        .response_storage = .{ .dynamic = &body },
        .max_append_size = 1 << 20,
    });
    return .{ .status = @intFromEnum(res.status), .body = body.items };
}

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn int(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// The human-readable error in a GoTrue error body.
pub fn errorMessage(arena: std.mem.Allocator, body: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return "unexpected reply from the sign-in server";
    if (parsed != .object) return "unexpected reply from the sign-in server";
    const o = parsed.object;
    if (str(o, "error_code")) |c| {
        if (std.mem.eql(u8, c, "email_not_confirmed")) return "Email not confirmed yet. Click the link we emailed you, then log in.";
        if (std.mem.eql(u8, c, "invalid_credentials")) return "Wrong email or password.";
        if (std.mem.eql(u8, c, "user_already_exists")) return "An account with that email already exists. Log in instead.";
        if (std.mem.eql(u8, c, "weak_password")) return str(o, "msg") orelse "That password is too weak.";
        if (std.mem.eql(u8, c, "over_email_send_rate_limit")) return "Too many emails sent. Wait a minute and try again.";
    }
    return str(o, "msg") orelse str(o, "error_description") orelse str(o, "message") orelse str(o, "error") orelse "sign-in failed";
}

/// A session from a token response (`/token`, or `/signup` when email
/// confirmation is off).
pub fn parseSession(arena: std.mem.Allocator, body: []const u8, now: i64) ?Session {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (parsed != .object) return null;
    const o = parsed.object;
    const access = str(o, "access_token") orelse return null;
    const refresh_tok = str(o, "refresh_token") orelse return null;
    const expires_at = int(o, "expires_at") orelse now + (int(o, "expires_in") orelse 3600);
    var s = Session{ .access_token = access, .refresh_token = refresh_tok, .expires_at = expires_at };
    if (o.get("user")) |u| if (u == .object) {
        s.email = str(u.object, "email") orelse "";
        s.user_id = str(u.object, "id") orelse "";
    };
    return s;
}

fn jsonBody(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.stringifyAlloc(arena, value, .{});
}

fn tokenOutcome(arena: std.mem.Allocator, res: Response) Outcome {
    if (res.status >= 500) return .{ .unreachable_ = "the sign-in server is having trouble" };
    if (res.status >= 400) return .{ .rejected = errorMessage(arena, res.body) };
    if (parseSession(arena, res.body, std.time.timestamp())) |s| return .{ .session = s };
    return .{ .rejected = "unexpected reply from the sign-in server" };
}

fn netError(err: anyerror) Outcome {
    return .{ .unreachable_ = switch (err) {
        error.UnknownHostName, error.TemporaryNameServerFailure, error.NameServerFailure => "no internet connection (cannot find the sign-in server)",
        error.ConnectionRefused, error.NetworkUnreachable, error.ConnectionTimedOut => "no internet connection",
        else => @errorName(err),
    } };
}

pub fn logIn(arena: std.mem.Allocator, project: Project, email: []const u8, password: []const u8) Outcome {
    const payload = jsonBody(arena, .{ .email = email, .password = password }) catch return .{ .unreachable_ = "out of memory" };
    const res = request(arena, project, .POST, "/auth/v1/token?grant_type=password", payload, null) catch |e| return netError(e);
    return tokenOutcome(arena, res);
}

pub fn signUp(arena: std.mem.Allocator, project: Project, email: []const u8, password: []const u8) Outcome {
    const payload = jsonBody(arena, .{ .email = email, .password = password }) catch return .{ .unreachable_ = "out of memory" };
    const res = request(arena, project, .POST, "/auth/v1/signup", payload, null) catch |e| return netError(e);
    if (res.status >= 400) return tokenOutcome(arena, res);
    if (parseSession(arena, res.body, std.time.timestamp())) |s| return .{ .session = s };
    return .confirm_email;
}

pub fn refresh(arena: std.mem.Allocator, project: Project, refresh_token: []const u8) Outcome {
    const payload = jsonBody(arena, .{ .refresh_token = refresh_token }) catch return .{ .unreachable_ = "out of memory" };
    const res = request(arena, project, .POST, "/auth/v1/token?grant_type=refresh_token", payload, null) catch |e| return netError(e);
    return tokenOutcome(arena, res);
}

/// Send a password-reset email. Supabase answers 200 whether or not the
/// address has an account.
pub fn recover(arena: std.mem.Allocator, project: Project, email: []const u8) ?[]const u8 {
    const payload = jsonBody(arena, .{ .email = email }) catch return "out of memory";
    const res = request(arena, project, .POST, "/auth/v1/recover", payload, null) catch |e| return netError(e).unreachable_;
    if (res.status >= 400) return errorMessage(arena, res.body);
    return null;
}

/// Revoke the session on the server (best effort).
pub fn logOut(arena: std.mem.Allocator, project: Project, access_token: []const u8) bool {
    const res = request(arena, project, .POST, "/auth/v1/logout", null, access_token) catch return false;
    return res.status < 300;
}

test "parse a token response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"access_token":"a.b.c","token_type":"bearer","expires_in":3600,"expires_at":1800000000,
        \\ "refresh_token":"r1","user":{"id":"u-1","email":"x@example.com"}}
    ;
    const s = parseSession(arena.allocator(), body, 0).?;
    try std.testing.expectEqualStrings("a.b.c", s.access_token);
    try std.testing.expectEqualStrings("r1", s.refresh_token);
    try std.testing.expectEqual(@as(i64, 1800000000), s.expires_at);
    try std.testing.expectEqualStrings("x@example.com", s.email);
    try std.testing.expect(parseSession(arena.allocator(), "{\"id\":\"u\",\"email\":\"e\"}", 0) == null);
}

test "error messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Wrong email or password.", errorMessage(arena.allocator(), "{\"code\":400,\"error_code\":\"invalid_credentials\",\"msg\":\"Invalid login credentials\"}"));
    try std.testing.expectEqualStrings("boom", errorMessage(arena.allocator(), "{\"msg\":\"boom\"}"));
}
