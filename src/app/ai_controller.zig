//! Glue between the terminal, the UI and the AI engine: decides when to
//! ask for a suggestion (after a typing pause, at a prompt), turns replies
//! into ghost text, runs "explain last error" and keeps the status tag.

const std = @import("std");
const posix = std.posix;
const terminal = @import("../terminal/terminal.zig");
const config = @import("../config/config.zig");
const ui_mod = @import("ui.zig");
const engine_mod = @import("../ai/engine.zig");
const context = @import("../ai/context.zig");
const si = terminal.shell_integration;

const Terminal = terminal.Terminal;
const Ui = ui_mod.Ui;
const Engine = engine_mod.Engine;

pub const Settings = struct {
    enabled: bool = true,
    endpoint: []const u8 = "http://localhost:11434/v1",
    model: []const u8 = "",
    api_key_env: []const u8 = "",
    timeout_ms: u32 = 5000,
    debounce_ms: u32 = 300,
    max_tokens: u16 = 64,
    explain_max_tokens: u16 = 400,
    history: u16 = 5,
    output_lines: u16 = 20,
    /// Shell program for the context ("" = $SHELL).
    shell: []const u8 = "",
    /// "user@host" when the terminal runs an SSH session (see context.zig).
    remote: []const u8 = "",

    pub fn fromConfig(cfg: *const config.Config) Settings {
        return .{
            .enabled = cfg.ai_enabled,
            .endpoint = cfg.ai_endpoint,
            .model = cfg.ai_model,
            .api_key_env = cfg.ai_api_key_env,
            .timeout_ms = cfg.ai_timeout_ms,
            .debounce_ms = cfg.ai_debounce_ms,
            .max_tokens = cfg.ai_max_tokens,
            .explain_max_tokens = cfg.ai_explain_max_tokens,
            .history = cfg.ai_history,
            .output_lines = cfg.ai_output_lines,
            .shell = cfg.shell_program,
        };
    }

    fn engineOptions(self: Settings) engine_mod.Options {
        return .{ .endpoint = self.endpoint, .model = self.model, .api_key_env = self.api_key_env, .timeout_ms = self.timeout_ms };
    }
};

/// Shortest input worth asking about.
const min_input = 2;

pub const Controller = struct {
    allocator: std.mem.Allocator,
    settings: Settings,
    engine: ?*Engine = null,
    /// When to ask for a suggestion (ms timestamp), after a typing pause.
    due_ms: ?i64 = null,
    suggest_gen: u64 = 0,
    /// Input and cursor position the outstanding suggestion is for.
    suggest_input: std.ArrayList(u8),
    suggest_anchor: ?si.Mark = null,
    explain_gen: u64 = 0,
    explain_title: std.ArrayList(u8),
    shown_status: ?engine_mod.Status = null,

    pub fn init(allocator: std.mem.Allocator, settings: Settings) Controller {
        var self = Controller{
            .allocator = allocator,
            .settings = settings,
            .suggest_input = std.ArrayList(u8).init(allocator),
            .explain_title = std.ArrayList(u8).init(allocator),
        };
        self.startEngine();
        return self;
    }

    pub fn deinit(self: *Controller) void {
        if (self.engine) |e| e.deinit();
        self.suggest_input.deinit();
        self.explain_title.deinit();
    }

    fn startEngine(self: *Controller) void {
        if (!self.settings.enabled) return;
        self.engine = Engine.init(self.allocator, self.settings.engineOptions()) catch |err| blk: {
            std.debug.print("ai: cannot start the worker ({s}); suggestions off\n", .{@errorName(err)});
            break :blk null;
        };
    }

    /// Config reload. `settings` slices must outlive the controller's use
    /// (they point into the live config).
    pub fn applySettings(self: *Controller, ui: *Ui, settings: Settings) void {
        const was = self.settings;
        self.settings = settings;
        if (!settings.enabled) {
            if (self.engine) |e| e.deinit();
            self.engine = null;
            ui.clearGhost();
            ui.setAiStatus(null);
            self.shown_status = null;
            return;
        }
        if (self.engine) |e| {
            if (!std.mem.eql(u8, was.endpoint, settings.endpoint) or !std.mem.eql(u8, was.model, settings.model) or
                !std.mem.eql(u8, was.api_key_env, settings.api_key_env) or was.timeout_ms != settings.timeout_ms)
            {
                e.setOptions(settings.engineOptions()) catch {};
                ui.setAiStatus(null);
                self.shown_status = null;
            }
        } else self.startEngine();
    }

    pub fn wakeFd(self: *const Controller) posix.fd_t {
        return if (self.engine) |e| e.wakeFd() else -1;
    }

    /// Milliseconds until `tick` has work (for the poll timeout).
    pub fn timeout(self: *const Controller, now_ms: i64) ?i64 {
        const d = self.due_ms orelse return null;
        return @max(0, d - now_ms);
    }

    /// The user sent `bytes` (typed text) to the shell.
    pub fn onTyped(self: *Controller, ui: *Ui, term: *const Terminal, bytes: []const u8, now_ms: i64) void {
        if (self.engine == null) return;
        // Typing along the ghost text keeps it; no new request needed.
        if (ui.ghostTyped(term, bytes)) {
            self.due_ms = null;
            return;
        }
        self.onKeystroke(ui, now_ms);
    }

    /// Any other key sent to the shell (arrows, backspace, Enter, ...):
    /// the old suggestion is stale.
    pub fn onKeystroke(self: *Controller, ui: *Ui, now_ms: i64) void {
        const e = self.engine orelse return;
        ui.clearGhost();
        if (self.suggest_anchor != null) e.cancelAll();
        self.suggest_anchor = null;
        self.due_ms = now_ms + self.settings.debounce_ms;
    }

    /// A suggestion was accepted: nothing to ask until the next keystroke.
    pub fn onAccepted(self: *Controller) void {
        self.due_ms = null;
        self.suggest_anchor = null;
    }

    /// Fire the debounced request when due. Returns whether the UI changed.
    pub fn tick(self: *Controller, term: *const Terminal, now_ms: i64) void {
        const d = self.due_ms orelse return;
        if (now_ms < d) return;
        self.due_ms = null;
        self.requestSuggestion(term) catch |err| std.log.debug("ai: suggestion request failed: {s}", .{@errorName(err)});
    }

    fn shellName(self: *const Controller) []const u8 {
        if (self.settings.shell.len > 0) return self.settings.shell;
        return posix.getenv("SHELL") orelse "sh";
    }

    fn baseContext(self: *const Controller, arena: std.mem.Allocator, term: *const Terminal, input: []const u8) !context.Context {
        var cwd: []const u8 = "";
        if (term.cwd_uri.len > 0) {
            const buf = try arena.alloc(u8, std.fs.max_path_bytes);
            cwd = si.cwdFromUri(term.cwd_uri, buf) orelse "";
        }
        const hist = term.shell.history.items;
        const n = @min(hist.len, self.settings.history);
        const items = try arena.alloc(context.HistoryItem, n);
        for (hist[hist.len - n ..], items) |h, *dst| dst.* = .{ .command = h.text, .exit_code = h.exit_code };
        const remote = self.settings.remote;
        return .{ .input = input, .cwd = cwd, .shell = if (remote.len > 0) "" else self.shellName(), .history = items, .remote = remote };
    }

    fn tailLines(text: []const u8, n: usize) []const u8 {
        if (n == 0) return "";
        var count: usize = 0;
        var i = text.len;
        while (i > 0) : (i -= 1) {
            if (text[i - 1] == '\n') {
                count += 1;
                if (count == n) return text[i..];
            }
        }
        return text;
    }

    fn requestSuggestion(self: *Controller, term: *const Terminal) !void {
        const e = self.engine orelse return;
        const input = (try term.currentInput(self.allocator)) orelse return;
        defer self.allocator.free(input);
        if (std.mem.trim(u8, input, " ").len < min_input) return;

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var ctx = try self.baseContext(arena, term, input);
        if (term.shell.lastCommand()) |last| {
            ctx.output = tailLines(last.output, self.settings.output_lines);
        } else if (self.settings.output_lines > 0) {
            // No shell integration: the screen above the prompt row.
            const text = try term.recentText(arena, self.settings.output_lines + 1);
            const nl = std.mem.lastIndexOfScalar(u8, text, '\n') orelse 0;
            ctx.output = text[0..nl];
        }
        const msgs = try context.suggestMessages(arena, ctx);
        self.suggest_gen = try e.submit(.suggest, msgs, self.settings.max_tokens, context.max_alternatives);
        self.suggest_input.clearRetainingCapacity();
        try self.suggest_input.appendSlice(input);
        self.suggest_anchor = term.cursorMark();
    }

    /// "Explain/fix last error": ask about the most recent failed command
    /// (or, without shell integration, the visible output).
    pub fn explain(self: *Controller, ui: *Ui, term: *const Terminal, now_ms: i64) !void {
        const e = self.engine orelse {
            try ui.setNotice(.info, "AI is disabled (config.ai.enabled = false or --no-ai)", &.{}, 4000, now_ms);
            return;
        };
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const ctx = try self.baseContext(arena, term, "");

        var failed: context.HistoryItem = .{ .command = "(not recorded; see the output)" };
        var output: []const u8 = "";
        const hist = term.shell.history.items;
        var found: ?*const si.Command = null;
        var i = hist.len;
        while (i > 0) : (i -= 1) {
            const c = &hist[i - 1];
            if (c.exit_code != null and c.exit_code.? != 0) {
                found = c;
                break;
            }
        }
        if (found == null and hist.len > 0) found = &hist[hist.len - 1];
        if (found) |c| {
            failed = .{ .command = c.text, .exit_code = c.exit_code };
            output = tailLines(c.output, @max(self.settings.output_lines, 40));
        } else {
            output = try term.recentText(arena, 40);
        }
        const msgs = try context.explainMessages(arena, ctx, failed, output);
        self.explain_gen = try e.submit(.explain, msgs, self.settings.explain_max_tokens, 0);
        // A suggestion request was just cancelled by this one.
        self.suggest_anchor = null;
        ui.clearGhost();

        self.explain_title.clearRetainingCapacity();
        const w = self.explain_title.writer();
        if (found) |c| {
            const short = c.text[0..@min(c.text.len, 60)];
            try w.print("AI: why did `{s}{s}` fail", .{ short, if (c.text.len > 60) "\u{2026}" else "" });
            if (c.exit_code) |code| try w.print(" (exit {d})", .{code});
            try w.writeAll("?");
        } else try w.writeAll("AI: what went wrong here?");
        try ui.setAiNotice(self.explain_title.items, "thinking\u{2026}", now_ms);
    }

    /// The engine signalled: collect streamed text. Returns whether the
    /// UI changed.
    pub fn onWake(self: *Controller, ui: *Ui, term: *const Terminal, now_ms: i64) !bool {
        const e = self.engine orelse return false;
        var changed = false;
        while (try e.take(self.allocator)) |u| {
            defer self.allocator.free(u.text);
            if (u.kind == .suggest and u.gen == self.suggest_gen) {
                changed = try self.showSuggestion(ui, term, u) or changed;
            } else if (u.kind == .explain and u.gen == self.explain_gen) {
                // Only while our answer is still the notice on screen.
                if (ui.notice == null or ui.notice.?.kind != .ai) continue;
                if (u.failed) |_| {
                    var buf: [96]u8 = undefined;
                    const why = e.statusText(&buf);
                    var line_buf: [160]u8 = undefined;
                    const line = std.fmt.bufPrint(&line_buf, "The AI endpoint is not available ({s}). Check config.ai.endpoint / that Ollama is running.", .{if (why.len > 0) why else "error"}) catch "The AI endpoint is not available.";
                    try ui.setAiNotice(self.explain_title.items, line, now_ms);
                } else {
                    const body = if (u.done) u.text else try std.fmt.allocPrint(self.allocator, "{s}\u{2026}", .{u.text});
                    defer if (!u.done) self.allocator.free(body);
                    try ui.setAiNotice(self.explain_title.items, if (body.len > 0) body else "(no answer)", now_ms);
                }
                changed = true;
            }
        }
        changed = self.syncStatus(ui) or changed;
        return changed;
    }

    fn showSuggestion(self: *Controller, ui: *Ui, term: *const Terminal, u: engine_mod.Update) !bool {
        const anchor = self.suggest_anchor orelse return false;
        if (u.failed != null) {
            if (u.done) self.suggest_anchor = null;
            return false;
        }
        // Still exactly where we asked?
        if (!std.meta.eql(anchor, term.cursorMark())) return false;
        // While streaming, only complete lines count.
        const text = if (u.done) u.text else u.text[0 .. (std.mem.lastIndexOfScalar(u8, u.text, '\n') orelse return false) + 1];
        const list = try context.parseSuggestions(self.allocator, self.suggest_input.items, text, context.max_alternatives);
        if (list.len == 0) {
            context.freeSuggestions(self.allocator, list);
            return false;
        }
        // Keep the user's current pick if the list only grew.
        const keep = if (ui.ghost) |g| g.index else 0;
        try ui.setSuggestions(term, list);
        if (ui.ghost) |*g| g.index = @min(keep, g.alternatives.items.len - 1);
        if (u.done) self.suggest_anchor = null;
        return true;
    }

    fn syncStatus(self: *Controller, ui: *Ui) bool {
        const e = self.engine orelse return false;
        const st = e.getStatus();
        if (self.shown_status != null and self.shown_status.? == st) return false;
        self.shown_status = st;
        ui.setAiStatus(if (st == .offline) "AI offline" else null);
        return true;
    }
};

// ------------------------------------------------------------------ tests

const mock = @import("../ai/mock_server.zig");
const t = std.testing;

fn waitFor(c: *Controller, ui: *Ui, term: *Terminal, comptime pred: fn (*Ui) bool) !void {
    const deadline = std.time.milliTimestamp() + 3000;
    while (std.time.milliTimestamp() < deadline) {
        var fds = [_]posix.pollfd{.{ .fd = c.wakeFd(), .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 50);
        _ = try c.onWake(ui, term, std.time.milliTimestamp());
        if (pred(ui)) return;
    }
    return error.TestTimeout;
}

fn hasTwoAlternatives(ui: *Ui) bool {
    const g = ui.ghost orelse return false;
    return g.alternatives.items.len == 2;
}

test "controller: typing at a prompt yields ghost text, Tab-accept writes it" {
    const replies = [_]mock.Reply{.{ .chunks = mock.sse(&.{ "git push origin main\\n", "git pull\\n" }) }};
    const srv = try mock.MockServer.start(t.allocator, &replies);
    defer srv.deinit();
    var url_buf: [64]u8 = undefined;
    var term = try Terminal.initBuffer(t.allocator, 6, 60, 16);
    defer term.deinit();
    var ui = Ui.init(t.allocator, .{});
    defer ui.deinit();
    var c = Controller.init(t.allocator, .{ .endpoint = srv.url(&url_buf), .model = "m", .debounce_ms = 0 });
    defer c.deinit();

    try term.processOutput("\x1b]133;A\x07$ \x1b]133;B\x07git pu");
    c.onTyped(&ui, &term, "u", 0);
    c.tick(&term, 0);
    try waitFor(&c, &ui, &term, hasTwoAlternatives);
    try t.expectEqualStrings("sh origin main", ui.ghostText().?);
    try t.expect(ui.ghostVisible(&term));
    // The request carried the typed input.
    try t.expect(std.mem.indexOf(u8, srv.requests.items[0], "Typed so far: git pu") != null);

    // Alt+] cycles, Tab accepts: the suffix goes to the shell.
    try t.expect(try ui.handleAction(&term, .ai_next));
    try t.expectEqualStrings("ll", ui.ghostText().?);
    try t.expect(try ui.handleAction(&term, .ai_prev));
    try t.expect(try ui.handleAction(&term, .ai_accept));
    const fx = try ui.takeEffects();
    defer ui.freeEffects(fx);
    try t.expectEqualStrings("sh origin main", fx[0].write);
    try t.expect(ui.ghost == null);
    // Nothing showing: Tab is not consumed (the shell completes).
    try t.expect(!try ui.handleAction(&term, .ai_accept));
}

test "controller: the ghost follows typed characters and hides when the cursor moves" {
    var term = try Terminal.initBuffer(t.allocator, 4, 40, 16);
    defer term.deinit();
    var ui = Ui.init(t.allocator, .{});
    defer ui.deinit();
    try term.processOutput("$ ls");
    var list = try t.allocator.alloc([]u8, 1);
    list[0] = try t.allocator.dupe(u8, " -la");
    try ui.setSuggestions(&term, list);
    try t.expect(ui.ghostVisible(&term));
    // Typing the next ghost character keeps the rest.
    try t.expect(ui.ghostTyped(&term, " "));
    try term.processOutput(" ");
    try t.expectEqualStrings("-la", ui.ghostText().?);
    try t.expect(ui.ghostVisible(&term));
    // Esc dismisses; nothing is written.
    try t.expect(try ui.handleAction(&term, .ai_dismiss));
    try t.expect(ui.ghost == null);
    try t.expectEqual(@as(usize, 0), ui.effects.items.len);
    // A different character drops the suggestion.
    list = try t.allocator.alloc([]u8, 1);
    list[0] = try t.allocator.dupe(u8, "-la");
    try ui.setSuggestions(&term, list);
    try t.expect(!ui.ghostTyped(&term, "x"));
    try t.expect(ui.ghost == null);
    // Cursor moved: hidden (and not accepted by Tab).
    list = try t.allocator.alloc([]u8, 1);
    list[0] = try t.allocator.dupe(u8, "-la");
    try ui.setSuggestions(&term, list);
    try term.processOutput("\x1b[D");
    try t.expect(!ui.ghostVisible(&term));
    try t.expect(!try ui.handleAction(&term, .ai_accept));
}

test "controller: ghost text is drawn dim after the cursor" {
    var term = try Terminal.initBuffer(t.allocator, 3, 20, 16);
    defer term.deinit();
    var ui = Ui.init(t.allocator, .{});
    defer ui.deinit();
    try term.processOutput("$ git st");
    const list = try t.allocator.alloc([]u8, 1);
    list[0] = try t.allocator.dupe(u8, "atus --short and more");
    try ui.setSuggestions(&term, list);
    var cells = std.ArrayList(terminal.Cell).init(t.allocator);
    defer cells.deinit();
    var marks = std.ArrayList(@import("../renderer/frame.zig").Mark).init(t.allocator);
    defer marks.deinit();
    _ = try ui.compose(&term, &cells, &marks);
    try t.expectEqual(@as(u21, 'a'), cells.items[8].char);
    try t.expectEqual(@import("../terminal/color.zig").indexed(8), cells.items[8].fg_color);
    // Clipped at the row end; the terminal grid itself is untouched.
    try t.expectEqual(@as(u21, 't'), cells.items[19].char);
    try t.expectEqual(@as(u21, ' '), cells.items[20].char);
    try t.expectEqual(@as(u21, ' '), term.screenRow(0)[8].char);
}

fn hasAiNotice(ui: *Ui) bool {
    const n = ui.notice orelse return false;
    if (n.kind != .ai or n.lines.items.len < 2) return false;
    return std.mem.indexOf(u8, n.lines.items[1], "thinking") == null and
        std.mem.indexOf(u8, n.lines.items[n.lines.items.len - 1], "\u{2026}") == null;
}

test "controller: explain last error shows the answer in an overlay" {
    const replies = [_]mock.Reply{.{ .chunks = mock.sse(&.{ "Typo in the subcommand.\\n", "$ git commit -m wip" }) }};
    const srv = try mock.MockServer.start(t.allocator, &replies);
    defer srv.deinit();
    var url_buf: [64]u8 = undefined;
    var term = try Terminal.initBuffer(t.allocator, 20, 70, 16);
    defer term.deinit();
    var ui = Ui.init(t.allocator, .{});
    defer ui.deinit();
    var c = Controller.init(t.allocator, .{ .endpoint = srv.url(&url_buf), .model = "m" });
    defer c.deinit();
    try term.processOutput("\x1b]133;A\x07$ \x1b]133;B\x07git comit -m wip\r\n\x1b]133;C\x07git: 'comit' is not a git command.\r\n\x1b]133;D;1\x07\x1b]133;A\x07$ \x1b]133;B\x07");
    try c.explain(&ui, &term, 0);
    try t.expectEqualStrings("AI: why did `git comit -m wip` fail (exit 1)?", ui.notice.?.lines.items[0]);
    try waitFor(&c, &ui, &term, hasAiNotice);
    try t.expectEqualStrings("  Typo in the subcommand.", ui.notice.?.lines.items[1]);
    try t.expectEqualStrings("  $ git commit -m wip", ui.notice.?.lines.items[2]);
    try t.expect(std.mem.indexOf(u8, srv.requests.items[0], "'comit' is not a git command") != null);
    // Esc closes it.
    try t.expect(try ui.handleKey(&term, .escape, .{}));
    try t.expect(ui.notice == null);
}

fn offlineTag(ui: *Ui) bool {
    return ui.ai_status != null;
}

test "controller: an unreachable endpoint only shows the status tag" {
    const srv = try mock.MockServer.start(t.allocator, &.{});
    var url_buf: [64]u8 = undefined;
    const url = try t.allocator.dupe(u8, srv.url(&url_buf));
    defer t.allocator.free(url);
    srv.deinit();
    var term = try Terminal.initBuffer(t.allocator, 5, 40, 16);
    defer term.deinit();
    var ui = Ui.init(t.allocator, .{});
    defer ui.deinit();
    var c = Controller.init(t.allocator, .{ .endpoint = url, .model = "m", .debounce_ms = 0 });
    defer c.deinit();
    try term.processOutput("$ make te");
    c.onKeystroke(&ui, 0);
    c.tick(&term, 0);
    try waitFor(&c, &ui, &term, offlineTag);
    try t.expectEqualStrings("AI offline", ui.ai_status.?);
    try t.expect(ui.ghost == null);
    try t.expect(ui.notice == null);
    // Disabling AI on reload clears it.
    c.applySettings(&ui, .{ .enabled = false });
    try t.expect(ui.ai_status == null);
    try t.expect(c.engine == null);
}

test "controller: the offline badge sits in a free corner" {
    var term = try Terminal.initBuffer(t.allocator, 4, 30, 16);
    defer term.deinit();
    var ui = Ui.init(t.allocator, .{});
    defer ui.deinit();
    try term.processOutput("$ ls");
    ui.setAiStatus("AI offline");
    var cells = std.ArrayList(terminal.Cell).init(t.allocator);
    defer cells.deinit();
    var marks = std.ArrayList(@import("../renderer/frame.zig").Mark).init(t.allocator);
    defer marks.deinit();
    _ = try ui.compose(&term, &cells, &marks);
    // Bottom row, right-aligned: " AI offline " in columns 18..29.
    try t.expectEqual(@as(u21, 'A'), cells.items[3 * 30 + 19].char);
    try t.expectEqual(@as(u32, 0x3A3A3A), cells.items[3 * 30 + 18].bg_color);
    // The bottom row in use: top-right instead.
    try term.processOutput("\r\n\r\n\r\n$ ");
    _ = try ui.compose(&term, &cells, &marks);
    try t.expectEqual(@as(u21, 'A'), cells.items[19].char);
    // Never on the alternate screen.
    try term.processOutput("\x1b[?1049h");
    _ = try ui.compose(&term, &cells, &marks);
    try t.expect(cells.items[19].char != 'A');
}
