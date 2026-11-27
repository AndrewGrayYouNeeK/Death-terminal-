//! Henad: the setup assistant behind `deathterminal --henad`.
//!
//! Two stages:
//!   1. Offline Henad talks only to local Ollama (http://localhost:11434). It
//!      helps get Death Terminal installed, configured, and connected.
//!      Nothing leaves the machine.
//!   2. Online Henad. Once the machine is online and the user has signed in
//!      with their own Henad account, questions go to the live Henad API
//!      (https://henad.youneek.dev, POST /agent/chat) for help with every
//!      other feature. When the API is unreachable or the user is signed
//!      out, Henad falls back to offline.
//!
//! No token ships with Death Terminal. `/signin` asks for the user's own
//! email and password, keeps the session token in a 0600 file under the
//! config folder, and `/signout` deletes it.
//!
//! Commands Henad suggests are never run on their own. `/run N` asks first,
//! and a destructive command (the Ghost Run list plus a few extras) needs
//! the phrase "run it" typed out.

const std = @import("std");
const builtin = @import("builtin");
const doctor = @import("doctor.zig");
const openai = @import("openai.zig");
const redact_mod = @import("redact.zig");
const match = @import("../ghost/match.zig");
const env_mod = @import("../platform/env.zig");
const paths = @import("../muscle/paths.zig");
const dial = @import("../net/dial.zig");

pub const name = "Henad";
pub const slogan = "The architecture of understanding.";
pub const default_online_url = "https://henad.youneek.dev";
pub const ollama_endpoint = doctor.default_endpoint;
pub const session_file = "henad-session";
/// Session file name from before the rename (Henad was called Nous). Read as a
/// fallback so an existing sign-in keeps working.
pub const legacy_session_file = "nous-session";
pub const session_cookie = "nf_session";
pub const destructive_phrase = "run it";
pub const max_commands = 9;

pub const Mode = enum { offline, online };

/// Whether online Henad can be used right now.
pub const OnlineState = enum {
    ready,
    /// No network, or henad.youneek.dev did not answer.
    no_network,
    /// Reachable, and there is no valid session for this user.
    signed_out,
    /// `--henad-offline` or `/offline`.
    disabled,
};

/// Online only when the API answered and the session is valid. Anything
/// else (including a forced `/online` that cannot work) is offline.
pub fn chooseMode(force_offline: bool, online: OnlineState) Mode {
    if (force_offline) return .offline;
    return if (online == .ready) .online else .offline;
}

pub fn onlineReason(s: OnlineState) []const u8 {
    return switch (s) {
        .ready => "signed in",
        .no_network => "the online Henad service is not reachable (no network, or it is down)",
        .signed_out => "not signed in. Type /signin to use your own Henad account",
        .disabled => "turned off (/online turns it back on)",
    };
}

// ------------------------------------------------------------ models

const Tags = struct {
    models: []const struct { name: []const u8 = "" } = &.{},
};

/// Model names from an Ollama `/api/tags` body. Garbage gives an empty list.
pub fn parseModels(a: std.mem.Allocator, body: []const u8) ![][]u8 {
    var out = std.ArrayList([]u8).init(a);
    errdefer {
        for (out.items) |m| a.free(m);
        out.deinit();
    }
    const parsed = std.json.parseFromSlice(Tags, a, body, .{ .ignore_unknown_fields = true }) catch return out.toOwnedSlice();
    defer parsed.deinit();
    for (parsed.value.models) |m| {
        if (m.name.len == 0) continue;
        try out.append(try a.dupe(u8, m.name));
    }
    return out.toOwnedSlice();
}

pub fn freeModels(a: std.mem.Allocator, models: [][]u8) void {
    for (models) |m| a.free(m);
    a.free(models);
}

fn isEmbedding(model: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(model, "embed") != null or std.ascii.indexOfIgnoreCase(model, "bert") != null;
}

fn sameModel(listed: []const u8, wanted: []const u8) bool {
    if (std.mem.eql(u8, listed, wanted)) return true;
    // "llama3.2" is "llama3.2:latest" in /api/tags.
    return std.mem.endsWith(u8, listed, ":latest") and std.mem.eql(u8, listed[0 .. listed.len - ":latest".len], wanted);
}

/// The preferred model when it is installed, otherwise the first installed
/// chat model (embedding models cannot answer). Null when there is none.
pub fn pickModel(models: []const []const u8, preferred: []const u8) ?[]const u8 {
    if (preferred.len > 0) for (models) |m| if (sameModel(m, preferred)) return m;
    for (models) |m| if (!isEmbedding(m)) return m;
    return null;
}

// ------------------------------------------------------------ commands

/// Command lines inside ``` fences, at most `max_commands`. Slices point
/// into `answer`. A leading "$ " prompt is dropped; blank lines and
/// comments are skipped.
pub fn extractCommands(a: std.mem.Allocator, answer: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(a);
    errdefer out.deinit();
    var in_fence = false;
    var it = std.mem.splitScalar(u8, answer, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (!in_fence or line.len == 0 or line[0] == '#') continue;
        var cmd = line;
        if (std.mem.startsWith(u8, cmd, "$ ")) cmd = std.mem.trimLeft(u8, cmd[2..], " ");
        if (cmd.len == 0) continue;
        try out.append(cmd);
        if (out.items.len == max_commands) break;
    }
    return out.toOwnedSlice();
}

pub const Risk = enum { normal, destructive };

const extra_risky = [_][]const u8{ "sudo ", "doas ", "shutdown", "reboot", "halt", "kill -9", "killall", "pkill", "diskutil erase", "format ", "del /", "rmdir /s", "rd /s", "Remove-Item", "launchctl unload", "systemctl stop", "systemctl disable", "rm " };

/// Ghost Run's built-in patterns plus a few that touch the whole system.
/// When in doubt (a parse failure) it is destructive.
pub fn classifyCommand(a: std.mem.Allocator, command: []const u8) Risk {
    const hit = match.intercept(a, command, &match.defaults, ".", true) catch return .destructive;
    if (hit) |h| {
        var owned = h;
        owned.deinit(a);
        return .destructive;
    }
    const trimmed = std.mem.trim(u8, command, " \t");
    for (extra_risky) |p| {
        if (std.mem.startsWith(u8, trimmed, p)) return .destructive;
        var buf: [64]u8 = undefined;
        for ([_][]const u8{ "; ", "&& ", "| ", "|| " }) |sep| {
            const needle = std.fmt.bufPrint(&buf, "{s}{s}", .{ sep, p }) catch continue;
            if (std.mem.indexOf(u8, trimmed, needle) != null) return .destructive;
        }
    }
    return .normal;
}

/// "y"/"yes" for a normal command. A destructive one needs "run it".
pub fn confirmed(risk: Risk, reply: []const u8) bool {
    const r = std.mem.trim(u8, reply, " \t\r\n");
    return switch (risk) {
        .normal => std.ascii.eqlIgnoreCase(r, "y") or std.ascii.eqlIgnoreCase(r, "yes"),
        .destructive => std.ascii.eqlIgnoreCase(r, destructive_phrase),
    };
}

// ------------------------------------------------------------ prompts

pub fn systemPrompt(a: std.mem.Allocator, report: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\You are Henad, the offline setup assistant built into YouNeeK Death Terminal (the `deathterminal` command). Slogan: "The architecture of understanding."
        \\You run on the user's own computer through local Ollama. Nothing they type leaves the machine.
        \\Your job: get Death Terminal installed, configured and connected. Diagnose config, Ollama, model, shell integration, SSH and network problems. Explain errors in plain words and suggest the next command.
        \\Facts:
        \\- `deathterminal --ai-setup` (same as --doctor) checks config, Ollama, the model and the voice key.
        \\- The config file is optional: ~/.config/death-terminal/config.lua (Windows %APPDATA%\death-terminal\config.lua). `deathterminal --print-default-config > ~/.config/death-terminal/config.lua` writes a documented one. Saving it reloads live.
        \\- AI suggestions use local Ollama at http://localhost:11434/v1 with qwen2.5-coder:0.5b by default: `ollama pull qwen2.5-coder:0.5b`. Start Ollama with the Ollama app or `ollama serve`.
        \\- `deathterminal --gui` opens a window. `deathterminal --ssh <host>` connects with the built-in SSH client (profiles in config.lua or ~/.ssh/config).
        \\- Shell integration for bash/zsh/fish is injected automatically; `deathterminal --print-shell-integration zsh` prints it.
        \\- `deathterminal --plugins list` shows plugins. `deathterminal --share` shares a pane. `deathterminal --henad` is you; once the user is online and signs in with /signin, the online Henad at henad.youneek.dev takes over for everything else.
        \\Rules: answer in a few short sentences. Put every command on its own line inside a ```sh fence so the user can pick it with /run. Never suggest deleting files, force pushes, sudo, or anything destructive unless the user asks, and then say plainly what it destroys. Never ask for passwords or API keys.
        \\Current check of this machine:
        \\{s}
    , .{report});
}

/// One-line context added in front of a question sent to online Henad.
pub fn onlineQuestion(a: std.mem.Allocator, question: []const u8) ![]u8 {
    const clean = try redact_mod.redact(a, question);
    defer a.free(clean);
    return std.fmt.allocPrint(a, "[From YouNeeK Death Terminal on {s}. Help me with Death Terminal features and setup; put commands in ```sh fences.] {s}", .{ @tagName(builtin.os.tag), clean });
}

pub fn writeOfflineHelp(w: anytype, model_missing: bool, report: []const u8) !void {
    if (model_missing) {
        try w.writeAll(
            \\Henad (offline) needs a local model. Ollama is running but has no chat model.
            \\  1. Get one:   ollama pull qwen2.5-coder:0.5b
            \\  2. Try again: deathterminal --henad
            \\
        );
    } else {
        try w.writeAll(
            \\Henad (offline) needs Ollama, and nothing is answering at http://localhost:11434.
            \\  1. Start it:  open the Ollama app, or run `ollama serve`
            \\  2. Get a model: ollama pull qwen2.5-coder:0.5b
            \\  3. Try again: deathterminal --henad
            \\  No Ollama yet? https://ollama.com/download
            \\
        );
    }
    try w.writeAll("\nWhat the built-in check sees right now:\n");
    try w.writeAll(report);
}

// ------------------------------------------------------------ offline (Ollama)

/// The Ollama endpoint Henad may use: config.ai.endpoint when it is local
/// Ollama, otherwise http://localhost:11434/v1. Never a remote host.
pub fn offlineEndpoint(configured: []const u8) []const u8 {
    return if (doctor.isLocalOllama(configured)) configured else ollama_endpoint;
}

const StreamSink = struct {
    out: *std.ArrayList(u8),
    w: ?std.io.AnyWriter,
    pub fn onDelta(self: StreamSink, text: []const u8) bool {
        self.out.appendSlice(text) catch return false;
        if (self.w) |w| w.writeAll(text) catch {};
        return true;
    }
};

/// Ask local Ollama. Streams to `w` when set. Returns the whole answer.
pub fn askOffline(a: std.mem.Allocator, endpoint: []const u8, model: []const u8, messages: []const openai.Message, w: ?std.io.AnyWriter) ![]u8 {
    if (!doctor.isLocalOllama(endpoint)) return error.NotLocal;
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    var cancel = openai.Cancel{};
    try openai.chatStream(a, .{
        .endpoint = endpoint,
        .model = model,
        .messages = messages,
        .max_tokens = 700,
        .temperature = 0.2,
        .timeout_ms = 180_000,
        .api = .chat,
    }, &cancel, StreamSink{ .out = &out, .w = w });
    return out.toOwnedSlice();
}

// ------------------------------------------------------------ online (henad.youneek.dev)

pub const HttpResult = struct {
    status: u16 = 0,
    body: []u8 = &.{},
    /// The nf_session value from Set-Cookie, when the server sent one.
    session: ?[]u8 = null,

    pub fn deinit(self: HttpResult, a: std.mem.Allocator) void {
        a.free(self.body);
        if (self.session) |s| a.free(s);
    }
};

/// `nf_session=VALUE; Path=/; ...` → VALUE. Null for other cookies or an
/// empty value (logout clears it).
pub fn parseSessionCookie(set_cookie: []const u8) ?[]const u8 {
    const first = std.mem.sliceTo(set_cookie, ';');
    const eq = std.mem.indexOfScalar(u8, first, '=') orelse return null;
    const key = std.mem.trim(u8, first[0..eq], " ");
    if (!std.mem.eql(u8, key, session_cookie)) return null;
    const v = std.mem.trim(u8, first[eq + 1 ..], " \"");
    return if (v.len == 0) null else v;
}

/// The host and port of an http(s) URL answer a TCP connect within `ms`.
pub fn reachable(base: []const u8, ms: u32) bool {
    const uri = std.Uri.parse(base) catch return false;
    const host_c = uri.host orelse return false;
    var host_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&host_buf);
    const host = host_c.toRawMaybeAlloc(fba.allocator()) catch return false;
    const port: u16 = uri.port orelse if (std.mem.eql(u8, uri.scheme, "https")) 443 else 80;
    const fd = dial.connect(host, port, ms, null) catch return false;
    dial.closeSocket(fd);
    return true;
}

fn joinUrl(buf: []u8, base: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ std.mem.trimRight(u8, base, "/"), path });
}

/// One HTTP call to online Henad. `token` goes in `Authorization: Bearer`.
pub fn httpCall(a: std.mem.Allocator, method: std.http.Method, base: []const u8, path: []const u8, token: ?[]const u8, body: ?[]const u8) !HttpResult {
    var url_buf: [1024]u8 = undefined;
    const url = try joinUrl(&url_buf, base, path);
    const uri = try std.Uri.parse(url);
    var client = std.http.Client{ .allocator = a };
    defer client.deinit();
    var head_buf: [16 * 1024]u8 = undefined;
    var auth_buf: [1024]u8 = undefined;
    var extra: [1]std.http.Header = undefined;
    var n_extra: usize = 0;
    if (token) |tk| {
        extra[0] = .{ .name = "authorization", .value = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{tk}) };
        n_extra = 1;
    }
    var req = try client.open(method, uri, .{
        .server_header_buffer = &head_buf,
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .user_agent = .{ .override = "deathterminal-henad" },
            .content_type = if (body != null) .{ .override = "application/json" } else .default,
        },
        .extra_headers = extra[0..n_extra],
    });
    defer req.deinit();
    if (body) |b| req.transfer_encoding = .{ .content_length = b.len };
    try req.send();
    if (body) |b| try req.writeAll(b);
    try req.finish();
    try req.wait();
    var session: ?[]u8 = null;
    errdefer if (session) |s| a.free(s);
    var it = req.response.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "set-cookie")) continue;
        if (parseSessionCookie(h.value)) |v| {
            if (session) |old| a.free(old);
            session = try a.dupe(u8, v);
        }
    }
    const resp = try req.reader().readAllAlloc(a, 1 << 20);
    return .{ .status = @intFromEnum(req.response.status), .body = resp, .session = session };
}

/// Online status for `token`. `connect_ms` bounds the reachability check.
pub fn probeOnline(a: std.mem.Allocator, base: []const u8, token: ?[]const u8, connect_ms: u32) OnlineState {
    if (!reachable(base, connect_ms)) return .no_network;
    const tk = token orelse return .signed_out;
    if (tk.len == 0) return .signed_out;
    const r = httpCall(a, .GET, base, "/auth/me", tk, null) catch return .no_network;
    defer r.deinit(a);
    if (r.status == 200) return .ready;
    if (r.status == 401 or r.status == 403) return .signed_out;
    return .no_network;
}

/// `email` from an /auth/me or /auth/login body, if present.
pub fn emailFrom(a: std.mem.Allocator, body: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(struct { email: []const u8 = "" }, a, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value.email.len == 0) return null;
    return a.dupe(u8, parsed.value.email) catch null;
}

pub fn buildChatBody(a: std.mem.Allocator, question: []const u8, history: []const openai.Message) ![]u8 {
    return std.json.stringifyAlloc(a, .{ .question = question, .history = history }, .{});
}

/// `text` from a POST /agent/chat answer.
pub fn parseChatAnswer(a: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(struct { text: []const u8 = "" }, a, body, .{ .ignore_unknown_fields = true }) catch return error.BadResponse;
    defer parsed.deinit();
    if (parsed.value.text.len == 0) return error.BadResponse;
    return a.dupe(u8, parsed.value.text);
}

pub const OnlineError = error{ SignedOut, Unavailable, BadResponse };

/// Ask online Henad. SignedOut on 401/403, Unavailable on anything else
/// that is not an answer, so the caller can fall back to offline.
pub fn askOnline(a: std.mem.Allocator, base: []const u8, token: []const u8, question: []const u8, history: []const openai.Message) ![]u8 {
    const q = try onlineQuestion(a, question);
    defer a.free(q);
    const body = try buildChatBody(a, q, history);
    defer a.free(body);
    const r = httpCall(a, .POST, base, "/agent/chat", token, body) catch return error.Unavailable;
    defer r.deinit(a);
    if (r.status == 401 or r.status == 403) return error.SignedOut;
    if (r.status != 200) return error.Unavailable;
    return parseChatAnswer(a, r.body) catch error.Unavailable;
}

pub const LoginResult = union(enum) {
    ok: []u8,
    rejected: u16,
};

/// POST /auth/login with the user's own email and password. Returns the
/// session token on success. The password is not stored.
pub fn login(a: std.mem.Allocator, base: []const u8, email: []const u8, password: []const u8) !LoginResult {
    const body = try std.json.stringifyAlloc(a, .{ .email = email, .password = password }, .{});
    defer {
        std.crypto.utils.secureZero(u8, body);
        a.free(body);
    }
    const r = try httpCall(a, .POST, base, "/auth/login", null, body);
    defer a.free(r.body);
    if (r.status == 200) if (r.session) |s| return .{ .ok = s };
    if (r.session) |s| a.free(s);
    return .{ .rejected = r.status };
}

// ------------------------------------------------------------ session file

/// `<config dir>/death-terminal/henad-session` (XDG_CONFIG_HOME or
/// ~/.config; %APPDATA% on Windows). `override_dir` is for tests.
pub fn sessionPath(a: std.mem.Allocator, override_dir: ?[]const u8) ![]u8 {
    if (override_dir) |d| return std.fs.path.join(a, &.{ d, session_file });
    var r = try paths.resolve(a);
    defer r.deinit(a);
    const dir = std.fs.path.dirname(r.shortcuts) orelse return error.NoHome;
    return std.fs.path.join(a, &.{ dir, session_file });
}

/// HENAD_SESSION (or the old NOUS_SESSION) wins (for CI and scripts), then the
/// session file, then the pre-rename `nous-session` file next to it.
pub fn loadToken(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (env_mod.get("HENAD_SESSION") orelse env_mod.get("NOUS_SESSION")) |v| {
        const tok = std.mem.trim(u8, v, " \r\n\t");
        if (tok.len > 0) return a.dupe(u8, tok) catch null;
    }
    const data = readSessionFile(a, path) orelse return null;
    const tok = std.mem.trim(u8, data, " \r\n\t");
    if (tok.len == 0) {
        a.free(data);
        return null;
    }
    const owned = a.dupe(u8, tok) catch null;
    a.free(data);
    return owned;
}

fn readSessionFile(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (paths.readFile(a, path, 4096) catch null) |data| return data;
    if (!std.mem.eql(u8, std.fs.path.basename(path), session_file)) return null;
    const dir = std.fs.path.dirname(path) orelse return null;
    const old = std.fs.path.join(a, &.{ dir, legacy_session_file }) catch return null;
    defer a.free(old);
    return paths.readFile(a, old, 4096) catch null;
}

pub fn saveToken(path: []const u8, token: []const u8) !void {
    try paths.replaceFile(path, token);
}

pub fn deleteToken(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
}

// ------------------------------------------------------------ tests

const t = std.testing;

test "henad: mode follows connectivity and sign-in" {
    try t.expectEqual(Mode.online, chooseMode(false, .ready));
    try t.expectEqual(Mode.offline, chooseMode(false, .no_network));
    try t.expectEqual(Mode.offline, chooseMode(false, .signed_out));
    try t.expectEqual(Mode.offline, chooseMode(false, .disabled));
    try t.expectEqual(Mode.offline, chooseMode(true, .ready));
    try t.expect(std.mem.indexOf(u8, onlineReason(.signed_out), "/signin") != null);
}

test "henad: parse and pick installed models" {
    const body = "{\"models\":[{\"name\":\"nomic-embed-text:latest\",\"size\":1},{\"name\":\"llama3.2:latest\"},{\"name\":\"qwen2.5-coder:0.5b\"}]}";
    const models = try parseModels(t.allocator, body);
    defer freeModels(t.allocator, models);
    try t.expectEqual(@as(usize, 3), models.len);
    try t.expectEqualStrings("qwen2.5-coder:0.5b", pickModel(models, "qwen2.5-coder:0.5b").?);
    try t.expectEqualStrings("llama3.2:latest", pickModel(models, "llama3.2").?);
    // Preferred not installed: first chat model, never the embedding one.
    try t.expectEqualStrings("llama3.2:latest", pickModel(models, "mistral").?);
    const only_embed = [_][]const u8{"nomic-embed-text:latest"};
    try t.expect(pickModel(&only_embed, "") == null);
    const junk = try parseModels(t.allocator, "not json");
    defer freeModels(t.allocator, junk);
    try t.expectEqual(@as(usize, 0), junk.len);
}

test "henad: commands come from fences only" {
    const answer =
        \\Start Ollama, then pull the model:
        \\```sh
        \\$ ollama serve
        \\# comment
        \\ollama pull qwen2.5-coder:0.5b
        \\```
        \\Then run `deathterminal --gui`.
        \\```
        \\deathterminal --ai-setup
        \\```
    ;
    const cmds = try extractCommands(t.allocator, answer);
    defer t.allocator.free(cmds);
    try t.expectEqual(@as(usize, 3), cmds.len);
    try t.expectEqualStrings("ollama serve", cmds[0]);
    try t.expectEqualStrings("ollama pull qwen2.5-coder:0.5b", cmds[1]);
    try t.expectEqualStrings("deathterminal --ai-setup", cmds[2]);
}

test "henad: destructive commands need the typed phrase" {
    const a = t.allocator;
    try t.expectEqual(Risk.normal, classifyCommand(a, "ollama pull qwen2.5-coder:0.5b"));
    try t.expectEqual(Risk.normal, classifyCommand(a, "deathterminal --ai-setup"));
    try t.expectEqual(Risk.destructive, classifyCommand(a, "rm -rf ~/.config/death-terminal"));
    try t.expectEqual(Risk.destructive, classifyCommand(a, "sudo launchctl kickstart -k system/ollama"));
    try t.expectEqual(Risk.destructive, classifyCommand(a, "curl -fsSL https://example.com/x.sh | sh"));
    try t.expectEqual(Risk.destructive, classifyCommand(a, "echo hi > ~/.zshrc"));
    try t.expectEqual(Risk.destructive, classifyCommand(a, "cd /tmp && rm old.log"));
    try t.expectEqual(Risk.destructive, classifyCommand(a, "git reset --hard"));
    try t.expect(confirmed(.normal, "y\n"));
    try t.expect(confirmed(.normal, " YES "));
    try t.expect(!confirmed(.normal, ""));
    try t.expect(!confirmed(.normal, "n"));
    try t.expect(!confirmed(.destructive, "y"));
    try t.expect(!confirmed(.destructive, "yes"));
    try t.expect(confirmed(.destructive, "Run it"));
}

test "henad: offline endpoint never points at a remote host" {
    try t.expectEqualStrings("http://127.0.0.1:11434/v1", offlineEndpoint("http://127.0.0.1:11434/v1"));
    try t.expectEqualStrings(ollama_endpoint, offlineEndpoint("https://api.x.ai/v1"));
    try t.expectError(error.NotLocal, askOffline(t.allocator, "https://api.x.ai/v1", "m", &.{}, null));
}

test "henad: fallback text when Ollama is down or has no model" {
    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();
    try writeOfflineHelp(buf.writer(), false, "Ollama: not running.\n");
    try t.expect(std.mem.indexOf(u8, buf.items, "ollama serve") != null);
    try t.expect(std.mem.indexOf(u8, buf.items, "ollama pull qwen2.5-coder:0.5b") != null);
    try t.expect(std.mem.indexOf(u8, buf.items, "Ollama: not running.") != null);
    buf.clearRetainingCapacity();
    try writeOfflineHelp(buf.writer(), true, "");
    try t.expect(std.mem.indexOf(u8, buf.items, "no chat model") != null);
}

test "henad: system prompt carries the check and the rules" {
    const p = try systemPrompt(t.allocator, "Ollama: running.");
    defer t.allocator.free(p);
    try t.expect(std.mem.indexOf(u8, p, "Ollama: running.") != null);
    try t.expect(std.mem.indexOf(u8, p, "```sh") != null);
    try t.expect(std.mem.indexOf(u8, p, slogan) != null);
}

test "henad: session cookie parsing" {
    try t.expectEqualStrings("abc123", parseSessionCookie("nf_session=abc123; Path=/; HttpOnly; Secure; SameSite=Strict").?);
    try t.expect(parseSessionCookie("other=1; Path=/") == null);
    try t.expect(parseSessionCookie("nf_session=\"\"; Max-Age=0") == null);
}

test "henad: online question is redacted and tagged" {
    const q = try onlineQuestion(t.allocator, "my key is OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz0123456789 help");
    defer t.allocator.free(q);
    try t.expect(std.mem.indexOf(u8, q, "sk-abcdefghijklmnopqrstuvwxyz0123456789") == null);
    try t.expect(std.mem.indexOf(u8, q, "Death Terminal") != null);
    const body = try buildChatBody(t.allocator, "hi", &.{.{ .role = "user", .content = "earlier" }});
    defer t.allocator.free(body);
    try t.expectEqualStrings("{\"question\":\"hi\",\"history\":[{\"role\":\"user\",\"content\":\"earlier\"}]}", body);
}

test "henad: session file round trip, 0600" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(t.allocator, ".");
    defer t.allocator.free(dir);
    const path = try sessionPath(t.allocator, dir);
    defer t.allocator.free(path);
    if (env_mod.get("HENAD_SESSION") == null) try t.expect(loadToken(t.allocator, path) == null);
    try saveToken(path, "tok-123\n");
    if (builtin.os.tag != .windows) {
        const st = try std.fs.cwd().statFile(path);
        try t.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.mode & 0o777)));
    }
    if (env_mod.get("HENAD_SESSION") == null) {
        const got = loadToken(t.allocator, path).?;
        defer t.allocator.free(got);
        try t.expectEqualStrings("tok-123", got);
    }
    deleteToken(path);
    try t.expect((try paths.readFile(t.allocator, path, 64)) == null);
}

test "henad: offline answer streams from a mock Ollama" {
    const mock = @import("mock_server.zig");
    const replies = [_]mock.Reply{.{ .chunks = &.{
        "data: {\"choices\":[{\"delta\":{\"content\":\"Start Ollama:\\n```sh\\nollama serve\\n```\"}}]}\n\n",
        "data: [DONE]\n\n",
    } }};
    const srv = try mock.MockServer.start(t.allocator, &replies);
    defer srv.deinit();
    const ep = try std.fmt.allocPrint(t.allocator, "http://127.0.0.1:{d}/v1", .{srv.port});
    defer t.allocator.free(ep);
    const msgs = [_]openai.Message{ .{ .role = "system", .content = "s" }, .{ .role = "user", .content = "Ollama won't start" } };
    const answer = try askOffline(t.allocator, ep, "qwen2.5-coder:0.5b", &msgs, null);
    defer t.allocator.free(answer);
    try t.expect(std.mem.indexOf(u8, answer, "ollama serve") != null);
    const cmds = try extractCommands(t.allocator, answer);
    defer t.allocator.free(cmds);
    try t.expectEqualStrings("ollama serve", cmds[0]);
}

test "henad: online sign-in, status, chat and fallback against a mock API" {
    const mock = @import("mock_server.zig");
    const json_ct = "application/json";
    const me = "{\"email\":\"user@example.com\"}";
    const denied = "{\"detail\":\"Sign in to continue.\"}";
    // probeOnline first opens and closes a bare TCP connection (the
    // reachability check). The mock counts that as a request, so each
    // probe has a throwaway reply in front of it.
    const dummy = mock.Reply{ .content_type = json_ct };
    const replies = [_]mock.Reply{
        .{ .head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nSet-Cookie: nf_session=sess-xyz; Path=/; HttpOnly\r\nConnection: close\r\n\r\n", .chunks = &.{me} }, // /auth/login
        dummy,
        .{ .content_type = json_ct, .chunks = &.{me} }, // /auth/me
        .{ .content_type = json_ct, .chunks = &.{"{\"text\":\"Open Settings, then Plugins.\",\"model\":true}"} }, // /agent/chat
        .{ .status = 401, .content_type = json_ct, .chunks = &.{denied} }, // /agent/chat, session expired
        dummy,
        .{ .status = 401, .content_type = json_ct, .chunks = &.{denied} }, // /auth/me, session expired
        dummy,
    };
    const srv = try mock.MockServer.start(t.allocator, &replies);
    defer srv.deinit();
    const base = try std.fmt.allocPrint(t.allocator, "http://127.0.0.1:{d}", .{srv.port});
    defer t.allocator.free(base);

    const lr = try login(t.allocator, base, "user@example.com", "pw");
    const token = switch (lr) {
        .ok => |s| s,
        .rejected => return error.TestUnexpectedResult,
    };
    defer t.allocator.free(token);
    try t.expectEqualStrings("sess-xyz", token);
    try t.expectEqual(OnlineState.ready, probeOnline(t.allocator, base, token, 1000));
    try t.expectEqual(Mode.online, chooseMode(false, .ready));

    const answer = try askOnline(t.allocator, base, token, "how do plugins work?", &.{});
    defer t.allocator.free(answer);
    try t.expectEqualStrings("Open Settings, then Plugins.", answer);
    try t.expectError(error.SignedOut, askOnline(t.allocator, base, token, "again", &.{}));
    try t.expectEqual(OnlineState.signed_out, probeOnline(t.allocator, base, token, 1000));
    try t.expectEqual(OnlineState.signed_out, probeOnline(t.allocator, base, null, 1000));

    // The bearer token went out; the password only to /auth/login.
    srv.mutex.lock();
    defer srv.mutex.unlock();
    var saw_login = false;
    var saw_me = false;
    var saw_chat = false;
    for (srv.requests.items) |r| {
        if (std.mem.startsWith(u8, r, "POST /auth/login")) {
            saw_login = true;
            try t.expect(std.mem.indexOf(u8, r, "\"password\":\"pw\"") != null);
            try t.expect(std.mem.indexOf(u8, r, "Bearer") == null);
        } else if (std.mem.startsWith(u8, r, "GET /auth/me")) {
            saw_me = true;
            try t.expect(std.mem.indexOf(u8, r, "Bearer sess-xyz") != null);
        } else if (std.mem.startsWith(u8, r, "POST /agent/chat")) {
            saw_chat = true;
            try t.expect(std.mem.indexOf(u8, r, "Bearer sess-xyz") != null);
            try t.expect(std.mem.indexOf(u8, r, "password") == null);
        }
    }
    try t.expect(saw_login and saw_me and saw_chat);
}

test "henad: unreachable API means offline" {
    // Port 9 (discard) on loopback is closed on CI runners.
    try t.expectEqual(OnlineState.no_network, probeOnline(t.allocator, "http://127.0.0.1:9", "tok", 500));
    try t.expectEqual(Mode.offline, chooseMode(false, .no_network));
}
