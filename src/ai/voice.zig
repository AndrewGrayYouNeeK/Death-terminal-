//! Read AI answers aloud with an ElevenLabs voice. Ghost-text completions
//! never come through here. The API key is read from ELEVENLABS_API_KEY at
//! request time and is not stored, logged, or written into the URL or body.
//!
//! Tests pass a fake HTTP function. Nothing in this file dials ElevenLabs
//! unless `fetchMpeg` is called, and the unit tests do not call it.

const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("../platform/env.zig");
const redact = @import("redact.zig");

pub const default_voice_id = "QMnwdN2oOwNXPcl9oXIl";
pub const default_model = "eleven_flash_v2_5";
pub const output_format = "mp3_44100_128";
pub const max_spoken: usize = 1200;
const key_env = "ELEVENLABS_API_KEY";

pub const Request = struct {
    url: []u8,
    body: []u8,

    pub fn deinit(self: Request, a: std.mem.Allocator) void {
        a.free(self.url);
        a.free(self.body);
    }
};

pub const Fetch = *const fn (ctx: *anyopaque, a: std.mem.Allocator, url: []const u8, api_key: []const u8, body: []const u8) anyerror![]u8;

/// Strip ANSI, drop fenced code, drop backtick marks, redact secrets,
/// collapse whitespace, and cap the length. Empty means "do not speak".
pub fn prepareSpeech(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const plain = try stripAnsi(a, text);
    defer a.free(plain);
    const unfenced = try stripFences(a, plain);
    defer a.free(unfenced);
    const bare = try stripBackticks(a, unfenced);
    defer a.free(bare);
    const hidden = try redact.redact(a, bare);
    defer a.free(hidden);
    const flat = try squash(a, hidden);
    defer a.free(flat);
    return cap(a, flat);
}

pub fn buildRequest(a: std.mem.Allocator, voice_id: []const u8, model: []const u8, text: []const u8) !Request {
    if (!validId(voice_id) or !validModel(model)) return error.BadVoice;
    const url = try std.fmt.allocPrint(a, "https://api.elevenlabs.io/v1/text-to-speech/{s}?output_format={s}", .{ voice_id, output_format });
    errdefer a.free(url);
    var body_list = std.ArrayList(u8).init(a);
    errdefer body_list.deinit();
    try std.json.stringify(.{ .text = text, .model_id = model }, .{}, body_list.writer());
    return .{ .url = url, .body = try body_list.toOwnedSlice() };
}

/// Prepare `raw`, build the POST, and hand it to `fetch`. The key is an
/// argument of `fetch` only. Tests pass a fake `fetch` and never touch the network.
pub fn perform(a: std.mem.Allocator, voice_id: []const u8, model: []const u8, raw: []const u8, api_key: []const u8, ctx: *anyopaque, fetch: Fetch) ![]u8 {
    const spoken = try prepareSpeech(a, raw);
    defer a.free(spoken);
    if (spoken.len == 0) return error.Empty;
    const req = try buildRequest(a, voice_id, model, spoken);
    defer req.deinit(a);
    return fetch(ctx, a, req.url, api_key, req.body);
}

pub fn fetchMpeg(ctx: *anyopaque, a: std.mem.Allocator, url: []const u8, api_key: []const u8, body: []const u8) ![]u8 {
    _ = ctx;
    if (api_key.len == 0) return error.NoKey;
    const uri = std.Uri.parse(url) catch return error.BadUrl;
    var client = std.http.Client{ .allocator = a };
    defer client.deinit();
    var header_buf: [16 * 1024]u8 = undefined;
    var req = client.open(.POST, uri, .{
        .server_header_buffer = &header_buf,
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "DeathTerminal" },
            .accept_encoding = .omit,
        },
        .extra_headers = &.{
            .{ .name = "xi-api-key", .value = api_key },
            .{ .name = "accept", .value = "audio/mpeg" },
        },
    }) catch return error.Offline;
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    req.send() catch return error.Offline;
    req.writeAll(body) catch return error.Offline;
    req.finish() catch return error.Offline;
    req.wait() catch return error.Offline;
    if (req.response.status != .ok) return error.Offline;
    return req.reader().readAllAlloc(a, 8 * 1024 * 1024) catch return error.Offline;
}

pub const Toggle = enum { muted, unmuted, disabled };

pub const Speaker = struct {
    a: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    quit: bool = false,
    enabled: bool,
    muted: bool = false,
    voice_id: []u8,
    model: []u8,
    hinted: bool = false,
    hint_kind: u8 = 0,
    gen: u64 = 0,
    pending: ?[]u8 = null,
    /// Set while a player is running so `stop` can end it without blocking.
    /// POSIX: pid. Windows: process HANDLE bits.
    player_bits: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn create(a: std.mem.Allocator, enabled: bool, voice_id: []const u8, model: []const u8) !*Speaker {
        const id = try a.dupe(u8, voice_id);
        errdefer a.free(id);
        const model_copy = try a.dupe(u8, model);
        errdefer a.free(model_copy);
        const self = try a.create(Speaker);
        self.* = .{
            .a = a,
            .enabled = enabled,
            .voice_id = id,
            .model = model_copy,
        };
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch null;
        return self;
    }

    pub fn destroy(self: *Speaker) void {
        self.mu.lock();
        self.quit = true;
        self.gen += 1;
        if (self.pending) |old| self.a.free(old);
        self.pending = null;
        self.mu.unlock();
        const bits = self.player_bits.load(.acquire);
        if (bits != 0) killPlayer(bits);
        self.cond.signal();
        if (self.thread) |th| th.join();
        self.a.free(self.voice_id);
        self.a.free(self.model);
        self.a.destroy(self);
    }

    pub fn apply(self: *Speaker, enabled: bool, voice_id: []const u8, model: []const u8) void {
        const id = self.a.dupe(u8, voice_id) catch return;
        const m = self.a.dupe(u8, model) catch {
            self.a.free(id);
            return;
        };
        self.mu.lock();
        self.a.free(self.voice_id);
        self.a.free(self.model);
        self.voice_id = id;
        self.model = m;
        const was = self.enabled;
        self.enabled = enabled;
        self.mu.unlock();
        if (was and !enabled) self.stop();
    }

    /// Queue `text`. A newer call or `stop` drops anything still in flight.
    pub fn speak(self: *Speaker, text: []const u8) void {
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
        self.mu.lock();
        const on = self.enabled and !self.muted and self.thread != null;
        self.mu.unlock();
        if (!on) return;
        const key = env_mod.get(key_env) orelse {
            self.hintOnce(1);
            return;
        };
        if (key.len == 0) {
            self.hintOnce(1);
            return;
        }
        const copy = self.a.dupe(u8, text) catch return;
        self.mu.lock();
        if (self.pending) |old| self.a.free(old);
        self.gen += 1;
        self.pending = copy;
        self.mu.unlock();
        self.cond.signal();
    }

    pub fn stop(self: *Speaker) void {
        self.mu.lock();
        self.gen += 1;
        if (self.pending) |old| self.a.free(old);
        self.pending = null;
        self.mu.unlock();
        self.cond.signal();
        const bits = self.player_bits.load(.acquire);
        if (bits != 0) killPlayer(bits);
    }

    pub fn toggle(self: *Speaker) Toggle {
        self.mu.lock();
        if (!self.enabled) {
            self.mu.unlock();
            return .disabled;
        }
        self.muted = !self.muted;
        const muted = self.muted;
        self.mu.unlock();
        if (muted) self.stop();
        return if (muted) .muted else .unmuted;
    }

    /// One hint per window. The GUI shows it and this returns null afterwards.
    pub fn takeHint(self: *Speaker) ?[]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const kind = self.hint_kind;
        self.hint_kind = 0;
        return switch (kind) {
            1 => "Voice needs ELEVENLABS_API_KEY",
            2 => "Voice is offline",
            else => null,
        };
    }

    fn hintOnce(self: *Speaker, kind: u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.hinted) return;
        self.hinted = true;
        self.hint_kind = kind;
    }

    fn generation(self: *Speaker) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.gen;
    }

    fn snapshot(self: *Speaker) struct { id: []u8, model: []u8 } {
        self.mu.lock();
        defer self.mu.unlock();
        return .{
            .id = self.a.dupe(u8, self.voice_id) catch self.a.dupe(u8, default_voice_id) catch unreachable,
            .model = self.a.dupe(u8, self.model) catch self.a.dupe(u8, default_model) catch unreachable,
        };
    }
};

const Job = struct { gen: u64, text: []u8 };

fn worker(self: *Speaker) void {
    while (true) {
        const job = take(self) orelse return;
        defer self.a.free(job.text);
        if (job.gen != self.generation()) continue;
        const spoken = prepareSpeech(self.a, job.text) catch continue;
        defer self.a.free(spoken);
        if (spoken.len == 0 or job.gen != self.generation()) continue;
        const key_slice = env_mod.get(key_env) orelse {
            self.hintOnce(1);
            continue;
        };
        if (key_slice.len == 0) {
            self.hintOnce(1);
            continue;
        }
        const key = self.a.dupe(u8, key_slice) catch continue;
        defer self.a.free(key);
        const ids = self.snapshot();
        defer self.a.free(ids.id);
        defer self.a.free(ids.model);
        var dummy: u8 = 0;
        const audio = perform(self.a, ids.id, ids.model, spoken, key, &dummy, fetchMpeg) catch {
            self.hintOnce(2);
            continue;
        };
        defer self.a.free(audio);
        if (job.gen != self.generation() or audio.len == 0) continue;
        play(self, job.gen, audio) catch {};
    }
}

fn take(self: *Speaker) ?Job {
    self.mu.lock();
    defer self.mu.unlock();
    while (self.pending == null and !self.quit) self.cond.wait(&self.mu);
    if (self.quit and self.pending == null) return null;
    const text = self.pending orelse return null;
    self.pending = null;
    return .{ .gen = self.gen, .text = text };
}

fn play(self: *Speaker, gen: u64, audio: []const u8) !void {
    const path = try tempPath(self.a, gen);
    defer self.a.free(path);
    {
        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(audio);
    }
    defer std.fs.deleteFileAbsolute(path) catch {};
    try runPlayers(self, gen, path);
}

fn runPlayers(self: *Speaker, gen: u64, path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const script = windowsScript(self.a, path) catch return;
        defer self.a.free(script);
        const argv = [_][]const u8{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script };
        _ = runOne(self, gen, &argv);
        return;
    }
    const sets: []const []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{&.{ "afplay", path }},
        else => &.{
            &.{ "paplay", path },
            &.{ "ffplay", "-nodisp", "-autoexit", "-loglevel", "error", path },
            &.{ "mpg123", "-q", path },
        },
    };
    for (sets) |argv| {
        if (self.generation() != gen) return;
        if (runOne(self, gen, argv)) return;
    }
}

/// true = this player ran (or we stopped it). false = try the next one.
fn runOne(self: *Speaker, gen: u64, argv: []const []const u8) bool {
    var child = std.process.Child.init(argv, self.a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const started = std.time.milliTimestamp();
    self.player_bits.store(playerBits(child.id), .release);
    const term = child.wait() catch {
        self.player_bits.store(0, .release);
        return false;
    };
    self.player_bits.store(0, .release);
    if (self.generation() != gen) return true;
    switch (term) {
        .Exited => |code| if (code == 0) return true,
        else => {},
    }
    // Died immediately: this player cannot play the file. Try the next.
    return std.time.milliTimestamp() - started >= 400;
}

fn tempPath(a: std.mem.Allocator, gen: u64) ![]u8 {
    if (builtin.os.tag == .windows) {
        const base = env_mod.get("TEMP") orelse env_mod.get("TMP") orelse ".";
        return std.fmt.allocPrint(a, "{s}\\dt-voice-{d}.mp3", .{ base, gen });
    }
    const base = env_mod.get("TMPDIR") orelse "/tmp";
    return std.fmt.allocPrint(a, "{s}/dt-voice-{d}.mp3", .{ base, gen });
}

fn windowsScript(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var uri = std.ArrayList(u8).init(a);
    defer uri.deinit();
    try uri.appendSlice("file:///");
    for (path) |c| {
        if (c == '\\') try uri.append('/') else try uri.append(c);
    }
    return std.fmt.allocPrint(a,
        \\Add-Type -AssemblyName PresentationCore; $p = New-Object System.Windows.Media.MediaPlayer; $p.Open([uri]'{s}'); $p.Volume = 1; $p.Play(); $n = 0; while (-not $p.NaturalDuration.HasTimeSpan -and $n -lt 50) {{ Start-Sleep -Milliseconds 100; $n++ }}; if ($p.NaturalDuration.HasTimeSpan) {{ $end = $p.NaturalDuration.TimeSpan.TotalSeconds; while ($p.Position.TotalSeconds + 0.05 -lt $end) {{ Start-Sleep -Milliseconds 100 }} }}
    , .{uri.items});
}

fn playerBits(id: std.process.Child.Id) usize {
    if (builtin.os.tag == .windows) return @intFromPtr(id);
    return @intCast(id);
}

fn killPlayer(bits: usize) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.TerminateProcess(@ptrFromInt(bits), 1);
        return;
    }
    _ = std.posix.kill(@intCast(bits), std.posix.SIG.TERM) catch {};
}

fn validId(s: []const u8) bool {
    if (s.len < 8 or s.len > 40) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

fn validModel(s: []const u8) bool {
    if (s.len < 3 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn stripAnsi(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len) {
            const next = text[i + 1];
            if (next == '[') {
                i += 2;
                while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == ';' or text[i] == '?')) : (i += 1) {}
                if (i < text.len) i += 1;
                continue;
            }
            if (next == ']') {
                i += 2;
                while (i < text.len and text[i] != 0x07 and !(text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\')) : (i += 1) {}
                if (i < text.len and text[i] == 0x07) i += 1 else if (i + 1 < text.len) i += 2;
                continue;
            }
        }
        if (text[i] != '\r') try out.append(text[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

fn stripFences(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    var i: usize = 0;
    var in_fence = false;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "```")) {
            in_fence = !in_fence;
            i += 3;
            if (!in_fence) {
                if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append('\n');
            } else {
                while (i < text.len and text[i] != '\n') i += 1;
            }
            continue;
        }
        if (!in_fence) try out.append(text[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

fn stripBackticks(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    for (text) |c| if (c != '`') try out.append(c);
    return out.toOwnedSlice();
}

fn squash(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    var space = true;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!space and out.items.len > 0) {
                try out.append(' ');
                space = true;
            }
        } else {
            try out.append(c);
            space = false;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice();
}

fn cap(a: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len <= max_spoken) return a.dupe(u8, text);
    var cut = max_spoken;
    var i = max_spoken;
    while (i > max_spoken / 2) : (i -= 1) {
        if (text[i - 1] == '.' or text[i - 1] == '!' or text[i - 1] == '?') {
            cut = i;
            break;
        }
    }
    return a.dupe(u8, std.mem.trimRight(u8, text[0..cut], " "));
}

const t = std.testing;

test "voice: cleanup strips fences, ANSI, and secrets, and caps length" {
    const token = "sk-" ++ "abcdefghijklmnopqrstuvwxyz0123456789";
    const raw = "\x1b[31mRun `ls` now.\n```sh\nexport TOKEN=supersecretvalue\n```\nthen " ++ token ++ " done.";
    const got = try prepareSpeech(t.allocator, raw);
    defer t.allocator.free(got);
    try t.expect(std.mem.indexOf(u8, got, "ls") != null);
    try t.expect(std.mem.indexOf(u8, got, "```") == null);
    try t.expect(std.mem.indexOf(u8, got, "`") == null);
    try t.expect(std.mem.indexOf(u8, got, "\x1b") == null);
    try t.expect(std.mem.indexOf(u8, got, "supersecretvalue") == null);
    try t.expect(std.mem.indexOf(u8, got, token) == null);
    try t.expect(std.mem.indexOf(u8, got, "[REDACTED]") != null);
    try t.expect(std.mem.startsWith(u8, got, "Run ls now."));

    var long = std.ArrayList(u8).init(t.allocator);
    defer long.deinit();
    try long.appendSlice("Start. ");
    while (long.items.len < max_spoken + 40) try long.appendSlice("word ");
    try long.appendSlice("End.");
    const capped = try prepareSpeech(t.allocator, long.items);
    defer t.allocator.free(capped);
    try t.expect(capped.len <= max_spoken);
    try t.expect(capped.len > max_spoken / 2);
}

test "voice: request builder targets Andrew's voice and leaves the key out" {
    const req = try buildRequest(t.allocator, default_voice_id, default_model, "Hello there.");
    defer req.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, req.url, default_voice_id) != null);
    try t.expect(std.mem.indexOf(u8, req.url, "output_format=mp3_44100_128") != null);
    try t.expect(std.mem.startsWith(u8, req.url, "https://api.elevenlabs.io/v1/text-to-speech/"));
    try t.expect(std.mem.indexOf(u8, req.url, "xi-api-key") == null);
    try t.expect(std.mem.indexOf(u8, req.body, "\"model_id\":\"eleven_flash_v2_5\"") != null or std.mem.indexOf(u8, req.body, "eleven_flash_v2_5") != null);
    try t.expect(std.mem.indexOf(u8, req.body, "Hello there.") != null);
    const fake_key = "test-key-not-real";
    try t.expect(std.mem.indexOf(u8, req.url, fake_key) == null);
    try t.expect(std.mem.indexOf(u8, req.body, fake_key) == null);

    const Mock = struct {
        fn fetch(ctx: *anyopaque, a: std.mem.Allocator, url: []const u8, api_key: []const u8, body: []const u8) ![]u8 {
            _ = ctx;
            if (std.mem.indexOf(u8, url, default_voice_id) == null) return error.BadUrl;
            if (std.mem.indexOf(u8, url, "output_format=mp3_44100_128") == null) return error.BadUrl;
            if (std.mem.indexOf(u8, url, api_key) != null) return error.Leak;
            if (std.mem.indexOf(u8, body, api_key) != null) return error.Leak;
            if (std.mem.indexOf(u8, body, "Hello there.") == null) return error.BadBody;
            if (!std.mem.eql(u8, api_key, "test-key-not-real")) return error.BadKey;
            return a.dupe(u8, "ID3fake");
        }
    };
    var dummy: u8 = 0;
    const audio = try perform(t.allocator, default_voice_id, default_model, "Hello there.", "test-key-not-real", &dummy, Mock.fetch);
    defer t.allocator.free(audio);
    try t.expectEqualStrings("ID3fake", audio);
}
