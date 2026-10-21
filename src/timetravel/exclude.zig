//! Gitignore-like path filters for Time Travel snapshots.
//!
//! A pattern with no slash matches a single path component (`node_modules`
//! skips that directory anywhere). A pattern with a slash is anchored at
//! the working tree (` .git/objects` skips that subtree only). `*` and `?`
//! do not cross `/`. A trailing slash matches directories only. `!`
//! negates. Later rules win, so a root `.gitignore` can put back something
//! the defaults skipped.

const std = @import("std");

pub const default_patterns = [_][]const u8{
    "node_modules",
    ".git/objects",
    "zig-cache",
    ".zig-cache",
    "zig-out",
    "target",
    "__pycache__",
    ".venv",
    "venv",
    "dist",
};

pub const Rule = struct {
    negated: bool = false,
    dir_only: bool = false,
    /// Pattern text with the `!` prefix, trailing slash, and a single
    /// leading slash removed. Slashes inside are `/`.
    text: []const u8,
    anchored: bool = false,
};

pub fn parsePattern(line: []const u8) ?Rule {
    var s = std.mem.trim(u8, line, " \t\r");
    if (s.len == 0 or s[0] == '#') return null;
    var negated = false;
    if (s[0] == '!') {
        negated = true;
        s = s[1..];
        if (s.len == 0) return null;
    }
    var dir_only = false;
    if (s.len > 1 and s[s.len - 1] == '/') {
        dir_only = true;
        s = s[0 .. s.len - 1];
    }
    var anchored = false;
    if (s.len > 0 and s[0] == '/') {
        anchored = true;
        s = s[1..];
    }
    if (std.mem.indexOfScalar(u8, s, '/') != null) anchored = true;
    if (s.len == 0) return null;
    return .{ .negated = negated, .dir_only = dir_only, .text = s, .anchored = anchored };
}

/// Parse a `.gitignore`-style document. `out` holds rules whose `text`
/// points into `source` (keep `source` alive).
pub fn parseFile(source: []const u8, out: *std.ArrayList(Rule)) !void {
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        if (parsePattern(line)) |r| try out.append(r);
    }
}

pub fn matches(rule: Rule, rel: []const u8, is_dir: bool) bool {
    if (rule.dir_only and !is_dir) return false;
    if (rule.anchored) {
        if (glob(rule.text, rel)) return true;
        // `dir/sub` also covers everything under it. Globs stay exact:
        // `src/*.o` must not swallow `src/foo.o/extra`.
        if (std.mem.indexOfAny(u8, rule.text, "*?") == null and
            rel.len > rule.text.len and
            std.mem.startsWith(u8, rel, rule.text) and
            rel[rule.text.len] == '/')
            return true;
        return false;
    }
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) continue;
        if (glob(rule.text, comp)) return true;
    }
    return false;
}

/// Last matching rule wins. No match means keep the path.
pub fn excluded(rules: []const Rule, rel: []const u8, is_dir: bool) bool {
    var skip = false;
    for (rules) |r| {
        if (matches(r, rel, is_dir)) skip = !r.negated;
    }
    return skip;
}

/// `*` / `?` against `text`. `*` does not match `/`.
fn glob(pat: []const u8, text: []const u8) bool {
    return globRec(pat, text);
}

fn globRec(pat: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    while (p < pat.len) {
        if (pat[p] == '*') {
            p += 1;
            if (p == pat.len) {
                return std.mem.indexOfScalar(u8, text[t..], '/') == null;
            }
            while (t <= text.len) : (t += 1) {
                if (t < text.len and text[t] == '/') break;
                if (globRec(pat[p..], text[t..])) return true;
                if (t == text.len) break;
            }
            return false;
        }
        if (t >= text.len) return false;
        if (pat[p] == '?') {
            if (text[t] == '/') return false;
            p += 1;
            t += 1;
            continue;
        }
        if (pat[p] != text[t]) return false;
        p += 1;
        t += 1;
    }
    return t == text.len;
}

test "default excludes skip node_modules and git objects, not the rest of .git" {
    var rules = std.ArrayList(Rule).init(std.testing.allocator);
    defer rules.deinit();
    for (default_patterns) |p| rules.append(parsePattern(p).?) catch unreachable;
    try std.testing.expect(excluded(rules.items, "node_modules", true));
    try std.testing.expect(excluded(rules.items, "pkg/node_modules", true));
    try std.testing.expect(excluded(rules.items, "pkg/node_modules/left-pad/index.js", false));
    try std.testing.expect(excluded(rules.items, ".git/objects", true));
    try std.testing.expect(excluded(rules.items, ".git/objects/ab/cd", false));
    try std.testing.expect(!excluded(rules.items, ".git", true));
    try std.testing.expect(!excluded(rules.items, ".git/HEAD", false));
    try std.testing.expect(!excluded(rules.items, "src/main.zig", false));
    try std.testing.expect(excluded(rules.items, "zig-out", true));
    try std.testing.expect(excluded(rules.items, "src/zig-out", true));
}

test "gitignore negation and globs" {
    const src = "# comment\n*.o\n!keep.o\nbuild/\n";
    var rules = std.ArrayList(Rule).init(std.testing.allocator);
    defer rules.deinit();
    try parseFile(src, &rules);
    try std.testing.expect(excluded(rules.items, "foo.o", false));
    try std.testing.expect(!excluded(rules.items, "keep.o", false));
    try std.testing.expect(excluded(rules.items, "build", true));
    try std.testing.expect(!excluded(rules.items, "build", false));
    try std.testing.expect(!excluded(rules.items, "foo.c", false));
}
