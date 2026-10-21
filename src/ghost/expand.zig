//! Read-only path expansion for Ghost Run previews.
//!
//! Brace, tilde, `$VAR` and globs are applied in the shell's working
//! directory. Command substitution is never run: a word containing `$(`
//! or a backtick is left as text.

const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("../platform/env.zig");

const match = @import("match.zig");

pub fn expandWord(allocator: std.mem.Allocator, cwd: []const u8, word: []const u8, mode: match.Expand) ![][]u8 {
    if (word.len == 0) return allocator.alloc([]u8, 0);
    if (std.mem.indexOf(u8, word, "$(") != null or std.mem.indexOfScalar(u8, word, '`') != null) {
        const one = try allocator.alloc([]u8, 1);
        one[0] = try allocator.dupe(u8, word);
        return one;
    }
    var braced = std.ArrayList([]u8).init(allocator);
    defer {
        for (braced.items) |s| allocator.free(s);
        braced.deinit();
    }
    if (mode == .all) try braceInto(allocator, word, &braced) else try braced.append(try allocator.dupe(u8, word));

    var out = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit();
    }
    for (braced.items) |part| {
        const tilde = if (mode == .all) try expandTilde(allocator, part) else try allocator.dupe(u8, part);
        defer allocator.free(tilde);
        const envd = if (mode != .none) try expandEnv(allocator, tilde) else try allocator.dupe(u8, tilde);
        defer allocator.free(envd);
        if (mode == .all and hasMeta(envd)) {
            const globbed = try globPaths(allocator, cwd, envd);
            defer allocator.free(globbed);
            for (globbed) |g| try out.append(try allocator.dupe(u8, g));
            for (globbed) |g| allocator.free(g);
        } else try out.append(try allocator.dupe(u8, envd));
    }
    return out.toOwnedSlice();
}

fn hasMeta(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "*?[") != null;
}

fn braceInto(allocator: std.mem.Allocator, word: []const u8, out: *std.ArrayList([]u8)) !void {
    const open = std.mem.indexOfScalar(u8, word, '{') orelse {
        try out.append(try allocator.dupe(u8, word));
        return;
    };
    const close = std.mem.lastIndexOfScalar(u8, word, '}') orelse {
        try out.append(try allocator.dupe(u8, word));
        return;
    };
    if (close < open or std.mem.indexOfScalar(u8, word[open + 1 .. close], ',') == null) {
        try out.append(try allocator.dupe(u8, word));
        return;
    }
    var alts = std.ArrayList([]u8).init(allocator);
    defer {
        for (alts.items) |s| allocator.free(s);
        alts.deinit();
    }
    var start: usize = open + 1;
    var depth: usize = 0;
    var i: usize = open + 1;
    while (i < close) : (i += 1) {
        if (word[i] == '{') depth += 1;
        if (word[i] == '}') depth -|= 1;
        if (word[i] == ',' and depth == 0) {
            try alts.append(try allocator.dupe(u8, word[start..i]));
            start = i + 1;
        }
    }
    try alts.append(try allocator.dupe(u8, word[start..close]));
    for (alts.items) |alt| {
        const joined = try std.mem.concat(allocator, u8, &.{ word[0..open], alt, word[close + 1 ..] });
        defer allocator.free(joined);
        try braceInto(allocator, joined, out);
    }
}

fn expandTilde(allocator: std.mem.Allocator, word: []const u8) ![]u8 {
    if (word.len == 0 or word[0] != '~') return allocator.dupe(u8, word);
    if (word.len > 1 and word[1] != '/') return allocator.dupe(u8, word);
    const home = env_mod.home() orelse return allocator.dupe(u8, word);
    if (word.len == 1) return allocator.dupe(u8, home);
    return std.mem.concat(allocator, u8, &.{ home, word[1..] });
}

fn expandEnv(allocator: std.mem.Allocator, word: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < word.len) {
        if (word[i] != '$' or i + 1 >= word.len) {
            try out.append(word[i]);
            i += 1;
            continue;
        }
        if (word[i + 1] == '{') {
            const end = std.mem.indexOfScalarPos(u8, word, i + 2, '}') orelse {
                try out.append(word[i]);
                i += 1;
                continue;
            };
            const name = word[i + 2 .. end];
            if (env_mod.get(name)) |v| try out.appendSlice(v);
            i = end + 1;
            continue;
        }
        var j = i + 1;
        if (!std.ascii.isAlphabetic(word[j]) and word[j] != '_') {
            try out.append(word[i]);
            i += 1;
            continue;
        }
        while (j < word.len and (std.ascii.isAlphanumeric(word[j]) or word[j] == '_')) j += 1;
        if (env_mod.get(word[i + 1 .. j])) |v| try out.appendSlice(v);
        i = j;
    }
    return out.toOwnedSlice();
}

fn globPaths(allocator: std.mem.Allocator, cwd: []const u8, word: []const u8) ![][]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, word, '/');
    const dir_part = if (slash) |s| word[0..s] else "";
    const pat = if (slash) |s| word[s + 1 ..] else word;
    if (pat.len == 0 or !hasMeta(pat)) {
        const one = try allocator.alloc([]u8, 1);
        one[0] = try allocator.dupe(u8, word);
        return one;
    }
    var dir = openDir(cwd, if (dir_part.len == 0) "." else dir_part) catch {
        const one = try allocator.alloc([]u8, 1);
        one[0] = try allocator.dupe(u8, word);
        return one;
    };
    defer dir.close();
    var matches = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (matches.items) |m| allocator.free(m);
        matches.deinit();
    }
    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (ent.name.len == 0) continue;
        if (ent.name[0] == '.' and pat[0] != '.') continue;
        if (!globMatch(pat, ent.name)) continue;
        if (dir_part.len == 0) {
            try matches.append(try allocator.dupe(u8, ent.name));
        } else {
            try matches.append(try std.fs.path.join(allocator, &.{ dir_part, ent.name }));
        }
        if (matches.items.len >= 512) break;
    }
    if (matches.items.len == 0) {
        try matches.append(try allocator.dupe(u8, word));
    }
    return matches.toOwnedSlice();
}

fn globMatch(pat: []const u8, text: []const u8) bool {
    if (pat.len == 0) return text.len == 0;
    if (pat[0] == '*') {
        var i: usize = 0;
        while (i <= text.len) : (i += 1) if (globMatch(pat[1..], text[i..])) return true;
        return false;
    }
    if (text.len == 0) return false;
    if (pat[0] == '?') return globMatch(pat[1..], text[1..]);
    if (pat[0] == '[') {
        const end = std.mem.indexOfScalar(u8, pat[1..], ']') orelse return false;
        if (!inClass(pat[1 .. 1 + end], text[0])) return false;
        return globMatch(pat[2 + end ..], text[1..]);
    }
    if (pat[0] != text[0]) return false;
    return globMatch(pat[1..], text[1..]);
}

fn inClass(class: []const u8, c: u8) bool {
    if (class.len == 0) return false;
    const neg = class[0] == '!';
    const body = if (neg) class[1..] else class;
    var ok = false;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (i + 2 < body.len and body[i + 1] == '-') {
            if (c >= body[i] and c <= body[i + 2]) ok = true;
            i += 2;
        } else if (body[i] == c) ok = true;
    }
    return if (neg) !ok else ok;
}

const Base = struct { dir: std.fs.Dir, owned: bool };

fn openBase(cwd: []const u8) !Base {
    if (cwd.len == 0) return .{ .dir = std.fs.cwd(), .owned = false };
    return .{ .dir = try std.fs.openDirAbsolute(cwd, .{}), .owned = true };
}

fn openDir(cwd: []const u8, path: []const u8) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) return std.fs.openDirAbsolute(path, .{ .iterate = true, .no_follow = true });
    var base = try openBase(cwd);
    defer if (base.owned) base.dir.close();
    if (std.mem.eql(u8, path, ".")) {
        if (cwd.len == 0) return std.fs.cwd().openDir(".", .{ .iterate = true });
        return std.fs.openDirAbsolute(cwd, .{ .iterate = true });
    }
    return base.dir.openDir(path, .{ .iterate = true, .no_follow = true });
}

pub fn lstat(cwd: []const u8, path: []const u8) !?std.fs.File.Stat {
    if (path.len == 0) return null;
    var base = openBase(cwd) catch return null;
    defer if (base.owned) base.dir.close();
    if (builtin.os.tag == .windows) {
        return base.dir.statFile(path) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
    }
    const st = std.posix.fstatat(base.dir.fd, path, std.posix.AT.SYMLINK_NOFOLLOW) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    return std.fs.File.Stat.fromSystem(st);
}

/// Follow the last symlink (for `mv` into a directory). Missing path is null.
pub fn statFollow(cwd: []const u8, path: []const u8) !?std.fs.File.Stat {
    if (path.len == 0) return null;
    var base = openBase(cwd) catch return null;
    defer if (base.owned) base.dir.close();
    return base.dir.statFile(path) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
}

pub fn openWalk(cwd: []const u8, path: []const u8) !std.fs.Dir {
    return openDir(cwd, path);
}

/// Existing paths `mv` would replace. Empty means the command is not an
/// overwrite. Every returned slice is owned.
pub fn mvDestinations(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    expand: []const match.Expand,
    cwd: []const u8,
) ![][]u8 {
    const av = match.effectiveArgv(argv);
    if (av.len == 0 or !std.mem.eql(u8, std.fs.path.basename(av[0]), "mv")) return allocator.alloc([]u8, 0);
    const start = argv.len - av.len;
    var no_target = false;
    var target: ?[]const u8 = null;
    var operands = std.ArrayList(usize).init(allocator);
    defer operands.deinit();
    var i: usize = 1;
    while (i < av.len) : (i += 1) {
        const a = av[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            while (i < av.len) : (i += 1) try operands.append(i);
            break;
        }
        if (std.mem.eql(u8, a, "-T") or std.mem.eql(u8, a, "--no-target-directory")) {
            no_target = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--target-directory")) {
            if (i + 1 < av.len) {
                target = av[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--target-directory=")) {
            target = a["--target-directory=".len..];
            continue;
        }
        if (a.len > 1 and a[0] == '-') continue;
        try operands.append(i);
    }
    const dest_tok: ?[]const u8 = target orelse if (operands.items.len >= 2) av[operands.items[operands.items.len - 1]] else null;
    const dest_raw = dest_tok orelse return allocator.alloc([]u8, 0);
    const dest_i: usize = blk: {
        if (target) |tok| {
            var k: usize = 1;
            while (k < av.len) : (k += 1) if (av[k].ptr == tok.ptr) break :blk start + k;
        }
        break :blk start + operands.items[operands.items.len - 1];
    };
    const mode: match.Expand = if (dest_i < expand.len) expand[dest_i] else .all;
    const dests = try expandWord(allocator, cwd, dest_raw, mode);
    defer {
        for (dests) |d| allocator.free(d);
        allocator.free(dests);
    }
    if (dests.len != 1) return allocator.alloc([]u8, 0);
    const dest = dests[0];
    const followed = (try statFollow(cwd, dest)) orelse return allocator.alloc([]u8, 0);

    var out = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit();
    }
    if (followed.kind == .directory and !no_target) {
        const srcs = if (target != null) operands.items else operands.items[0 .. operands.items.len - 1];
        for (srcs) |si| {
            const src_mode: match.Expand = if (start + si < expand.len) expand[start + si] else .all;
            const srcs_exp = try expandWord(allocator, cwd, av[si], src_mode);
            defer {
                for (srcs_exp) |s| allocator.free(s);
                allocator.free(srcs_exp);
            }
            for (srcs_exp) |src| {
                const base = std.fs.path.basename(src);
                if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) continue;
                const child = try std.fs.path.join(allocator, &.{ dest, base });
                errdefer allocator.free(child);
                if (try statFollow(cwd, child) != null) try out.append(child) else allocator.free(child);
            }
        }
    } else {
        try out.append(try allocator.dupe(u8, dest));
    }
    return out.toOwnedSlice();
}

pub fn freeList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

test "brace, env and glob expansion stay read-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "bb" });
    try tmp.dir.writeFile(.{ .sub_path = "c.log", .data = "c" });
    const cwd = try @import("../testutil.zig").tmpPath(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(cwd);

    const braced = try expandWord(std.testing.allocator, cwd, "{a,b}.txt", .all);
    defer freeList(std.testing.allocator, braced);
    try std.testing.expectEqual(@as(usize, 2), braced.len);

    const globbed = try expandWord(std.testing.allocator, cwd, "*.txt", .all);
    defer freeList(std.testing.allocator, globbed);
    try std.testing.expectEqual(@as(usize, 2), globbed.len);

    const quoted = try expandWord(std.testing.allocator, cwd, "*.txt", .none);
    defer freeList(std.testing.allocator, quoted);
    try std.testing.expectEqualStrings("*.txt", quoted[0]);
}
