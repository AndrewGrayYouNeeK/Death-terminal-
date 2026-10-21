//! Risky-command matching for Ghost Run.
//!
//! The line is tokenised only. Nothing is executed: no shell, no
//! `$(...)`, no globs. Patterns come from `defaults` or from
//! `config.ghost_run.patterns` (a custom list replaces the defaults).

const std = @import("std");

pub const defaults = [_][]const u8{
    "rm -r",
    "rm -R",
    "rm --recursive",
    "git reset --hard",
    "git clean",
    "git push --force",
    "git push --force-with-lease",
    "git push -f",
    "dd",
    "mkfs*",
    "chmod -R",
    "chown -R",
    "find -delete",
    "find -exec",
    "find -execdir",
    "mv:overwrite",
    ">",
    "curl | sh",
    "wget | sh",
};

pub const Expand = enum { all, env, none };

pub const RedirKind = enum { trunc, append, other };

pub const Redirect = struct {
    kind: RedirKind,
    target: []const u8,
    expand: Expand,
};

pub const Command = struct {
    argv: []const []const u8,
    expand: []const Expand,
    redirects: []const Redirect,
};

pub const Line = struct {
    arena: *std.heap.ArenaAllocator,
    /// Statements (`&&`, `||`, `;`, `&`) of pipelines (`|`).
    statements: []const []const Command,
    /// Unquoted `$(` or backticks: preview must not evaluate them.
    subst: bool = false,

    pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

pub const Hit = struct {
    pattern: []const u8,
    line: Line,
    statement: usize,
    cmd: usize,

    pub fn deinit(self: *Hit, allocator: std.mem.Allocator) void {
        self.line.deinit(allocator);
    }

    pub fn command(self: *const Hit) Command {
        return self.line.statements[self.statement][self.cmd];
    }
};

const shells = [_][]const u8{ "sh", "bash", "dash", "ash", "zsh", "ksh", "fish", "csh", "tcsh" };
const wrappers = [_][]const u8{ "sudo", "doas", "command", "exec", "nohup", "time", "nice", "stdbuf", "env" };

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Line {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();
    var statements = std.ArrayList([]const Command).init(a);
    var pipeline = std.ArrayList(Command).init(a);
    var argv = std.ArrayList([]const u8).init(a);
    var expand = std.ArrayList(Expand).init(a);
    var redirs = std.ArrayList(Redirect).init(a);
    var subst = false;
    var i: usize = 0;
    var pending: ?RedirKind = null;

    const flush_cmd = struct {
        fn call(
            aa: std.mem.Allocator,
            pipe: *std.ArrayList(Command),
            av: *std.ArrayList([]const u8),
            ex: *std.ArrayList(Expand),
            rd: *std.ArrayList(Redirect),
        ) !void {
            if (av.items.len == 0 and rd.items.len == 0) return;
            try pipe.append(.{
                .argv = try av.toOwnedSlice(),
                .expand = try ex.toOwnedSlice(),
                .redirects = try rd.toOwnedSlice(),
            });
            av.* = std.ArrayList([]const u8).init(aa);
            ex.* = std.ArrayList(Expand).init(aa);
            rd.* = std.ArrayList(Redirect).init(aa);
        }
    }.call;

    while (i < source.len) {
        while (i < source.len and std.ascii.isWhitespace(source[i])) i += 1;
        if (i >= source.len) break;
        if (pending) |kind| {
            const word = try readWord(a, source, &i, &subst);
            try redirs.append(.{ .kind = kind, .target = word.text, .expand = word.expand });
            pending = null;
            continue;
        }
        if (operator(source, i)) |op| {
            i += op.len;
            switch (op.class) {
                .pipe => try flush_cmd(a, &pipeline, &argv, &expand, &redirs),
                .statement => {
                    try flush_cmd(a, &pipeline, &argv, &expand, &redirs);
                    if (pipeline.items.len > 0) try statements.append(try pipeline.toOwnedSlice());
                    pipeline = std.ArrayList(Command).init(a);
                },
                .redir => {
                    if (op.eat_target) pending = op.redir else try redirs.append(.{
                        .kind = op.redir,
                        .target = "",
                        .expand = .none,
                    });
                },
            }
            continue;
        }
        const word = try readWord(a, source, &i, &subst);
        if (word.text.len == 0) continue;
        try argv.append(word.text);
        try expand.append(word.expand);
    }
    if (pending) |kind| try redirs.append(.{ .kind = kind, .target = "", .expand = .none });
    try flush_cmd(a, &pipeline, &argv, &expand, &redirs);
    if (pipeline.items.len > 0) try statements.append(try pipeline.toOwnedSlice());

    return .{
        .arena = arena,
        .statements = try statements.toOwnedSlice(),
        .subst = subst,
    };
}

const Class = enum { pipe, statement, redir };

const Found = struct {
    len: usize,
    class: Class,
    redir: RedirKind = .other,
    eat_target: bool = false,
};

fn operator(s: []const u8, i: usize) ?Found {
    const rest = s[i..];
    if (std.mem.startsWith(u8, rest, ">>")) return .{ .len = 2, .class = .redir, .redir = .append, .eat_target = true };
    if (std.mem.startsWith(u8, rest, "<<")) return .{ .len = 2, .class = .redir, .redir = .other, .eat_target = true };
    if (std.mem.startsWith(u8, rest, ">&")) return .{ .len = 2, .class = .redir, .redir = .trunc, .eat_target = true };
    if (std.mem.startsWith(u8, rest, "<&")) return .{ .len = 2, .class = .redir, .redir = .other, .eat_target = true };
    if (std.mem.startsWith(u8, rest, "&>")) return .{ .len = 2, .class = .redir, .redir = .trunc, .eat_target = true };
    if (std.mem.startsWith(u8, rest, ">|")) return .{ .len = 2, .class = .redir, .redir = .trunc, .eat_target = true };
    if (std.mem.startsWith(u8, rest, "||")) return .{ .len = 2, .class = .statement };
    if (std.mem.startsWith(u8, rest, "&&")) return .{ .len = 2, .class = .statement };
    if (std.mem.startsWith(u8, rest, "|&")) return .{ .len = 2, .class = .pipe };
    if (rest[0] == '|') return .{ .len = 1, .class = .pipe };
    if (rest[0] == ';') return .{ .len = 1, .class = .statement };
    if (rest[0] == '&') return .{ .len = 1, .class = .statement };
    if (rest[0] == '<') return .{ .len = 1, .class = .redir, .redir = .other, .eat_target = true };
    if (rest[0] == '>') return .{ .len = 1, .class = .redir, .redir = .trunc, .eat_target = true };
    // 2>, 2>>, 2>&
    if (std.ascii.isDigit(rest[0])) {
        var j: usize = 0;
        while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
        if (j < rest.len and rest[j] == '>') {
            if (j + 1 < rest.len and rest[j + 1] == '>') return .{ .len = j + 2, .class = .redir, .redir = .append, .eat_target = true };
            if (j + 1 < rest.len and rest[j + 1] == '&') return .{ .len = j + 2, .class = .redir, .redir = .other, .eat_target = true };
            return .{ .len = j + 1, .class = .redir, .redir = .trunc, .eat_target = true };
        }
    }
    return null;
}

const Word = struct { text: []const u8, expand: Expand };

fn readWord(a: std.mem.Allocator, s: []const u8, i: *usize, subst: *bool) !Word {
    var out = std.ArrayList(u8).init(a);
    var saw_unquoted = false;
    var saw_single = false;
    var saw_double = false;
    var quote: u8 = 0;
    while (i.* < s.len) {
        const c = s[i.*];
        if (quote == 0 and (std.ascii.isWhitespace(c) or operator(s, i.*) != null)) break;
        if (quote == 0 and (c == '\'' or c == '"')) {
            quote = c;
            if (c == '\'') saw_single = true else saw_double = true;
            i.* += 1;
            continue;
        }
        if (quote != 0 and c == quote) {
            quote = 0;
            i.* += 1;
            continue;
        }
        if (c == '\\' and quote != '\'' and i.* + 1 < s.len) {
            i.* += 1;
            try out.append(s[i.*]);
            i.* += 1;
            if (quote == 0) saw_unquoted = true;
            continue;
        }
        if (quote == 0) {
            saw_unquoted = true;
            if (c == '`' or (c == '$' and i.* + 1 < s.len and s[i.* + 1] == '(')) subst.* = true;
        }
        try out.append(c);
        i.* += 1;
    }
    const mode: Expand = if (saw_unquoted) .all else if (saw_double and !saw_single) .env else .none;
    return .{ .text = out.items, .expand = mode };
}

fn isEnvAssign(s: []const u8) bool {
    if (s.len == 0 or s[0] == '-' or s[0] == '=') return false;
    const eq = std.mem.indexOfScalar(u8, s, '=') orelse return false;
    if (eq == 0) return false;
    for (s[0..eq]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn isWrapper(name: []const u8) bool {
    for (wrappers) |w| if (std.mem.eql(u8, name, w)) return true;
    return false;
}

/// argv with leading env assignments and sudo/env/time wrappers removed.
pub fn effectiveArgv(argv: []const []const u8) []const []const u8 {
    var i: usize = 0;
    while (i < argv.len and isEnvAssign(argv[i])) i += 1;
    while (i < argv.len) {
        const base = std.fs.path.basename(argv[i]);
        if (!isWrapper(base)) break;
        const wrapped = base;
        i += 1;
        if (std.mem.eql(u8, wrapped, "sudo") or std.mem.eql(u8, wrapped, "doas")) {
            while (i < argv.len and argv[i].len > 1 and argv[i][0] == '-') {
                const opt = argv[i];
                i += 1;
                if (opt.len == 2 and std.mem.indexOfScalar(u8, "ugCphrUtg", opt[1]) != null and i < argv.len) i += 1;
            }
        } else if (std.mem.eql(u8, wrapped, "env")) {
            while (i < argv.len and (isEnvAssign(argv[i]) or (argv[i].len > 0 and argv[i][0] == '-'))) {
                const opt = argv[i];
                i += 1;
                if ((std.mem.eql(u8, opt, "-u") or std.mem.eql(u8, opt, "--unset")) and i < argv.len) i += 1;
            }
        } else {
            while (i < argv.len and argv[i].len > 1 and argv[i][0] == '-') i += 1;
        }
    }
    return argv[i..];
}

fn shortCluster(token: []const u8) ?[]const u8 {
    if (token.len < 2 or token.len > 4 or token[0] != '-' or token[1] == '-') return null;
    for (token[1..]) |c| if (!std.ascii.isAlphabetic(c)) return null;
    return token[1..];
}

fn hasLong(argv: []const []const u8, name: []const u8) bool {
    for (argv) |a| {
        if (std.mem.eql(u8, a, name)) return true;
        if (std.mem.startsWith(u8, a, name) and a.len > name.len and a[name.len] == '=') return true;
    }
    return false;
}

fn hasShortLetter(argv: []const []const u8, letter: u8) bool {
    for (argv) |a| {
        if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            if (std.mem.indexOfScalar(u8, a[1..], letter) != null) return true;
        }
    }
    return false;
}

fn longAlias(letter: u8) ?[]const u8 {
    return switch (letter) {
        'r', 'R' => "--recursive",
        'f' => "--force",
        else => null,
    };
}

fn flagPresent(argv: []const []const u8, token: []const u8) bool {
    if (shortCluster(token)) |letters| {
        for (letters) |letter| {
            if (hasShortLetter(argv, letter)) continue;
            if (longAlias(letter)) |alias| if (hasLong(argv, alias)) continue;
            return false;
        }
        return true;
    }
    if (token.len > 1 and token[0] == '-') return hasLong(argv, token);
    return false;
}

fn globMatch(pat: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (ti < text.len) {
        if (pi < pat.len and (pat[pi] == '?' or pat[pi] == text[ti])) {
            pi += 1;
            ti += 1;
        } else if (pi < pat.len and pat[pi] == '*') {
            star = pi;
            pi += 1;
            mark = ti;
        } else if (star) |s| {
            pi = s + 1;
            mark += 1;
            ti = mark;
        } else return false;
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

fn tokenMatch(pat: []const u8, text: []const u8, command: bool) bool {
    const got = if (command) std.fs.path.basename(text) else text;
    if (std.mem.indexOfAny(u8, pat, "*?") != null) return globMatch(pat, got);
    return std.mem.eql(u8, pat, got);
}

fn matchArgv(pat_tokens: []const []const u8, argv: []const []const u8) bool {
    if (pat_tokens.len == 0 or argv.len == 0) return false;
    if (!tokenMatch(pat_tokens[0], argv[0], true)) return false;
    var ai: usize = 1;
    for (pat_tokens[1..]) |p| {
        if (p.len > 0 and p[0] == '-') {
            if (!flagPresent(argv, p)) return false;
            continue;
        }
        var found = false;
        while (ai < argv.len) : (ai += 1) {
            if (tokenMatch(p, argv[ai], false)) {
                found = true;
                ai += 1;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn splitPattern(a: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(a);
    var it = std.mem.tokenizeAny(u8, pattern, " \t");
    while (it.next()) |tok| try list.append(tok);
    return list.toOwnedSlice();
}

fn isShell(name: []const u8) bool {
    const b = std.fs.path.basename(name);
    for (shells) |s| if (std.mem.eql(u8, b, s)) return true;
    return false;
}

fn dryRunGitClean(argv: []const []const u8) bool {
    if (hasShortLetter(argv, 'n') or hasLong(argv, "--dry-run")) return true;
    return false;
}

fn matchPipe(a: std.mem.Allocator, pattern: []const u8, pipeline: []const Command) !bool {
    const bar = std.mem.indexOf(u8, pattern, " | ") orelse return false;
    const left = std.mem.trim(u8, pattern[0..bar], " ");
    const right = std.mem.trim(u8, pattern[bar + 3 ..], " ");
    const left_toks = try splitPattern(a, left);
    defer a.free(left_toks);
    const right_toks = try splitPattern(a, right);
    defer a.free(right_toks);
    var li: ?usize = null;
    for (pipeline, 0..) |cmd, i| {
        const av = effectiveArgv(cmd.argv);
        if (av.len == 0) continue;
        if (matchArgv(left_toks, av)) {
            li = i;
            break;
        }
    }
    const from = (li orelse return false) + 1;
    if (from > pipeline.len) return false;
    for (pipeline[from..]) |cmd| {
        const av = effectiveArgv(cmd.argv);
        if (av.len == 0) continue;
        if (right_toks.len == 1 and std.mem.eql(u8, right_toks[0], "sh") and isShell(av[0])) return true;
        if (matchArgv(right_toks, av)) return true;
    }
    return false;
}

fn hasTrunc(cmd: Command) bool {
    for (cmd.redirects) |r| if (r.kind == .trunc) {
        if (r.target.len > 0 and r.target[0] == '&') continue;
        if (r.target.len > 0 and r.target.len <= 2 and std.ascii.isDigit(r.target[0])) continue;
        return true;
    };
    return false;
}

fn lineHasTrunc(statement: []const Command) bool {
    for (statement) |c| if (hasTrunc(c)) return true;
    return false;
}

/// First matching pattern, or null. `cwd` is only used for `mv:overwrite`
/// (a stat, never a write). `remote` skips that stat.
pub fn intercept(
    allocator: std.mem.Allocator,
    command: []const u8,
    patterns: []const []const u8,
    cwd: []const u8,
    remote: bool,
) !?Hit {
    const trimmed = std.mem.trim(u8, command, " \t");
    if (trimmed.len == 0) return null;
    var line = try parse(allocator, trimmed);
    errdefer line.deinit(allocator);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    for (patterns) |pattern| {
        if (std.mem.eql(u8, pattern, "mv:overwrite")) {
            if (remote) continue;
            if (try findMv(allocator, &line, cwd)) |at| {
                return .{ .pattern = pattern, .line = line, .statement = at[0], .cmd = at[1] };
            }
            continue;
        }
        if (std.mem.eql(u8, pattern, ">")) {
            for (line.statements, 0..) |st, si| if (lineHasTrunc(st)) {
                return .{ .pattern = pattern, .line = line, .statement = si, .cmd = 0 };
            };
            continue;
        }
        if (std.mem.indexOf(u8, pattern, " | ") != null) {
            for (line.statements, 0..) |st, si| {
                if (try matchPipe(sa, pattern, st)) {
                    return .{ .pattern = pattern, .line = line, .statement = si, .cmd = 0 };
                }
            }
            continue;
        }
        const toks = try splitPattern(sa, pattern);
        for (line.statements, 0..) |st, si| {
            for (st, 0..) |cmd, ci| {
                const av = effectiveArgv(cmd.argv);
                if (!matchArgv(toks, av)) continue;
                if (std.mem.eql(u8, pattern, "git clean") and dryRunGitClean(av)) continue;
                return .{ .pattern = pattern, .line = line, .statement = si, .cmd = ci };
            }
        }
    }
    line.deinit(allocator);
    return null;
}

fn findMv(allocator: std.mem.Allocator, line: *const Line, cwd: []const u8) !?[2]usize {
    for (line.statements, 0..) |st, si| {
        for (st, 0..) |cmd, ci| {
            const av = effectiveArgv(cmd.argv);
            if (av.len == 0 or !std.mem.eql(u8, std.fs.path.basename(av[0]), "mv")) continue;
            if (try mvOverwrites(allocator, av, cmd.expand, cwd)) return .{ si, ci };
        }
    }
    return null;
}

/// True when `mv` would replace an existing path. Stats only.
pub fn mvOverwrites(allocator: std.mem.Allocator, argv: []const []const u8, expand: []const Expand, cwd: []const u8) !bool {
    // Inline: expand.zig imports this file for `Expand`, so a top-level
    // import here would be a cycle.
    const paths = @import("expand.zig");
    const ops = try paths.mvDestinations(allocator, argv, expand, cwd);
    defer {
        for (ops) |p| allocator.free(p);
        allocator.free(ops);
    }
    return ops.len > 0;
}

// ---------------------------------------------------------------- tests

const t = std.testing;

fn hits(line: []const u8, patterns: []const []const u8) !bool {
    var h = try intercept(t.allocator, line, patterns, "/tmp", false) orelse return false;
    defer h.deinit(t.allocator);
    return true;
}

fn hitsDefault(line: []const u8) !bool {
    return hits(line, &defaults);
}

test "parser splits quotes, pipes and truncating redirects" {
    var line = try parse(t.allocator, "echo \"a b\" 'c' > out | wc -l");
    defer line.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), line.statements.len);
    try t.expectEqual(@as(usize, 2), line.statements[0].len);
    try t.expectEqualStrings("echo", line.statements[0][0].argv[0]);
    try t.expectEqualStrings("a b", line.statements[0][0].argv[1]);
    try t.expectEqualStrings("c", line.statements[0][0].argv[2]);
    try t.expect(line.statements[0][0].redirects[0].kind == .trunc);
    try t.expectEqualStrings("out", line.statements[0][0].redirects[0].target);
    try t.expect(!line.subst);
}

test "risky patterns match the built-in list" {
    try t.expect(try hitsDefault("rm -rf /tmp/x"));
    try t.expect(try hitsDefault("rm -fr dir"));
    try t.expect(try hitsDefault("rm -r -- dir"));
    try t.expect(try hitsDefault("/bin/rm --recursive ./a"));
    try t.expect(try hitsDefault("sudo rm -rf x"));
    try t.expect(try hitsDefault("sudo -u root rm -rf x"));
    try t.expect(try hitsDefault("FOO=1 rm -rf x"));
    try t.expect(try hitsDefault("git reset --hard"));
    try t.expect(try hitsDefault("git reset --hard HEAD~1"));
    try t.expect(try hitsDefault("git clean -fd"));
    try t.expect(try hitsDefault("git push --force origin main"));
    try t.expect(try hitsDefault("git push -f"));
    try t.expect(try hitsDefault("git push --force-with-lease"));
    try t.expect(try hitsDefault("dd if=/dev/zero of=disk bs=1M"));
    try t.expect(try hitsDefault("mkfs.ext4 /dev/sdb1"));
    try t.expect(try hitsDefault("chmod -R 755 ."));
    try t.expect(try hitsDefault("chown -R user:user /srv"));
    try t.expect(try hitsDefault("find . -name '*.o' -delete"));
    try t.expect(try hitsDefault("find . -exec rm {} \\;"));
    try t.expect(try hitsDefault("echo hi > file"));
    try t.expect(try hitsDefault("echo hi >| file"));
    try t.expect(try hitsDefault("make 2> log"));
    try t.expect(try hitsDefault("curl -fsSL https://example.com/x | sh"));
    try t.expect(try hitsDefault("curl https://example.com/x | bash"));
    try t.expect(try hitsDefault("wget -qO- https://example.com/x | sudo bash"));
    try t.expect(!try hitsDefault("rm -f file"));
    try t.expect(!try hitsDefault("rm file"));
    try t.expect(!try hitsDefault("git reset --soft HEAD~1"));
    try t.expect(!try hitsDefault("git clean -n"));
    try t.expect(!try hitsDefault("git clean --dry-run -fd"));
    try t.expect(!try hitsDefault("git push origin main"));
    try t.expect(!try hitsDefault("chmod 644 file"));
    try t.expect(!try hitsDefault("chown user file"));
    try t.expect(!try hitsDefault("echo hi >> file"));
    try t.expect(!try hitsDefault("echo \"rm -rf /\""));
    try t.expect(!try hitsDefault("echo hi"));
    try t.expect(!try hitsDefault(""));
}

test "a custom pattern list replaces the defaults" {
    const only = [_][]const u8{"dd"};
    try t.expect(try hits("dd if=a of=b", &only));
    try t.expect(!try hits("rm -rf x", &only));
    const none = [_][]const u8{};
    try t.expect(!try hits("rm -rf x", &none));
}

test "command substitution is flagged and not treated as a pipe" {
    var line = try parse(t.allocator, "rm -rf $(echo /tmp/x)");
    defer line.deinit(t.allocator);
    try t.expect(line.subst);
    try t.expect(try hitsDefault("rm -rf $(echo /tmp/x)"));
}
