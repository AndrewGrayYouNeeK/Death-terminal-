//! Strips secrets from text before it leaves the machine for an AI
//! endpoint. Errs on the side of redacting: a lost suggestion is cheap, a
//! leaked token is not.
//!
//! Covered: PEM private keys; well-known token formats (OpenAI/Anthropic
//! `sk-`, GitHub `ghp_`/`github_pat_`..., AWS `AKIA`/`ASIA`, Slack `xox?-`,
//! Google `AIza`, GitLab `glpat-`, Hugging Face `hf_`, JWTs); Bearer/Basic
//! credentials; passwords in URLs; `key=value` / `key: value` / `--flag
//! value` where the key looks secret (password, token, secret, api key...);
//! every environment-style `NAME=value` assignment except a small allowlist
//! of harmless names; `sshpass -p`, `mysql -pSECRET`; and long random-looking
//! strings (mixed case + digits).

const std = @import("std");

pub const mask = "[REDACTED]";

pub fn redact(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(text.len);
    var i: usize = 0;
    // Set after `--password` style flags: redact the next word.
    var redact_next_word = false;
    while (i < text.len) {
        const at_word = i == 0 or !isWordChar(text[i - 1]);
        if (redact_next_word and !isSpace(text[i])) {
            redact_next_word = false;
            const end = wordEnd(text, i);
            if (end > i) {
                try out.appendSlice(mask);
                i = end;
                continue;
            }
        }
        if (std.mem.startsWith(u8, text[i..], "-----BEGIN ")) {
            if (pemBlock(text, i)) |end| {
                try out.appendSlice("[REDACTED PRIVATE KEY]");
                i = end;
                continue;
            }
        }
        if (at_word) {
            if (knownToken(text, i)) |end| {
                try out.appendSlice(mask);
                i = end;
                continue;
            }
            if (authScheme(text, i)) |r| {
                try out.appendSlice(text[i..r.value_start]);
                try out.appendSlice(mask);
                i = r.end;
                continue;
            }
            if (assignment(text, i)) |r| {
                try out.appendSlice(text[i..r.value_start]);
                try out.appendSlice(mask);
                i = r.end;
                continue;
            }
            if (secretFlag(text, i)) |end| {
                try out.appendSlice(text[i..end]);
                i = end;
                redact_next_word = true;
                continue;
            }
            if (passwordOption(text, i)) |r| {
                try out.appendSlice(text[i..r.value_start]);
                try out.appendSlice(mask);
                i = r.end;
                continue;
            }
            if (randomLooking(text, i)) |end| {
                try out.appendSlice(mask);
                i = end;
                continue;
            }
        }
        if (std.mem.startsWith(u8, text[i..], "://")) {
            if (urlPassword(text, i + 3)) |r| {
                try out.appendSlice(text[i..r.value_start]);
                try out.appendSlice(mask);
                i = r.end;
                continue;
            }
        }
        if (redact_next_word and text[i] == '\n') redact_next_word = false;
        try out.append(text[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

const Span = struct { value_start: usize, end: usize };

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// End of a shell-ish word starting at `i` (a quoted string counts as one).
fn wordEnd(text: []const u8, i: usize) usize {
    if (i < text.len and (text[i] == '"' or text[i] == '\'')) {
        const q = text[i];
        var j = i + 1;
        while (j < text.len and text[j] != q and text[j] != '\n') j += 1;
        return if (j < text.len and text[j] == q) j + 1 else j;
    }
    var j = i;
    while (j < text.len and !isSpace(text[j]) and text[j] != ';' and text[j] != '&' and text[j] != '|' and text[j] != ',' and text[j] != '}' and text[j] != ')') j += 1;
    return j;
}

fn runOf(text: []const u8, i: usize, comptime pred: fn (u8) bool) usize {
    var j = i;
    while (j < text.len and pred(text[j])) j += 1;
    return j;
}

fn pemBlock(text: []const u8, i: usize) ?usize {
    const line_end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
    if (std.mem.indexOf(u8, text[i..line_end], "PRIVATE KEY") == null) return null;
    const end_marker = std.mem.indexOfPos(u8, text, line_end, "-----END ") orelse return text.len;
    const close = std.mem.indexOfPos(u8, text, end_marker + 9, "-----") orelse return text.len;
    return close + 5;
}

const Prefix = struct { p: []const u8, min: usize, charset: enum { token, upper_digit } = .token, exact: usize = 0 };
const prefixes = [_]Prefix{
    .{ .p = "sk-", .min = 20 }, // OpenAI, Anthropic (sk-ant-), sk-proj-
    .{ .p = "ghp_", .min = 30 },
    .{ .p = "gho_", .min = 30 },
    .{ .p = "ghu_", .min = 30 },
    .{ .p = "ghs_", .min = 30 },
    .{ .p = "ghr_", .min = 30 },
    .{ .p = "github_pat_", .min = 20 },
    .{ .p = "glpat-", .min = 20 },
    .{ .p = "AKIA", .min = 16, .charset = .upper_digit, .exact = 16 },
    .{ .p = "ASIA", .min = 16, .charset = .upper_digit, .exact = 16 },
    .{ .p = "xoxb-", .min = 10 },
    .{ .p = "xoxp-", .min = 10 },
    .{ .p = "xoxa-", .min = 10 },
    .{ .p = "xoxr-", .min = 10 },
    .{ .p = "xoxs-", .min = 10 },
    .{ .p = "AIza", .min = 30 },
    .{ .p = "hf_", .min = 30 },
    .{ .p = "npm_", .min = 30 },
};

fn isUpperDigit(c: u8) bool {
    return std.ascii.isUpper(c) or std.ascii.isDigit(c);
}

fn knownToken(text: []const u8, i: usize) ?usize {
    for (prefixes) |pre| {
        if (!std.mem.startsWith(u8, text[i..], pre.p)) continue;
        const s = i + pre.p.len;
        const e = switch (pre.charset) {
            .token => runOf(text, s, isTokenChar),
            .upper_digit => runOf(text, s, isUpperDigit),
        };
        if (e - s < pre.min) continue;
        if (pre.exact != 0 and e - s != pre.exact) continue;
        return e;
    }
    // JWT: three base64url segments.
    if (std.mem.startsWith(u8, text[i..], "eyJ")) {
        var j = i;
        var parts: usize = 0;
        while (parts < 3) : (parts += 1) {
            const e = runOf(text, j, isTokenChar);
            if (e - j < 8) break;
            j = e;
            if (parts < 2) {
                if (j >= text.len or text[j] != '.') break;
                j += 1;
            }
        }
        if (parts == 3) return j;
    }
    return null;
}

/// "Bearer xxx" / "Basic xxx" / "token xxx" in Authorization headers.
fn authScheme(text: []const u8, i: usize) ?Span {
    const schemes = [_][]const u8{ "bearer ", "basic ", "token " };
    for (schemes) |sch| {
        if (text.len - i < sch.len or !std.ascii.eqlIgnoreCase(text[i..][0..sch.len], sch)) continue;
        if (std.mem.eql(u8, sch, "token ")) {
            // Only in "Authorization: token xxx".
            const before = text[0..i];
            if (std.ascii.indexOfIgnoreCase(before[before.len -| 20..], "authorization") == null) continue;
        }
        const s = i + sch.len;
        const e = runOf(text, s, struct {
            fn f(c: u8) bool {
                return isTokenChar(c) or c == '.' or c == '/' or c == '+' or c == '=' or c == '~';
            }
        }.f);
        if (e - s >= 8) return .{ .value_start = s, .end = e };
    }
    return null;
}

const secret_words = [_][]const u8{
    "password",  "passwd",      "passphrase",    "secret",      "token",       "apikey",     "api_key",    "api-key",
    "accesskey", "access_key",  "access-key",    "private_key", "private-key", "privatekey", "credential", "authorization",
    "auth_key",  "session_key", "client_secret", "signing_key",
};

/// Key names whose value should never be sent.
fn secretKey(key_in: []const u8) bool {
    var buf: [64]u8 = undefined;
    if (key_in.len == 0 or key_in.len > buf.len) return false;
    const key = std.ascii.lowerString(&buf, key_in);
    for (secret_words) |w| if (std.mem.indexOf(u8, key, w) != null) return true;
    const exact = [_][]const u8{ "pass", "pw", "pwd_hash", "key", "auth" };
    for (exact) |w| if (std.mem.eql(u8, key, w)) return true;
    return std.mem.endsWith(u8, key, "_key") or std.mem.endsWith(u8, key, "-key") or std.mem.endsWith(u8, key, "_pass") or std.mem.endsWith(u8, key, "_pw");
}

/// Environment names whose values are harmless and useful as context.
const env_allow = [_][]const u8{
    "PATH",             "HOME",            "PWD",       "OLDPWD",    "TERM",      "SHELL",           "LANG",          "LANGUAGE",
    "LC_ALL",           "LC_CTYPE",        "USER",      "LOGNAME",   "EDITOR",    "VISUAL",          "PAGER",         "TZ",
    "DISPLAY",          "CC",              "CXX",       "CFLAGS",    "LDFLAGS",   "CPPFLAGS",        "GOOS",          "GOARCH",
    "NODE_ENV",         "DEBUG",           "VERBOSE",   "PORT",      "HOST",      "HOSTNAME",        "MAKEFLAGS",     "RUST_LOG",
    "RUST_BACKTRACE",   "PYTHONPATH",      "GOPATH",    "JAVA_HOME", "COLORTERM", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR",
    "XDG_SESSION_TYPE", "WAYLAND_DISPLAY", "LS_COLORS", "PS1",       "HISTSIZE",  "HISTFILESIZE",    "GIT_PAGER",     "LESS",
    "MANPAGER",         "TMUX",            "SHLVL",     "CI",
};

fn envLooking(key: []const u8) bool {
    if (key.len < 2) return false;
    if (!std.ascii.isUpper(key[0]) and key[0] != '_') return false;
    for (key) |c| if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_')) return false;
    for (env_allow) |a| if (std.mem.eql(u8, key, a)) return false;
    return true;
}

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

/// `KEY=value`, `--key=value`, `"key": "value"`, `key: value`.
fn assignment(text: []const u8, i: usize) ?Span {
    var j = i;
    var quoted_key = false;
    if (j < text.len and (text[j] == '"' or text[j] == '\'')) {
        quoted_key = true;
        j += 1;
    }
    while (j < text.len and text[j] == '-') j += 1;
    const ks = j;
    j = runOf(text, j, isKeyChar);
    if (j == ks) return null;
    const key = text[ks..j];
    if (quoted_key) {
        if (j >= text.len or (text[j] != '"' and text[j] != '\'')) return null;
        j += 1;
    }
    if (j >= text.len) return null;
    const sep = text[j];
    if (sep != '=' and sep != ':') return null;
    const secret = secretKey(key);
    // Env-style: NAME=value only (not "NAME: value", which is prose/YAML).
    const env = sep == '=' and !quoted_key and ks == i and envLooking(key);
    if (!secret and !env) return null;
    j += 1;
    if (sep == ':') {
        if (j < text.len and text[j] == '/') return null; // URL scheme "http://"
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
    }
    if (j >= text.len or isSpace(text[j])) return null;
    // "Authorization: Bearer xxx": keep the scheme, hide the credential.
    if (authScheme(text, j)) |r| return r;
    const e = wordEnd(text, j);
    if (e == j) return null;
    return .{ .value_start = j, .end = e };
}

/// `--password value`, `--api-key value`, `sshpass -p value`.
fn secretFlag(text: []const u8, i: usize) ?usize {
    if (std.mem.startsWith(u8, text[i..], "--")) {
        const e = runOf(text, i + 2, isKeyChar);
        if (e < text.len and text[e] == ' ' and secretKey(text[i + 2 .. e])) return e;
        return null;
    }
    if (std.mem.startsWith(u8, text[i..], "sshpass -p ")) return i + "sshpass -p".len;
    return null;
}

/// mysql/mariadb `-pSECRET`.
fn passwordOption(text: []const u8, i: usize) ?Span {
    if (!std.mem.startsWith(u8, text[i..], "-p") or i == 0 or text[i - 1] != ' ') return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..i], '\n')) |n| n + 1 else 0;
    const line = text[line_start..i];
    if (std.mem.indexOf(u8, line, "mysql") == null and std.mem.indexOf(u8, line, "mariadb") == null) return null;
    const s = i + 2;
    const e = wordEnd(text, s);
    if (e == s) return null;
    return .{ .value_start = s, .end = e };
}

/// user:password@ after "scheme://".
fn urlPassword(text: []const u8, s: usize) ?Span {
    var j = s;
    while (j < text.len and !isSpace(text[j]) and text[j] != '/' and text[j] != '@' and text[j] != ':') j += 1;
    if (j >= text.len or text[j] != ':') return null;
    const ps = j + 1;
    var k = ps;
    while (k < text.len and !isSpace(text[k]) and text[k] != '/' and text[k] != '@') k += 1;
    if (k >= text.len or text[k] != '@' or k == ps) return null;
    return .{ .value_start = ps, .end = k };
}

/// 32+ characters mixing upper, lower and digits: looks like a key.
fn randomLooking(text: []const u8, i: usize) ?usize {
    const e = runOf(text, i, struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=' or c == '_' or c == '-';
        }
    }.f);
    if (e - i < 32) return null;
    var up = false;
    var lo = false;
    var dig = false;
    var transitions: usize = 0;
    var prev: u8 = 0;
    for (text[i..e]) |c| {
        const cls: u8 = if (std.ascii.isUpper(c)) 1 else if (std.ascii.isLower(c)) 2 else if (std.ascii.isDigit(c)) 3 else 4;
        up = up or cls == 1;
        lo = lo or cls == 2;
        dig = dig or cls == 3;
        if (cls != prev) transitions += 1;
        prev = cls;
    }
    // Paths and identifiers have long runs; keys flip classes constantly.
    if (up and lo and dig and transitions * 3 >= (e - i)) return e;
    return null;
}

/// Whether `s` as a whole looks like a credential (used to reject an API
/// key pasted where an environment variable name belongs).
pub fn looksLikeKey(s: []const u8) bool {
    if (s.len == 0) return false;
    if (knownToken(s, 0)) |e| if (e == s.len) return true;
    if (randomLooking(s, 0)) |e| if (e == s.len) return true;
    // Names are short upper-snake words; anything with lower case and
    // digits mixed in at length is almost certainly a key.
    return s.len >= 20 and std.mem.indexOfAny(u8, s, "abcdefghijklmnopqrstuvwxyz") != null and
        std.mem.indexOfAny(u8, s, "0123456789") != null;
}

// ------------------------------------------------------------------ tests

test "looksLikeKey" {
    try std.testing.expect(looksLikeKey("sk" ++ "-proj-abcdefghijklmnopqrstuvwxyz012345"));
    try std.testing.expect(looksLikeKey("gh" ++ "p_0123456789abcdefghijklmnopqrstuvwxyzAB"));
    try std.testing.expect(!looksLikeKey("OPENAI_API_KEY"));
    try std.testing.expect(!looksLikeKey("GROQ_KEY_2"));
}

fn expectRedacted(input: []const u8, want: []const u8) !void {
    const got = try redact(std.testing.allocator, input);
    defer std.testing.allocator.free(got);
    std.testing.expectEqualStrings(want, got) catch |err| {
        std.debug.print("input: {s}\n", .{input});
        return err;
    };
}

// Fake tokens are split with ++ so secret scanners do not flag this file.
test "redact: provider token formats" {
    try expectRedacted("export OPENAI=sk" ++ "-proj-abcdefghijklmnopqrstuvwxyz123456", "export OPENAI=[REDACTED]");
    try expectRedacted("curl -H x sk" ++ "-ant-api03-abcdefghijklmnopqrstuv", "curl -H x [REDACTED]");
    try expectRedacted("git clone https://gh" ++ "p_abcdefghijklmnopqrstuvwxyz0123456789@github.com/a/b", "git clone https://[REDACTED]@github.com/a/b");
    try expectRedacted("token github" ++ "_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz", "token [REDACTED]");
    try expectRedacted("aws key AK" ++ "IAIOSFODNN7EXAMPLE here", "aws key [REDACTED] here");
    try expectRedacted("AS" ++ "IAABCDEFGHIJKLMNOP", "[REDACTED]");
    try expectRedacted("slack xo" ++ "xb-123456789012-abcdefghij", "slack [REDACTED]");
    try expectRedacted("key=AI" ++ "zaSyA1234567890abcdefghijklmnopqrstu", "key=[REDACTED]");
    try expectRedacted("gl" ++ "pat-abcdefghijklmnopqrst", "[REDACTED]");
    try expectRedacted("h" ++ "f_abcdefghijklmnopqrstuvwxyzABCDEFGH", "[REDACTED]");
    try expectRedacted("jwt ey" ++ "JhbGciOiJIUzI1NiJ9.ey" ++ "JzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U ok", "jwt [REDACTED] ok");
}

test "redact: headers, URLs and key/value forms" {
    try expectRedacted("curl -H 'Authorization: Bearer abcdef123456789' x", "curl -H 'Authorization: Bearer [REDACTED]' x");
    try expectRedacted("Authorization: Basic dXNlcjpwYXNz", "Authorization: Basic [REDACTED]");
    try expectRedacted("psql postgres://admin:hunter2@db:5432/x", "psql postgres://admin:[REDACTED]@db:5432/x");
    try expectRedacted("mytool --password=hunter2 --user bob", "mytool --password=[REDACTED] --user bob");
    try expectRedacted("mytool --password hunter2 --user bob", "mytool --password [REDACTED] --user bob");
    try expectRedacted("cli --api-key abc123 run", "cli --api-key [REDACTED] run");
    try expectRedacted("{\"password\": \"s3cret!\", \"user\": \"bob\"}", "{\"password\": [REDACTED], \"user\": \"bob\"}");
    try expectRedacted("db_password: correct horse", "db_password: [REDACTED] horse");
    try expectRedacted("client_secret=xyz", "client_secret=[REDACTED]");
    try expectRedacted("sshpass -p 'hunter 2' ssh host", "sshpass -p [REDACTED] ssh host");
    try expectRedacted("mysql -u root -phunter2 db", "mysql -u root -p[REDACTED] db");
}

test "redact: environment assignments" {
    try expectRedacted("export DATABASE_URL=postgres://x", "export DATABASE_URL=[REDACTED]");
    try expectRedacted("MY_VAR=\"some value\" make", "MY_VAR=[REDACTED] make");
    try expectRedacted("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "AWS_SECRET_ACCESS_KEY=[REDACTED]");
    try expectRedacted("FOO=1 BAR=2 cmd", "FOO=[REDACTED] BAR=[REDACTED] cmd");
    // Harmless names are kept: they are useful context.
    try expectRedacted("PATH=/usr/bin:/bin EDITOR=vim make CC=clang", "PATH=/usr/bin:/bin EDITOR=vim make CC=clang");
    try expectRedacted("lowercase=fine", "lowercase=fine");
}

test "redact: private keys and random-looking strings" {
    try expectRedacted("a\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----\nz", "a\n[REDACTED PRIVATE KEY]\nz");
    try expectRedacted("-----BEGIN CERTIFICATE-----", "-----BEGIN CERTIFICATE-----");
    try expectRedacted("id Xk9mQ2pL7vR4tN8wZ3bC6yF1hJ5sD0aE ok", "id [REDACTED] ok");
}

test "redact: ordinary commands and output survive" {
    const keep = [_][]const u8{
        "git commit -m 'fix the parser' --author=bob",
        "git checkout 3f9a2c1d8e7b6a5f4e3d2c1b0a9f8e7d6c5b4a3f",
        "ls -la /usr/local/lib/python3.12/site-packages",
        "mkdir -p build && cd build && cmake ..",
        "docker run -p 8080:80 nginx",
        "make: *** [Makefile:12: all] Error 2",
        "error: cannot find module 'ReactDOMServerIntegrationTests'",
        "ssh -i ~/.ssh/id_ed25519 user@host",
        "https://github.com/AndrewGrayYouNeeK/Death-terminal-",
        "keyboard: us",
        "Password:",
        "echo $TERM",
    };
    for (keep) |k| try expectRedacted(k, k);
}
