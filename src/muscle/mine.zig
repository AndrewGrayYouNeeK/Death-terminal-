//! Find command sequences that repeat in one project.
//!
//! A sequence is 2..=max_len commands in order. Repeats are counted
//! without overlap, and only inside one project (git root, or the cwd
//! when there is no repository). A shorter sequence is dropped when a
//! longer one in the same project already covers it at least as often.

const std = @import("std");

pub const cap = 256;

pub const Record = struct {
    project: []const u8,
    command: []const u8,
};

pub const Options = struct {
    min_repeats: usize = 3,
    max_len: usize = 5,
};

pub const Hit = struct {
    project: []const u8,
    commands: []const []const u8,
    count: usize,
};

pub fn freeHits(a: std.mem.Allocator, hits: []Hit) void {
    for (hits) |h| a.free(h.commands);
    a.free(hits);
}

pub fn fingerprint(project: []const u8, commands: []const []const u8) u64 {
    var h = std.hash.Wyhash.init(0x4D555343);
    h.update(project);
    h.update("\x00");
    for (commands) |c| {
        h.update(c);
        h.update("\x00");
    }
    return h.final();
}

const Cand = struct {
    project: []const u8,
    cmds: []const []const u8,
    start: usize,
    len: usize,
    count: usize,
};

pub fn mine(a: std.mem.Allocator, records: []const Record, opts: Options) ![]Hit {
    if (opts.max_len < 2 or opts.min_repeats < 2) return a.alloc(Hit, 0);
    var groups = std.ArrayList(Group).init(a);
    defer {
        for (groups.items) |*g| g.cmds.deinit();
        groups.deinit();
    }
    for (records) |r| {
        if (r.project.len == 0 or r.command.len == 0) continue;
        const g = try groupFor(&groups, a, r.project);
        try g.cmds.append(r.command);
    }

    var raw = std.ArrayList(Cand).init(a);
    defer raw.deinit();
    for (groups.items) |g| {
        const window = if (g.cmds.items.len > cap) g.cmds.items[g.cmds.items.len - cap ..] else g.cmds.items;
        if (window.len < opts.min_repeats * 2) continue;
        const max_len = @min(opts.max_len, window.len);
        var len: usize = 2;
        while (len <= max_len) : (len += 1) {
            var i: usize = 0;
            while (i + len <= window.len) : (i += 1) {
                if (already(&raw, g.project, window, i, len)) continue;
                const n = countGreedy(window, i, len);
                if (n >= opts.min_repeats) {
                    try raw.append(.{ .project = g.project, .cmds = window, .start = i, .len = len, .count = n });
                }
            }
        }
    }

    std.sort.insertion(Cand, raw.items, {}, prefer);
    var kept = std.ArrayList(Cand).init(a);
    defer kept.deinit();
    for (raw.items) |c| {
        if (!isShadowed(kept.items, c)) try kept.append(c);
    }

    var hits = try a.alloc(Hit, kept.items.len);
    errdefer a.free(hits);
    var filled: usize = 0;
    errdefer {
        for (hits[0..filled]) |h| a.free(h.commands);
    }
    for (kept.items) |c| {
        const cmds = try a.alloc([]const u8, c.len);
        for (0..c.len) |k| cmds[k] = c.cmds[c.start + k];
        hits[filled] = .{ .project = c.project, .commands = cmds, .count = c.count };
        filled += 1;
    }
    return hits;
}

const Group = struct {
    project: []const u8,
    cmds: std.ArrayList([]const u8),
};

fn groupFor(groups: *std.ArrayList(Group), a: std.mem.Allocator, project: []const u8) !*Group {
    for (groups.items) |*g| if (std.mem.eql(u8, g.project, project)) return g;
    try groups.append(.{ .project = project, .cmds = std.ArrayList([]const u8).init(a) });
    return &groups.items[groups.items.len - 1];
}

fn already(raw: *const std.ArrayList(Cand), project: []const u8, cmds: []const []const u8, start: usize, len: usize) bool {
    for (raw.items) |c| {
        if (c.len != len or !std.mem.eql(u8, c.project, project)) continue;
        if (windowEq(c.cmds, c.start, cmds, start, len)) return true;
    }
    return false;
}

fn windowEq(a: []const []const u8, a0: usize, b: []const []const u8, b0: usize, len: usize) bool {
    for (0..len) |k| if (!std.mem.eql(u8, a[a0 + k], b[b0 + k])) return false;
    return true;
}

fn countGreedy(cmds: []const []const u8, start: usize, len: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + len <= cmds.len) {
        if (windowEq(cmds, start, cmds, i, len)) {
            n += 1;
            i += len;
        } else i += 1;
    }
    return n;
}

fn prefer(_: void, a: Cand, b: Cand) bool {
    if (a.len != b.len) return a.len > b.len;
    if (a.count != b.count) return a.count > b.count;
    return std.mem.order(u8, a.project, b.project) == .lt;
}

fn isShadowed(kept: []const Cand, c: Cand) bool {
    for (kept) |k| {
        if (k.len <= c.len or k.count < c.count) continue;
        if (!std.mem.eql(u8, k.project, c.project)) continue;
        if (containsSeq(k.cmds[k.start .. k.start + k.len], c.cmds[c.start .. c.start + c.len])) return true;
    }
    return false;
}

fn containsSeq(hay: []const []const u8, needle: []const []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (windowEq(hay, i, needle, 0, needle.len)) return true;
    }
    return false;
}

fn rec(project: []const u8, command: []const u8) Record {
    return .{ .project = project, .command = command };
}

test "three repeats of a pair in one project" {
    const a = std.testing.allocator;
    const rows = [_]Record{
        rec("/app", "git status"), rec("/app", "git diff"),
        rec("/app", "git status"), rec("/app", "git diff"),
        rec("/app", "git status"), rec("/app", "git diff"),
    };
    const hits = try mine(a, &rows, .{});
    defer freeHits(a, hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("/app", hits[0].project);
    try std.testing.expectEqual(@as(usize, 3), hits[0].count);
    try std.testing.expectEqual(@as(usize, 2), hits[0].commands.len);
    try std.testing.expectEqualStrings("git status", hits[0].commands[0]);
    try std.testing.expectEqualStrings("git diff", hits[0].commands[1]);
}

test "other projects and a higher repeat threshold do not match" {
    const a = std.testing.allocator;
    const rows = [_]Record{
        rec("/app", "git status"),   rec("/app", "git diff"),
        rec("/other", "git status"), rec("/other", "git diff"),
        rec("/app", "git status"),   rec("/app", "git diff"),
        rec("/app", "git status"),   rec("/app", "git diff"),
    };
    const hits = try mine(a, &rows, .{ .min_repeats = 4 });
    defer freeHits(a, hits);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
    const once = try mine(a, &rows, .{});
    defer freeHits(a, once);
    try std.testing.expectEqual(@as(usize, 1), once.len);
    try std.testing.expectEqualStrings("/app", once[0].project);
}

test "a longer sequence shadows its pieces" {
    const a = std.testing.allocator;
    const rows = [_]Record{
        rec("/app", "a"), rec("/app", "b"), rec("/app", "c"),
        rec("/app", "a"), rec("/app", "b"), rec("/app", "c"),
        rec("/app", "a"), rec("/app", "b"), rec("/app", "c"),
    };
    const hits = try mine(a, &rows, .{});
    defer freeHits(a, hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(usize, 3), hits[0].commands.len);
    try std.testing.expectEqualStrings("c", hits[0].commands[2]);
}

test "max_len limits how long a sequence can be" {
    const a = std.testing.allocator;
    const rows = [_]Record{
        rec("/app", "a"), rec("/app", "b"), rec("/app", "c"),
        rec("/app", "a"), rec("/app", "b"), rec("/app", "c"),
        rec("/app", "a"), rec("/app", "b"), rec("/app", "c"),
    };
    const hits = try mine(a, &rows, .{ .max_len = 2 });
    defer freeHits(a, hits);
    try std.testing.expect(hits.len >= 1);
    for (hits) |h| try std.testing.expect(h.commands.len <= 2);
    try std.testing.expect(hits.len <= 2);
}
