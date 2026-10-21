//! Local, read-only impact estimates.
//!
//! Directory walks use lstat and never follow symlinks. Git previews run
//! fixed read-only argv (`git diff`, `git clean -n`, `git log`), never the
//! user's command and never a shell. The risky command is not executed.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("../platform/io.zig");
const match = @import("match.zig");
const paths = @import("expand.zig");

pub const Report = struct {
    summary: []u8,
    lines: [][]u8,
    partial: bool,

    pub fn deinit(self: *Report, a: std.mem.Allocator) void {
        a.free(self.summary);
        paths.freeList(a, self.lines);
        self.* = undefined;
    }

    pub fn flat(self: *const Report, a: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).init(a);
        errdefer out.deinit();
        try out.appendSlice(self.summary);
        for (self.lines) |line| {
            try out.append('\n');
            try out.appendSlice(line);
        }
        return out.toOwnedSlice();
    }
};

const max_entries: u64 = 4000;
const max_show: usize = 8;
const budget_ms: i64 = 200;

const Walk = struct {
    files: u64 = 0,
    dirs: u64 = 0,
    bytes: u64 = 0,
    missing: u64 = 0,
    lines: std.ArrayList([]u8),
    partial: bool = false,
    started: i64,

    fn note(self: *Walk, a: std.mem.Allocator, text: []const u8) void {
        if (self.lines.items.len >= max_show) return;
        const d = a.dupe(u8, text) catch return;
        self.lines.append(d) catch a.free(d);
    }

    fn over(self: *Walk) bool {
        if (self.entries() >= max_entries) {
            self.partial = true;
            return true;
        }
        if (std.time.milliTimestamp() - self.started > budget_ms) {
            self.partial = true;
            return true;
        }
        return self.partial;
    }

    fn entries(self: *const Walk) u64 {
        return self.files + self.dirs;
    }
};

pub fn estimate(a: std.mem.Allocator, hit: *const match.Hit, cwd: []const u8, remote: bool) !Report {
    if (remote) {
        return simple(a, "remote shell; the local filesystem was not walked. The command was not run.", &.{}, false);
    }
    const pattern = hit.pattern;
    const cmd = hit.command();
    const av = match.effectiveArgv(cmd.argv);
    var report = if (std.mem.eql(u8, pattern, ">") or std.mem.eql(u8, pattern, ">>"))
        try truncating(a, hit, cwd)
    else if (std.mem.eql(u8, pattern, "mv:overwrite"))
        try mvImpact(a, cmd.argv, cmd.expand, cwd)
    else if (std.mem.indexOf(u8, pattern, " | ") != null)
        try pipeImpact(a, hit)
    else if (std.mem.startsWith(u8, pattern, "rm "))
        try treeImpact(a, cmd.argv, cmd.expand, cwd, "rm would delete", 0)
    else if (std.mem.startsWith(u8, pattern, "chmod"))
        try treeImpact(a, cmd.argv, cmd.expand, cwd, "chmod -R would change", 1)
    else if (std.mem.startsWith(u8, pattern, "chown"))
        try treeImpact(a, cmd.argv, cmd.expand, cwd, "chown -R would change", 1)
    else if (std.mem.startsWith(u8, pattern, "find"))
        try findImpact(a, cmd.argv, cmd.expand, cwd)
    else if (std.mem.eql(u8, pattern, "git reset --hard"))
        try gitReset(a, av, cwd)
    else if (std.mem.eql(u8, pattern, "git clean"))
        try gitClean(a, av, cwd)
    else if (std.mem.startsWith(u8, pattern, "git push"))
        try gitPush(a, av, cwd)
    else if (std.mem.eql(u8, pattern, "dd"))
        try ddImpact(a, av, cwd)
    else if (std.mem.startsWith(u8, pattern, "mkfs"))
        try mkfsImpact(a, av, cwd)
    else
        try simple(a, "matched a risky pattern. The command was not run.", &.{}, false);

    if (hit.line.subst) {
        const note = try a.dupe(u8, "command substitution was not evaluated");
        errdefer a.free(note);
        const extra = try a.alloc([]u8, report.lines.len + 1);
        extra[0] = note;
        @memcpy(extra[1..], report.lines);
        a.free(report.lines);
        report.lines = extra;
        report.partial = true;
    }
    return report;
}

fn simple(a: std.mem.Allocator, summary: []const u8, lines: []const []const u8, partial: bool) !Report {
    var owned = try a.alloc([]u8, lines.len);
    errdefer a.free(owned);
    var n: usize = 0;
    errdefer {
        for (owned[0..n]) |s| a.free(s);
    }
    for (lines) |line| {
        owned[n] = try a.dupe(u8, line);
        n += 1;
    }
    return .{
        .summary = try a.dupe(u8, summary),
        .lines = owned,
        .partial = partial,
    };
}

fn finishWalk(a: std.mem.Allocator, w: *Walk, verb: []const u8) !Report {
    var bytes: [32]u8 = undefined;
    var buf: [220]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "{s} {d} file{s} in {d} director{s} ({s}){s}. The command was not run.", .{
        verb,
        w.files,
        if (w.files == 1) "" else "s",
        w.dirs,
        if (w.dirs == 1) "y" else "ies",
        formatBytes(&bytes, w.bytes),
        if (w.partial) "; preview stopped early" else "",
    }) catch verb;
    const lines = try w.lines.toOwnedSlice();
    errdefer paths.freeList(a, lines);
    return .{
        .summary = try a.dupe(u8, summary),
        .lines = lines,
        .partial = w.partial,
    };
}

fn treeImpact(
    a: std.mem.Allocator,
    argv: []const []const u8,
    expand: []const match.Expand,
    cwd: []const u8,
    verb: []const u8,
    skip_first: usize,
) !Report {
    var w = Walk{ .lines = std.ArrayList([]u8).init(a), .started = std.time.milliTimestamp() };
    errdefer paths.freeList(a, w.lines.items);
    const ops = try positionals(a, argv, expand, cwd, skip_first);
    defer paths.freeList(a, ops);
    if (ops.len == 0) {
        w.lines.deinit();
        return simple(a, "no paths were given. The command was not run.", &.{}, false);
    }
    for (ops) |p| consider(a, cwd, p, true, &w);
    return finishWalk(a, &w, verb);
}

fn consider(a: std.mem.Allocator, cwd: []const u8, path: []const u8, recurse: bool, w: *Walk) void {
    if (w.over()) return;
    if (path.len == 0 or std.mem.eql(u8, path, "/")) {
        w.partial = true;
        w.note(a, "skipped /");
        return;
    }
    const st = paths.lstat(cwd, path) catch {
        w.partial = true;
        w.note(a, path);
        return;
    } orelse {
        w.missing += 1;
        var b: [300]u8 = undefined;
        const missing = std.fmt.bufPrint(&b, "not found: {s}", .{path}) catch path;
        w.note(a, missing);
        return;
    };
    switch (st.kind) {
        .directory => {
            w.dirs += 1;
            w.note(a, path);
            if (recurse) walkDir(a, cwd, path, w);
        },
        .sym_link => {
            w.files += 1;
            w.note(a, path);
        },
        else => {
            w.files += 1;
            w.bytes += st.size;
            w.note(a, path);
        },
    }
}

fn walkDir(a: std.mem.Allocator, cwd: []const u8, path: []const u8, w: *Walk) void {
    var dir = paths.openWalk(cwd, path) catch {
        w.partial = true;
        return;
    };
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |ent| {
        if (w.over()) return;
        if (std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
        const child = std.fs.path.join(a, &.{ path, ent.name }) catch {
            w.partial = true;
            return;
        };
        defer a.free(child);
        switch (ent.kind) {
            .sym_link => {
                w.files += 1;
                w.note(a, child);
            },
            .directory => {
                w.dirs += 1;
                w.note(a, child);
                walkDir(a, cwd, child, w);
            },
            .file, .block_device, .character_device, .named_pipe, .unix_domain_socket, .whiteout, .door, .event_port, .unknown => {
                const st = paths.lstat(cwd, child) catch null;
                if (st) |s| {
                    switch (s.kind) {
                        .directory => {
                            w.dirs += 1;
                            w.note(a, child);
                            walkDir(a, cwd, child, w);
                        },
                        .sym_link => {
                            w.files += 1;
                            w.note(a, child);
                        },
                        else => {
                            w.bytes += s.size;
                            w.files += 1;
                            w.note(a, child);
                        },
                    }
                } else {
                    w.files += 1;
                    w.note(a, child);
                }
            },
        }
    }
}

/// Non-option operands, expanded. `skip_first` drops leading operands
/// (chmod's mode, chown's owner) after flags are removed.
fn positionals(
    a: std.mem.Allocator,
    argv: []const []const u8,
    expand: []const match.Expand,
    cwd: []const u8,
    skip_first: usize,
) ![][]u8 {
    const av = match.effectiveArgv(argv);
    const start = argv.len - av.len;
    var idx = std.ArrayList(usize).init(a);
    defer idx.deinit();
    var i: usize = 1;
    var ended = false;
    while (i < av.len) : (i += 1) {
        const arg = av[i];
        if (!ended and std.mem.eql(u8, arg, "--")) {
            ended = true;
            continue;
        }
        if (!ended and arg.len > 1 and arg[0] == '-') continue;
        try idx.append(i);
    }
    var out = std.ArrayList([]u8).init(a);
    errdefer paths.freeList(a, out.items);
    const from = @min(skip_first, idx.items.len);
    for (idx.items[from..]) |ai| {
        const full_i = start + ai;
        const mode: match.Expand = if (full_i < expand.len) expand[full_i] else .all;
        const got = try paths.expandWord(a, cwd, av[ai], mode);
        defer a.free(got);
        for (got) |g| try out.append(try a.dupe(u8, g));
        for (got) |g| a.free(g);
    }
    return out.toOwnedSlice();
}

fn truncating(a: std.mem.Allocator, hit: *const match.Hit, cwd: []const u8) !Report {
    var lines = std.ArrayList([]u8).init(a);
    errdefer paths.freeList(a, lines.items);
    var files: u64 = 0;
    var bytes: u64 = 0;
    for (hit.line.statements[hit.statement]) |cmd| {
        for (cmd.redirects) |r| {
            if (r.kind != .trunc or r.target.len == 0) continue;
            if (r.target[0] == '&' or (r.target.len <= 2 and std.ascii.isDigit(r.target[0]))) continue;
            const got = try paths.expandWord(a, cwd, r.target, r.expand);
            defer paths.freeList(a, got);
            for (got) |p| {
                files += 1;
                const st = paths.lstat(cwd, p) catch null;
                const size: u64 = if (st) |s| s.size else 0;
                bytes += size;
                var b: [320]u8 = undefined;
                var nb: [32]u8 = undefined;
                const note = if (st == null)
                    std.fmt.bufPrint(&b, "would create {s}", .{p}) catch p
                else
                    std.fmt.bufPrint(&b, "would truncate {s} ({s})", .{ p, formatBytes(&nb, size) }) catch p;
                if (lines.items.len < max_show) {
                    const d = try a.dupe(u8, note);
                    try lines.append(d);
                }
            }
        }
    }
    var buf: [160]u8 = undefined;
    var nb: [32]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "would truncate {d} file{s} ({s}). The command was not run.", .{
        files,
        if (files == 1) "" else "s",
        formatBytes(&nb, bytes),
    }) catch "would truncate a file. The command was not run.";
    return .{
        .summary = try a.dupe(u8, summary),
        .lines = try lines.toOwnedSlice(),
        .partial = false,
    };
}

fn mvImpact(a: std.mem.Allocator, argv: []const []const u8, expand: []const match.Expand, cwd: []const u8) !Report {
    const dests = try paths.mvDestinations(a, argv, expand, cwd);
    var lines = std.ArrayList([]u8).init(a);
    errdefer paths.freeList(a, lines.items);
    var bytes: u64 = 0;
    for (dests) |p| {
        const st = paths.lstat(cwd, p) catch null;
        if (st) |s| bytes += s.size;
        var b: [320]u8 = undefined;
        var nb: [32]u8 = undefined;
        const note = std.fmt.bufPrint(&b, "would replace {s} ({s})", .{ p, formatBytes(&nb, if (st) |s| s.size else 0) }) catch p;
        if (lines.items.len < max_show) try lines.append(try a.dupe(u8, note));
        a.free(p);
    }
    a.free(dests);
    var buf: [180]u8 = undefined;
    var nb: [32]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "mv would replace {d} existing path{s} ({s}). The command was not run.", .{
        lines.items.len,
        if (lines.items.len == 1) "" else "s",
        formatBytes(&nb, bytes),
    }) catch "mv would replace an existing path. The command was not run.";
    return .{ .summary = try a.dupe(u8, summary), .lines = try lines.toOwnedSlice(), .partial = false };
}

fn pipeImpact(a: std.mem.Allocator, hit: *const match.Hit) !Report {
    var lines = std.ArrayList([]u8).init(a);
    errdefer paths.freeList(a, lines.items);
    for (hit.line.statements[hit.statement]) |cmd| {
        for (cmd.argv) |arg| {
            if (!std.mem.startsWith(u8, arg, "http://") and !std.mem.startsWith(u8, arg, "https://")) continue;
            if (lines.items.len >= max_show) break;
            var b: [400]u8 = undefined;
            const note = std.fmt.bufPrint(&b, "URL (not fetched): {s}", .{arg}) catch arg;
            try lines.append(try a.dupe(u8, note));
        }
    }
    if (lines.items.len == 0) try lines.append(try a.dupe(u8, "no URL was parsed; nothing was fetched"));
    return .{
        .summary = try a.dupe(u8, "would download a script and pipe it to a shell. Nothing was fetched or executed."),
        .lines = try lines.toOwnedSlice(),
        .partial = false,
    };
}

fn findImpact(a: std.mem.Allocator, argv: []const []const u8, expand: []const match.Expand, cwd: []const u8) !Report {
    const av = match.effectiveArgv(argv);
    const start = argv.len - av.len;
    var names = std.ArrayList([]const u8).init(a);
    defer names.deinit();
    var type_c: ?u8 = null;
    var roots = std.ArrayList([]u8).init(a);
    defer paths.freeList(a, roots.items);
    var i: usize = 1;
    var expr = false;
    while (i < av.len) : (i += 1) {
        const arg = av[i];
        if (!expr and arg.len > 0 and arg[0] != '-' and !std.mem.eql(u8, arg, "(") and !std.mem.eql(u8, arg, "!") and !std.mem.eql(u8, arg, ",")) {
            const mode: match.Expand = if (start + i < expand.len) expand[start + i] else .all;
            const got = try paths.expandWord(a, cwd, arg, mode);
            defer paths.freeList(a, got);
            for (got) |g| try roots.append(try a.dupe(u8, g));
            continue;
        }
        expr = true;
        if (std.mem.eql(u8, arg, "-name") or std.mem.eql(u8, arg, "-iname")) {
            if (i + 1 < av.len) {
                try names.append(av[i + 1]);
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "-type") and i + 1 < av.len and av[i + 1].len == 1) {
            type_c = av[i + 1][0];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-delete") or std.mem.eql(u8, arg, "-print") or std.mem.eql(u8, arg, "-print0")) continue;
        if (std.mem.eql(u8, arg, "-exec") or std.mem.eql(u8, arg, "-execdir") or std.mem.eql(u8, arg, "-ok")) {
            return simple(a, "find -exec would run another command. It was not run, and the preview did not walk it.", &.{}, true);
        }
        if (allowedFind(arg)) continue;
        return simple(a, "find expression is too complex to preview safely. The command was not run.", &.{}, true);
    }
    if (roots.items.len == 0) try roots.append(try a.dupe(u8, "."));
    var w = Walk{ .lines = std.ArrayList([]u8).init(a), .started = std.time.milliTimestamp() };
    for (roots.items) |root| walkFind(a, cwd, root, names.items, type_c, &w);
    var report = try finishWalk(a, &w, "find -delete would remove");
    report.partial = report.partial or w.partial;
    return report;
}

fn allowedFind(arg: []const u8) bool {
    const ok = [_][]const u8{ "(", ")", "!", "-not", "-a", "-and", "-o", "-or", "," };
    for (ok) |s| if (std.mem.eql(u8, arg, s)) return true;
    return false;
}

fn walkFind(a: std.mem.Allocator, cwd: []const u8, path: []const u8, names: []const []const u8, type_c: ?u8, w: *Walk) void {
    if (w.over()) return;
    const st = paths.lstat(cwd, path) catch {
        w.partial = true;
        return;
    } orelse return;
    if (findMatch(path, st, names, type_c)) {
        if (st.kind == .directory) w.dirs += 1 else {
            w.files += 1;
            if (st.kind != .sym_link) w.bytes += st.size;
        }
        w.note(a, path);
    }
    if (st.kind != .directory) return;
    var dir = paths.openWalk(cwd, path) catch {
        w.partial = true;
        return;
    };
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |ent| {
        if (std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
        const child = std.fs.path.join(a, &.{ path, ent.name }) catch return;
        defer a.free(child);
        if (ent.kind == .sym_link) {
            if (findName(ent.name, names) and (type_c == null or type_c == 'l')) {
                w.files += 1;
                w.note(a, child);
            }
            continue;
        }
        walkFind(a, cwd, child, names, type_c, w);
    }
}

fn findMatch(path: []const u8, st: std.fs.File.Stat, names: []const []const u8, type_c: ?u8) bool {
    if (type_c) |c| {
        const ok = switch (c) {
            'd' => st.kind == .directory,
            'f' => st.kind == .file,
            'l' => st.kind == .sym_link,
            else => true,
        };
        if (!ok) return false;
    }
    return findName(std.fs.path.basename(path), names);
}

fn findName(base: []const u8, names: []const []const u8) bool {
    if (names.len == 0) return true;
    for (names) |n| if (globStar(n, base)) return true;
    return false;
}

fn globStar(pat: []const u8, text: []const u8) bool {
    if (std.mem.indexOfAny(u8, pat, "*?") == null) return std.mem.eql(u8, pat, text);
    if (pat.len == 0) return text.len == 0;
    if (pat[0] == '*') {
        var i: usize = 0;
        while (i <= text.len) : (i += 1) if (globStar(pat[1..], text[i..])) return true;
        return false;
    }
    if (text.len == 0) return false;
    if (pat[0] == '?' or pat[0] == text[0]) return globStar(pat[1..], text[1..]);
    return false;
}

fn gitReset(a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !Report {
    const rev = gitRev(argv, "reset");
    var lines = std.ArrayList([]u8).init(a);
    errdefer paths.freeList(a, lines.items);
    const dirty = capture(a, cwd, &.{ "git", "diff", "--name-only" }) catch {
        return simple(a, "git reset --hard would discard uncommitted work. git could not be asked (read-only). The command was not run.", &.{}, true);
    };
    defer a.free(dirty);
    const staged = capture(a, cwd, &.{ "git", "diff", "--cached", "--name-only" }) catch "";
    defer if (staged.len > 0) a.free(staged);
    try takeLines(a, &lines, dirty);
    try takeLines(a, &lines, staged);
    if (rev) |r| {
        const argv_log = [_][]const u8{ "git", "log", "--oneline", "-n", "12", try std.fmt.allocPrint(a, "{s}..HEAD", .{r}) };
        defer a.free(argv_log[5]);
        const log = capture(a, cwd, &argv_log) catch "";
        defer if (log.len > 0) a.free(log);
        try takeLines(a, &lines, log);
    }
    const summary = if (lines.items.len == 0)
        "git reset --hard would discard uncommitted changes. None are visible from here. The command was not run."
    else
        "git reset --hard would discard these tracked changes. The command was not run.";
    return .{ .summary = try a.dupe(u8, summary), .lines = try lines.toOwnedSlice(), .partial = false };
}

fn gitClean(a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !Report {
    var args = std.ArrayList([]const u8).init(a);
    defer args.deinit();
    try args.appendSlice(&.{ "git", "clean", "-n" });
    var i: usize = 0;
    // argv is the effective command: git clean ...
    while (i < argv.len) : (i += 1) {
        if (i < 2) continue;
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "-X")) {
            try args.append(arg);
            continue;
        }
        if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            if (std.mem.indexOfScalar(u8, arg, 'd') != null) try args.append("-d");
            if (std.mem.indexOfScalar(u8, arg, 'x') != null) try args.append("-x");
            if (std.mem.indexOfScalar(u8, arg, 'X') != null) try args.append("-X");
            continue;
        }
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exclude")) {
            if (i + 1 < argv.len and safePath(argv[i + 1])) {
                try args.append("-e");
                try args.append(argv[i + 1]);
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--exclude=") and safePath(arg["--exclude=".len..])) {
            try args.append(arg);
            continue;
        }
        if (arg.len > 0 and arg[0] != '-' and safePath(arg)) try args.append(arg);
    }
    const out = capture(a, cwd, args.items) catch {
        return simple(a, "git clean would remove untracked files. A dry run could not be started. The command was not run.", &.{}, true);
    };
    defer a.free(out);
    var lines = std.ArrayList([]u8).init(a);
    errdefer paths.freeList(a, lines.items);
    try takeLines(a, &lines, out);
    const summary = if (lines.items.len == 0)
        "git clean dry-run listed nothing. The command was not run."
    else
        "git clean would remove these untracked paths (dry run). The command was not run.";
    return .{ .summary = try a.dupe(u8, summary), .lines = try lines.toOwnedSlice(), .partial = false };
}

fn gitPush(a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !Report {
    const spec = pushSpec(argv);
    const range = if (spec) |s|
        try std.fmt.allocPrint(a, "{s}..{s}/{s}", .{ s.branch, s.remote, s.branch })
    else
        try a.dupe(u8, "HEAD..@{upstream}");
    defer a.free(range);
    const log = capture(a, cwd, &.{ "git", "log", "--oneline", "-n", "12", range }) catch {
        return simple(a, "git push --force would overwrite remote history. The commits that would be lost could not be listed. The command was not run.", &.{}, true);
    };
    defer a.free(log);
    var lines = std.ArrayList([]u8).init(a);
    errdefer paths.freeList(a, lines.items);
    try takeLines(a, &lines, log);
    const summary = if (lines.items.len == 0)
        "git push --force: no remote-only commits were listed. The command was not run."
    else
        "git push --force would drop these remote commits. The command was not run.";
    return .{ .summary = try a.dupe(u8, summary), .lines = try lines.toOwnedSlice(), .partial = false };
}

const PushSpec = struct { remote: []const u8, branch: []const u8 };

fn pushSpec(argv: []const []const u8) ?PushSpec {
    var ops: [2][]const u8 = .{ "", "" };
    var n: usize = 0;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (i < 2) continue;
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < argv.len and n < 2) : (i += 1) {
                if (safePath(argv[i])) {
                    ops[n] = argv[i];
                    n += 1;
                }
            }
            break;
        }
        if (arg.len > 1 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--push-option") or std.mem.eql(u8, arg, "--receive-pack") or std.mem.eql(u8, arg, "--exec") or std.mem.eql(u8, arg, "--repo")) {
                i += 1;
            }
            continue;
        }
        if (n < 2 and safePath(arg)) {
            ops[n] = arg;
            n += 1;
        }
    }
    if (n >= 2) return .{ .remote = ops[0], .branch = ops[1] };
    return null;
}

fn gitRev(argv: []const []const u8, sub: []const u8) ?[]const u8 {
    var seen_sub = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!seen_sub) {
            if (std.mem.eql(u8, arg, sub)) seen_sub = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            if (i + 1 < argv.len and safeRev(argv[i + 1])) return argv[i + 1];
            return null;
        }
        if (arg.len > 1 and arg[0] == '-') continue;
        if (safeRev(arg)) return arg;
    }
    return null;
}

fn safeRev(s: []const u8) bool {
    if (s.len == 0 or s.len > 80 or s[0] == '-') return false;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (std.mem.indexOfScalar(u8, "~^@{}/_.+-", c) != null) continue;
        return false;
    }
    return true;
}

fn safePath(s: []const u8) bool {
    if (s.len == 0 or s.len > 200 or s[0] == '-') return false;
    if (std.mem.indexOfAny(u8, s, "\r\n;&|`$") != null) return false;
    return true;
}

fn ddImpact(a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !Report {
    var of: []const u8 = "";
    var count: []const u8 = "";
    for (argv) |arg| {
        if (std.mem.startsWith(u8, arg, "of=")) of = arg[3..];
        if (std.mem.startsWith(u8, arg, "count=")) count = arg["count=".len..];
    }
    if (of.len == 0) return simple(a, "dd has no of= target. The command was not run.", &.{}, false);
    const st = paths.lstat(cwd, of) catch null;
    var b: [360]u8 = undefined;
    var nb: [32]u8 = undefined;
    const line = if (st) |s|
        std.fmt.bufPrint(&b, "would write {s} ({s}{s})", .{ of, formatBytes(&nb, s.size), if (count.len > 0) ", count set" else "" }) catch of
    else
        std.fmt.bufPrint(&b, "would write {s} (path not found)", .{of}) catch of;
    return simple(a, "dd would overwrite its output file. The command was not run.", &.{line}, false);
}

fn mkfsImpact(a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !Report {
    var dev: []const u8 = "";
    var i = argv.len;
    while (i > 1) {
        i -= 1;
        if (argv[i].len > 0 and argv[i][0] != '-') {
            dev = argv[i];
            break;
        }
    }
    if (dev.len == 0) return simple(a, "mkfs device was not parsed. The command was not run.", &.{}, true);
    const st = paths.lstat(cwd, dev) catch null;
    var b: [300]u8 = undefined;
    var nb: [32]u8 = undefined;
    const line = if (st) |s|
        std.fmt.bufPrint(&b, "would format {s} ({s})", .{ dev, formatBytes(&nb, s.size) }) catch dev
    else
        std.fmt.bufPrint(&b, "would format {s}", .{dev}) catch dev;
    return simple(a, "mkfs would format a device. The command was not run.", &.{line}, false);
}

fn takeLines(a: std.mem.Allocator, lines: *std.ArrayList([]u8), text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (lines.items.len >= max_show) return;
        try lines.append(try a.dupe(u8, trimmed));
    }
}

fn capture(a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    if (cwd.len > 0) child.cwd = cwd;
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }
    const file = child.stdout.?;
    const max: usize = 48 * 1024;
    if (builtin.os.tag == .windows) {
        const out = try file.reader().readAllAlloc(a, max);
        _ = child.wait() catch {};
        return out;
    }
    io.setNonBlocking(file.handle) catch {};
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    const deadline = std.time.milliTimestamp() + 1500;
    var buf: [4096]u8 = undefined;
    var eof = false;
    while (std.time.milliTimestamp() < deadline and out.items.len < max) {
        const n = file.read(&buf) catch |e| switch (e) {
            error.WouldBlock => {
                var fds = [_]io.PollFd{io.pollFd(file.handle, io.POLL.IN)};
                _ = io.poll(&fds, 40);
                continue;
            },
            else => break,
        };
        if (n == 0) {
            eof = true;
            break;
        }
        try out.appendSlice(buf[0..n]);
    }
    if (!eof) _ = child.kill() catch {};
    _ = child.wait() catch {};
    return out.toOwnedSlice();
}

fn formatBytes(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(n);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) {
        v /= 1024;
        u += 1;
    }
    if (u == 0) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "0 B";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "0 B";
}

// ---------------------------------------------------------------- tests

const t = std.testing;

test "rm preview counts files and does not delete them" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("dir/sub");
    try tmp.dir.writeFile(.{ .sub_path = "dir/a.txt", .data = "hello" });
    try tmp.dir.writeFile(.{ .sub_path = "dir/sub/b.txt", .data = "world!" });
    try tmp.dir.writeFile(.{ .sub_path = "keep.txt", .data = "stay" });
    const cwd = try @import("../testutil.zig").tmpPath(t.allocator, &tmp, ".");
    defer t.allocator.free(cwd);

    var hit = (try match.intercept(t.allocator, "rm -rf dir *.txt", &match.defaults, cwd, false)).?;
    defer hit.deinit(t.allocator);
    var report = try estimate(t.allocator, &hit, cwd, false);
    defer report.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, report.summary, "was not run") != null);
    try t.expect(report.summary.len > 0);
    // a.txt, b.txt, and the glob also sees keep.txt. dir is walked.
    try t.expect(std.mem.indexOf(u8, report.summary, "file") != null);

    var body: [8]u8 = undefined;
    const f = try tmp.dir.openFile("dir/a.txt", .{});
    defer f.close();
    try t.expectEqualStrings("hello", body[0..try f.readAll(&body)]);
    try tmp.dir.access("keep.txt", .{});
    try tmp.dir.access("dir/sub/b.txt", .{});
}

test "truncating redirect and mv overwrite are counted without writing" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "log", .data = "abcdef" });
    try tmp.dir.writeFile(.{ .sub_path = "dest", .data = "keep" });
    try tmp.dir.writeFile(.{ .sub_path = "src", .data = "new" });
    const cwd = try @import("../testutil.zig").tmpPath(t.allocator, &tmp, ".");
    defer t.allocator.free(cwd);

    var hit = (try match.intercept(t.allocator, "echo x > log", &match.defaults, cwd, false)).?;
    defer hit.deinit(t.allocator);
    var report = try estimate(t.allocator, &hit, cwd, false);
    defer report.deinit(t.allocator);
    try t.expect(report.lines.len >= 1);
    try t.expect(std.mem.indexOf(u8, report.lines[0], "log") != null);

    var hit2 = (try match.intercept(t.allocator, "mv src dest", &match.defaults, cwd, false)).?;
    defer hit2.deinit(t.allocator);
    var report2 = try estimate(t.allocator, &hit2, cwd, false);
    defer report2.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, report2.summary, "replace") != null);

    var buf: [8]u8 = undefined;
    const f = try tmp.dir.openFile("dest", .{});
    defer f.close();
    try t.expectEqualStrings("keep", buf[0..try f.readAll(&buf)]);
    const g = try tmp.dir.openFile("log", .{});
    defer g.close();
    var buf2: [8]u8 = undefined;
    try t.expectEqualStrings("abcdef", buf2[0..try g.readAll(&buf2)]);
}

test "append redirect is not a truncating preview" {
    try t.expect(try match.intercept(t.allocator, "echo x >> log", &match.defaults, "/tmp", false) == null);
}

fn runGit(cwd: []const u8, argv: []const []const u8) !void {
    const out = try capture(t.allocator, cwd, argv);
    t.allocator.free(out);
}

test "git reset and clean previews are read-only" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../testutil.zig").tmpPath(t.allocator, &tmp, ".");
    defer t.allocator.free(cwd);
    runGit(cwd, &.{ "git", "--version" }) catch return;
    try runGit(cwd, &.{ "git", "init", "-q" });
    try runGit(cwd, &.{ "git", "config", "user.email", "t@example.com" });
    try runGit(cwd, &.{ "git", "config", "user.name", "t" });
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "one\n" });
    try runGit(cwd, &.{ "git", "add", "f.txt" });
    try runGit(cwd, &.{ "git", "commit", "-q", "-m", "init" });
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "one\ntwo\n" });
    try tmp.dir.writeFile(.{ .sub_path = "extra.txt", .data = "junk" });

    var hit = (try match.intercept(t.allocator, "git reset --hard", &match.defaults, cwd, false)).?;
    defer hit.deinit(t.allocator);
    var report = try estimate(t.allocator, &hit, cwd, false);
    defer report.deinit(t.allocator);
    var saw = false;
    for (report.lines) |line| if (std.mem.indexOf(u8, line, "f.txt") != null) {
        saw = true;
    };
    try t.expect(saw);

    var hit2 = (try match.intercept(t.allocator, "git clean -fd", &match.defaults, cwd, false)).?;
    defer hit2.deinit(t.allocator);
    var report2 = try estimate(t.allocator, &hit2, cwd, false);
    defer report2.deinit(t.allocator);
    var saw_extra = false;
    for (report2.lines) |line| if (std.mem.indexOf(u8, line, "extra.txt") != null) {
        saw_extra = true;
    };
    try t.expect(saw_extra);

    var body: [16]u8 = undefined;
    const f = try tmp.dir.openFile("f.txt", .{});
    defer f.close();
    try t.expectEqualStrings("one\ntwo\n", body[0..try f.readAll(&body)]);
    tmp.dir.access("extra.txt", .{}) catch unreachable;
}
