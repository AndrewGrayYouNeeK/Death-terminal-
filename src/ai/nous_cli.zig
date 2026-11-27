//! `deathterminal --nous`: the Nous chat loop. See nous.zig for the two
//! stages. Input and output are injected so the loop is tested without a
//! terminal, Ollama, or the network.

const std = @import("std");
const builtin = @import("builtin");
const nous = @import("nous.zig");
const doctor = @import("doctor.zig");
const openai = @import("openai.zig");

pub const Options = struct {
    /// Output of the built-in check (doctor.writeReport).
    report: []const u8,
    /// config.ai.endpoint and config.ai.model.
    endpoint: []const u8 = nous.ollama_endpoint,
    model: []const u8 = doctor.default_model,
    /// `--nous-model`.
    model_override: ?[]const u8 = null,
    /// `--nous-offline`.
    force_offline: bool = false,
    /// `--nous-url` or NOUS_URL. Default https://nous.youneek.dev.
    online_url: []const u8 = nous.default_online_url,
    /// Session file (nous.sessionPath).
    session_path: []const u8,
    /// One-shot question (`deathterminal --nous "..."`). Null = chat loop.
    question: ?[]const u8 = null,
    connect_ms: u32 = 2500,
};

pub const RunFn = *const fn (allocator: std.mem.Allocator, command: []const u8) u8;
pub const SecretFn = *const fn (allocator: std.mem.Allocator, prompt: []const u8, out: std.io.AnyWriter) anyerror![]u8;

pub const Io = struct {
    in: std.io.AnyReader,
    out: std.io.AnyWriter,
    run: RunFn = runShell,
    secret: SecretFn = readSecret,
};

const max_history = 12;

pub const Session = struct {
    a: std.mem.Allocator,
    opts: Options,
    io: Io,
    models: [][]u8 = &.{},
    model: ?[]const u8 = null,
    ollama_up: bool = false,
    token: ?[]u8 = null,
    email: ?[]u8 = null,
    online: nous.OnlineState = .signed_out,
    force_offline: bool = false,
    history: std.ArrayList(openai.Message),
    last_answer: ?[]u8 = null,
    commands: [][]const u8 = &.{},

    pub fn init(a: std.mem.Allocator, opts: Options, io: Io) Session {
        return .{ .a = a, .opts = opts, .io = io, .force_offline = opts.force_offline, .history = std.ArrayList(openai.Message).init(a) };
    }

    pub fn deinit(self: *Session) void {
        nous.freeModels(self.a, self.models);
        if (self.token) |tk| self.a.free(tk);
        if (self.email) |e| self.a.free(e);
        self.clearHistory();
        self.history.deinit();
        self.a.free(self.commands);
        if (self.last_answer) |s| self.a.free(s);
    }

    fn clearHistory(self: *Session) void {
        for (self.history.items) |m| self.a.free(m.content);
        self.history.clearRetainingCapacity();
    }

    pub fn mode(self: *const Session) nous.Mode {
        return nous.chooseMode(self.force_offline, self.online);
    }

    fn endpoint(self: *const Session) []const u8 {
        return nous.offlineEndpoint(self.opts.endpoint);
    }

    /// Ollama models, the session file, and the online check.
    pub fn detect(self: *Session) void {
        nous.freeModels(self.a, self.models);
        self.models = &.{};
        self.model = null;
        self.ollama_up = false;
        if (doctor.tagsUrl(self.a, self.endpoint())) |tags| {
            defer self.a.free(tags);
            const got = doctor.httpGet(self.a, tags) catch doctor.GetResult{};
            defer got.deinit(self.a);
            if (got.status == 200) {
                self.ollama_up = true;
                self.models = nous.parseModels(self.a, got.body) catch &.{};
                self.model = nous.pickModel(self.models, self.opts.model_override orelse self.opts.model);
            }
        } else |_| {}
        if (self.token == null) self.token = nous.loadToken(self.a, self.opts.session_path);
        self.checkOnline();
    }

    fn checkOnline(self: *Session) void {
        if (self.force_offline) {
            self.online = .disabled;
            return;
        }
        self.online = nous.probeOnline(self.a, self.opts.online_url, self.token, self.opts.connect_ms);
        if (self.online == .ready and self.email == null and self.token != null) {
            const r = nous.httpCall(self.a, .GET, self.opts.online_url, "/auth/me", self.token, null) catch return;
            defer r.deinit(self.a);
            self.email = nous.emailFrom(self.a, r.body);
        }
    }

    pub fn writeStatus(self: *Session) !void {
        const w = self.io.out;
        try w.print("{s} · {s}\n", .{ nous.name, nous.slogan });
        switch (self.mode()) {
            .online => try w.print("Mode: ONLINE · Nous at {s}{s}{s}. Questions go to your Nous account.\n", .{
                hostOf(self.opts.online_url),
                if (self.email != null) ", signed in as " else "",
                self.email orelse "",
            }),
            .offline => {
                if (self.model) |m| {
                    try w.print("Mode: OFFLINE · local Ollama ({s}). Nothing leaves this machine.\n", .{m});
                } else {
                    try w.writeAll("Mode: OFFLINE · local Ollama is not ready.\n");
                }
                try w.print("Online Nous: {s}.\n", .{nous.onlineReason(self.online)});
            },
        }
    }

    pub fn writeHelp(self: *Session) !void {
        try self.io.out.writeAll(
            \\Ask anything about setting up Death Terminal. Commands:
            \\  /run N     run suggested command N (asks first; destructive ones need "run it")
            \\  /status    show the mode and re-check Ollama and the network
            \\  /models    list local Ollama models
            \\  /signin    sign in to your own Nous account (online mode)
            \\  /signout   sign out and delete the saved session
            \\  /offline   stay offline   /online   allow online again
            \\  /doctor    print the built-in check
            \\  /clear     forget this conversation   /quit   leave
            \\
        );
    }

    /// Answer one question in the active mode. Online failures fall back
    /// to offline for this answer and say so.
    pub fn ask(self: *Session, question: []const u8) !void {
        const w = self.io.out;
        var answer: ?[]u8 = null;
        if (self.mode() == .online) {
            if (nous.askOnline(self.a, self.opts.online_url, self.token.?, question, self.history.items)) |text| {
                try w.writeAll("Nous (online): ");
                try w.writeAll(text);
                try w.writeAll("\n");
                answer = text;
            } else |err| {
                self.online = if (err == error.SignedOut) .signed_out else .no_network;
                try w.print("[Online Nous is unavailable ({s}). Switching to offline.]\n", .{nous.onlineReason(self.online)});
            }
        }
        if (answer == null) {
            const model = self.model orelse {
                try nous.writeOfflineHelp(w, self.ollama_up, self.opts.report);
                return;
            };
            const sys = try nous.systemPrompt(self.a, self.opts.report);
            defer self.a.free(sys);
            var msgs = std.ArrayList(openai.Message).init(self.a);
            defer msgs.deinit();
            try msgs.append(.{ .role = "system", .content = sys });
            try msgs.appendSlice(self.history.items);
            try msgs.append(.{ .role = "user", .content = question });
            try w.writeAll("Nous (offline): ");
            answer = nous.askOffline(self.a, self.endpoint(), model, msgs.items, w) catch |err| {
                try w.print("\n[Local Ollama did not answer ({s}).]\n", .{@errorName(err)});
                self.ollama_up = false;
                self.model = null;
                try nous.writeOfflineHelp(w, false, self.opts.report);
                return;
            };
            try w.writeAll("\n");
        }
        const text = answer.?;
        try self.remember("user", question);
        try self.remember("assistant", text);
        if (self.last_answer) |old| self.a.free(old);
        self.last_answer = text;
        self.a.free(self.commands);
        self.commands = try nous.extractCommands(self.a, text);
        if (self.commands.len > 0) {
            try w.writeAll("\nSuggested commands (nothing runs until you type /run N and confirm):\n");
            for (self.commands, 1..) |c, i| {
                const risk = nous.classifyCommand(self.a, c);
                try w.print("  {d}. {s}{s}\n", .{ i, c, if (risk == .destructive) "   [destructive]" else "" });
            }
        }
    }

    fn remember(self: *Session, role: []const u8, content: []const u8) !void {
        if (self.history.items.len >= max_history) {
            self.a.free(self.history.items[0].content);
            _ = self.history.orderedRemove(0);
        }
        try self.history.append(.{ .role = role, .content = try self.a.dupe(u8, content) });
    }

    /// `/run N`. Asks first; a destructive command needs "run it".
    pub fn runSuggestion(self: *Session, arg: []const u8) !void {
        const w = self.io.out;
        const n = std.fmt.parseInt(usize, std.mem.trim(u8, arg, " "), 10) catch 0;
        if (n == 0 or n > self.commands.len) {
            try w.print("No suggestion {s}. Pick 1 to {d}.\n", .{ arg, self.commands.len });
            return;
        }
        const cmd = self.commands[n - 1];
        const risk = nous.classifyCommand(self.a, cmd);
        try w.print("Command: {s}\n", .{cmd});
        if (risk == .destructive) {
            try w.print("WARNING: this command can delete or change things that are hard to undo.\nType \"{s}\" to run it, anything else cancels: ", .{nous.destructive_phrase});
        } else {
            try w.writeAll("Run it? [y/N] ");
        }
        var buf: [256]u8 = undefined;
        const reply = (try readLine(self.io.in, &buf)) orelse "";
        if (!nous.confirmed(risk, reply)) {
            try w.writeAll("Cancelled. Nothing ran.\n");
            return;
        }
        const code = self.io.run(self.a, cmd);
        try w.print("[exit {d}]\n", .{code});
    }

    pub fn signIn(self: *Session) !void {
        const w = self.io.out;
        if (!nous.reachable(self.opts.online_url, self.opts.connect_ms)) {
            try w.print("Cannot reach {s}. Stay offline until the network is up.\n", .{hostOf(self.opts.online_url)});
            return;
        }
        try w.print("Sign in to your Nous account at {s}. No account yet? Sign up at {s}\nEmail: ", .{ hostOf(self.opts.online_url), self.opts.online_url });
        var ebuf: [320]u8 = undefined;
        const email_raw = (try readLine(self.io.in, &ebuf)) orelse return;
        const email = std.mem.trim(u8, email_raw, " \t\r");
        if (email.len == 0) return;
        const password = try self.io.secret(self.a, "Password (not shown, not saved): ", w);
        defer {
            std.crypto.utils.secureZero(u8, password);
            self.a.free(password);
        }
        const res = nous.login(self.a, self.opts.online_url, email, password) catch |err| {
            try w.print("Sign-in failed: {s}. Still offline.\n", .{@errorName(err)});
            return;
        };
        switch (res) {
            .rejected => |code| {
                try w.print("Sign-in was refused (HTTP {d}). Check the email and password. Still offline.\n", .{code});
            },
            .ok => |tok| {
                if (self.token) |old| self.a.free(old);
                self.token = tok;
                nous.saveToken(self.opts.session_path, tok) catch |err| {
                    try w.print("Signed in, but the session could not be saved ({s}); you will need /signin next time.\n", .{@errorName(err)});
                };
                if (self.email) |e| self.a.free(e);
                self.email = self.a.dupe(u8, email) catch null;
                self.force_offline = false;
                self.checkOnline();
                try self.writeStatus();
            },
        }
    }

    pub fn signOut(self: *Session) !void {
        if (self.token) |tk| {
            if (nous.httpCall(self.a, .POST, self.opts.online_url, "/auth/logout", tk, "{}")) |r| r.deinit(self.a) else |_| {}
            self.a.free(tk);
            self.token = null;
        }
        if (self.email) |e| self.a.free(e);
        self.email = null;
        nous.deleteToken(self.opts.session_path);
        self.online = .signed_out;
        try self.io.out.writeAll("Signed out. The saved session is deleted. Nous is offline.\n");
    }

    /// Handle one input line. Returns false to quit.
    pub fn handle(self: *Session, line_raw: []const u8) !bool {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) return true;
        const w = self.io.out;
        if (line[0] != '/') {
            try self.ask(line);
            return true;
        }
        const sp = std.mem.indexOfScalar(u8, line, ' ');
        const cmd = if (sp) |i| line[0..i] else line;
        const arg = if (sp) |i| line[i + 1 ..] else "";
        if (eq(cmd, "/quit") or eq(cmd, "/exit")) return false;
        if (eq(cmd, "/help")) {
            try self.writeHelp();
        } else if (eq(cmd, "/run")) {
            try self.runSuggestion(arg);
        } else if (eq(cmd, "/status")) {
            self.detect();
            try self.writeStatus();
        } else if (eq(cmd, "/models")) {
            if (self.models.len == 0) try w.writeAll("No local models (is Ollama running? `ollama pull qwen2.5-coder:0.5b`).\n");
            for (self.models) |m| try w.print("  {s}{s}\n", .{ m, if (self.model != null and std.mem.eql(u8, self.model.?, m)) "  (in use)" else "" });
        } else if (eq(cmd, "/signin") or eq(cmd, "/login")) {
            try self.signIn();
        } else if (eq(cmd, "/signout") or eq(cmd, "/logout")) {
            try self.signOut();
        } else if (eq(cmd, "/offline")) {
            self.force_offline = true;
            self.online = .disabled;
            try self.writeStatus();
        } else if (eq(cmd, "/online")) {
            self.force_offline = false;
            self.checkOnline();
            try self.writeStatus();
        } else if (eq(cmd, "/doctor")) {
            try w.writeAll(self.opts.report);
        } else if (eq(cmd, "/clear")) {
            self.clearHistory();
            try w.writeAll("Conversation cleared.\n");
        } else {
            try w.print("Unknown command {s}. /help lists them.\n", .{cmd});
        }
        return true;
    }

    /// The whole session. Returns the process exit code.
    pub fn run(self: *Session) !u8 {
        self.detect();
        try self.writeStatus();
        if (self.opts.question) |q| {
            try self.ask(q);
            return if (self.model == null and self.mode() == .offline) 1 else 0;
        }
        if (self.mode() == .offline and self.model == null) {
            try self.io.out.writeAll("\n");
            try nous.writeOfflineHelp(self.io.out, self.ollama_up, self.opts.report);
            try self.io.out.writeAll("\nYou can still type /signin, /status or /quit.\n");
        }
        try self.io.out.writeAll("Type a question, or /help.\n");
        var buf: [4096]u8 = undefined;
        while (true) {
            try self.io.out.print("\n{s}> ", .{if (self.mode() == .online) "nous·online" else "nous·offline"});
            const line = (try readLine(self.io.in, &buf)) orelse break;
            if (!try self.handle(line)) break;
        }
        return 0;
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn hostOf(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    return std.mem.trimRight(u8, s, "/");
}

fn readLine(r: std.io.AnyReader, buf: []u8) !?[]const u8 {
    const line = r.readUntilDelimiterOrEof(buf, '\n') catch |err| switch (err) {
        error.StreamTooLong => {
            r.skipUntilDelimiterOrEof('\n') catch {};
            return buf;
        },
        else => return err,
    };
    return if (line) |l| std.mem.trimRight(u8, l, "\r") else null;
}

/// Run `command` with the user's shell attached to this terminal.
pub fn runShell(a: std.mem.Allocator, command: []const u8) u8 {
    const argv: []const []const u8 = if (builtin.os.tag == .windows) &.{ "cmd.exe", "/C", command } else &.{ "/bin/sh", "-c", command };
    var child = std.process.Child.init(argv, a);
    const term = child.spawnAndWait() catch return 127;
    return switch (term) {
        .Exited => |c| c,
        else => 1,
    };
}

/// Read a line from the terminal with echo off (POSIX). On Windows the
/// console echoes; the prompt says so.
pub fn readSecret(a: std.mem.Allocator, prompt: []const u8, out: std.io.AnyWriter) ![]u8 {
    const stdin = std.io.getStdIn();
    try out.writeAll(prompt);
    const echo_off = if (comptime builtin.os.tag != .windows) disableEcho(stdin) else null;
    defer if (comptime builtin.os.tag != .windows) {
        if (echo_off) |old| {
            std.posix.tcsetattr(stdin.handle, .NOW, old) catch {};
            out.writeAll("\n") catch {};
        }
    };
    var buf: [512]u8 = undefined;
    const line = (try readLine(stdin.reader().any(), &buf)) orelse "";
    const owned = try a.dupe(u8, line);
    std.crypto.utils.secureZero(u8, &buf);
    return owned;
}

const Termios = if (builtin.os.tag == .windows) void else std.posix.termios;

/// Echo off on a TTY. Returns the old settings to restore, or null.
fn disableEcho(stdin: std.fs.File) ?Termios {
    if (comptime builtin.os.tag == .windows) return null;
    if (!stdin.isTty()) return null;
    const old = std.posix.tcgetattr(stdin.handle) catch return null;
    var raw = old;
    raw.lflag.ECHO = false;
    std.posix.tcsetattr(stdin.handle, .NOW, raw) catch return null;
    return old;
}

// ------------------------------------------------------------ tests

const t = std.testing;

var ran_count: usize = 0;
fn fakeRun(_: std.mem.Allocator, _: []const u8) u8 {
    ran_count += 1;
    return 0;
}
fn fakeSecret(a: std.mem.Allocator, _: []const u8, _: std.io.AnyWriter) anyerror![]u8 {
    return a.dupe(u8, "pw");
}

fn testSession(a: std.mem.Allocator, in: std.io.AnyReader, out: std.io.AnyWriter, session_path: []const u8) Session {
    return Session.init(a, .{
        .report = "Ollama: running.\n",
        .session_path = session_path,
        .online_url = "http://127.0.0.1:9",
        .connect_ms = 300,
    }, .{ .in = in, .out = out, .run = fakeRun, .secret = fakeSecret });
}

test "nous cli: /run asks first and needs the phrase for destructive commands" {
    var input = std.io.fixedBufferStream("n\nyes\nrun it\ny\n");
    var out = std.ArrayList(u8).init(t.allocator);
    defer out.deinit();
    var s = testSession(t.allocator, input.reader().any(), out.writer().any(), "/nonexistent/nous-session");
    defer s.deinit();
    s.last_answer = try t.allocator.dupe(u8, "```sh\nrm -rf ~/.config/death-terminal\nollama pull qwen2.5-coder:0.5b\n```");
    s.commands = try nous.extractCommands(t.allocator, s.last_answer.?);
    ran_count = 0;
    _ = try s.handle("/run 1"); // "n" → cancelled
    try t.expectEqual(@as(usize, 0), ran_count);
    _ = try s.handle("/run 1"); // "yes" is not enough for rm -rf
    try t.expectEqual(@as(usize, 0), ran_count);
    try t.expect(std.mem.indexOf(u8, out.items, "WARNING") != null);
    _ = try s.handle("/run 1"); // "run it"
    try t.expectEqual(@as(usize, 1), ran_count);
    _ = try s.handle("/run 2"); // "y" for a normal command
    try t.expectEqual(@as(usize, 2), ran_count);
    _ = try s.handle("/run 7");
    try t.expect(std.mem.indexOf(u8, out.items, "No suggestion 7") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "Cancelled. Nothing ran.") != null);
}

test "nous cli: offline with no Ollama prints the fallback, never crashes" {
    var input = std.io.fixedBufferStream("");
    var out = std.ArrayList(u8).init(t.allocator);
    defer out.deinit();
    var s = testSession(t.allocator, input.reader().any(), out.writer().any(), "/nonexistent/nous-session");
    defer s.deinit();
    s.online = .no_network;
    try s.writeStatus();
    try s.ask("how do I set up ssh?");
    try t.expect(std.mem.indexOf(u8, out.items, "Mode: OFFLINE") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "not reachable") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "ollama serve") != null);
    try t.expect(!try s.handle("/quit"));
}

test "nous cli: online answer, then fallback to offline when the session expires" {
    const mock = @import("mock_server.zig");
    const replies = [_]mock.Reply{
        .{ .content_type = "application/json", .chunks = &.{"{\"text\":\"Plugins:\\n```sh\\ndeathterminal --plugins list\\n```\"}"} },
        .{ .status = 401, .content_type = "application/json", .chunks = &.{"{\"detail\":\"Sign in to continue.\"}"} },
    };
    const srv = try mock.MockServer.start(t.allocator, &replies);
    defer srv.deinit();
    const base = try std.fmt.allocPrint(t.allocator, "http://127.0.0.1:{d}", .{srv.port});
    defer t.allocator.free(base);

    var input = std.io.fixedBufferStream("");
    var out = std.ArrayList(u8).init(t.allocator);
    defer out.deinit();
    var s = testSession(t.allocator, input.reader().any(), out.writer().any(), "/nonexistent/nous-session");
    defer s.deinit();
    s.opts.online_url = base;
    s.token = try t.allocator.dupe(u8, "sess-abc");
    s.online = .ready;
    try t.expectEqual(nous.Mode.online, s.mode());
    try s.writeStatus();
    try s.ask("what are plugins?");
    try t.expect(std.mem.indexOf(u8, out.items, "Mode: ONLINE") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "Nous (online): Plugins:") != null);
    try t.expectEqualStrings("deathterminal --plugins list", s.commands[0]);
    try s.ask("and themes?");
    try t.expectEqual(nous.Mode.offline, s.mode());
    try t.expect(std.mem.indexOf(u8, out.items, "Switching to offline") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "ollama serve") != null);
}

test "nous cli: /offline forces offline even when signed in" {
    var input = std.io.fixedBufferStream("");
    var out = std.ArrayList(u8).init(t.allocator);
    defer out.deinit();
    var s = testSession(t.allocator, input.reader().any(), out.writer().any(), "/nonexistent/nous-session");
    defer s.deinit();
    s.online = .ready;
    _ = try s.handle("/offline");
    try t.expectEqual(nous.Mode.offline, s.mode());
    try t.expect(std.mem.indexOf(u8, out.items, "turned off") != null);
}
