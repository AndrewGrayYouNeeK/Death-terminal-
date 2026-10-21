//! Content-addressed snapshots of one working tree.
//!
//! Blobs live under `<root>/objects/<hh>/<rest>`. A manifest under
//! `<root>/snaps/<id>.manifest` lists the tree. Identical bytes are stored
//! once. The snapshot tree (`snaps/<id>/tree/…`) hardlinks those blobs when
//! the filesystem allows it, so a second name does not copy the bytes.
//!
//! The walk uses `openat` without following symlinks. A link is recorded
//! as a link. Nothing outside the root directory is opened, hashed, or
//! written. Restores refuse a manifest path that is absolute or contains
//! `..`, and they copy or reflink into the live tree instead of hardlinking
//! (a hardlink would let a later save corrupt the blob).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const exclude = @import("exclude.zig");
const copy = @import("copy.zig");

pub const max_files: usize = 50_000;
pub const max_depth: u16 = 40;

pub const Kind = enum { file, symlink, dir, unread };

pub const Rec = struct {
    path: []u8,
    kind: Kind,
    mode: u32 = 0o644,
    size: u64 = 0,
    mtime_ns: i128 = 0,
    hash: [32]u8 = [_]u8{0} ** 32,
    link: []u8,

    pub fn deinit(self: *Rec, a: std.mem.Allocator) void {
        a.free(self.path);
        a.free(self.link);
    }
};

pub const Skip = enum { too_big, too_many };

pub const Snapshot = struct {
    id: []u8,
    cwd: []u8,
    bytes: u64 = 0,
    files: std.ArrayList(Rec),
    /// Set when the tree was not stored. `id` is empty in that case.
    skip: ?Skip = null,

    pub fn deinit(self: *Snapshot, a: std.mem.Allocator) void {
        a.free(self.id);
        a.free(self.cwd);
        for (self.files.items) |*r| r.deinit(a);
        self.files.deinit();
    }

    pub fn saved(self: *const Snapshot) bool {
        return self.skip == null and self.id.len > 0;
    }
};

pub const Diff = struct {
    added: std.ArrayList([]u8),
    removed: std.ArrayList([]u8),
    modified: std.ArrayList([]u8),

    pub fn deinit(self: *Diff, a: std.mem.Allocator) void {
        freeList(a, &self.added);
        freeList(a, &self.removed);
        freeList(a, &self.modified);
    }

    pub fn empty(self: *const Diff) bool {
        return self.added.items.len == 0 and self.removed.items.len == 0 and self.modified.items.len == 0;
    }
};

fn freeList(a: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |p| a.free(p);
    list.deinit();
}

pub const CaptureOpts = struct {
    max_bytes: u64,
    excludes: []const []const u8 = &.{},
    /// When set, a file whose size and mtime still match is not read again.
    prior: ?[]const Rec = null,
};

pub const Store = struct {
    a: std.mem.Allocator,
    root_path: []u8,
    root: std.fs.Dir,
    seq: u64 = 1,

    pub fn open(a: std.mem.Allocator, root_path: []const u8) !Store {
        const path = try a.dupe(u8, root_path);
        errdefer a.free(path);
        try std.fs.cwd().makePath(path);
        var root = try std.fs.cwd().openDir(path, .{});
        errdefer root.close();
        try root.makePath("objects");
        try root.makePath("tmp");
        try root.makePath("snaps");
        return .{ .a = a, .root_path = path, .root = root };
    }

    pub fn deinit(self: *Store) void {
        self.root.close();
        self.a.free(self.root_path);
    }

    pub fn capture(self: *Store, cwd: []const u8, opts: CaptureOpts) !Snapshot {
        if (!std.fs.path.isAbsolute(cwd)) return error.RelativePath;
        var tree = try std.fs.openDirAbsolute(cwd, .{ .iterate = true });
        defer tree.close();
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = try tree.realpath(".", &real_buf);
        var rules = try loadRules(self.a, tree, opts.excludes);
        defer rules.deinit();

        var listing = try walk(self.a, tree, rules.items(), opts);
        var listing_owned = true;
        errdefer if (listing_owned) listing.deinit(self.a);
        if (listing.skip) |why| {
            const bytes = listing.bytes;
            const cwd_owned = try self.a.dupe(u8, real);
            errdefer self.a.free(cwd_owned);
            listing_owned = false;
            listing.deinit(self.a);
            return .{
                .id = try self.a.dupe(u8, ""),
                .cwd = cwd_owned,
                .bytes = bytes,
                .files = std.ArrayList(Rec).init(self.a),
                .skip = why,
            };
        }

        const id = try self.nextId();
        var id_live = true;
        errdefer if (id_live) self.a.free(id);
        for (listing.files.items) |*rec| {
            if (rec.kind != .file) continue;
            self.ingest(tree, rec.path, &rec.hash) catch {
                rec.kind = .unread;
                continue;
            };
            self.linkIntoTree(id, rec) catch {};
        }
        const cwd_owned = try self.a.dupe(u8, real);
        var snap = Snapshot{
            .id = id,
            .cwd = cwd_owned,
            .bytes = listing.bytes,
            .files = listing.files,
        };
        id_live = false;
        listing.files = std.ArrayList(Rec).init(self.a);
        listing_owned = false;
        listing.deinit(self.a);
        errdefer snap.deinit(self.a);
        try self.writeManifest(&snap);
        return snap;
    }

    /// Metadata (and hashes) of the live tree, without writing blobs.
    pub fn scan(self: *Store, cwd: []const u8, opts: CaptureOpts) !Snapshot {
        if (!std.fs.path.isAbsolute(cwd)) return error.RelativePath;
        var tree = try std.fs.openDirAbsolute(cwd, .{ .iterate = true });
        defer tree.close();
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = try tree.realpath(".", &real_buf);
        var rules = try loadRules(self.a, tree, opts.excludes);
        defer rules.deinit();
        var walked = try walk(self.a, tree, rules.items(), opts);
        var walked_owned = true;
        errdefer if (walked_owned) walked.deinit(self.a);
        const cwd_owned = try self.a.dupe(u8, real);
        errdefer self.a.free(cwd_owned);
        const id = try self.a.dupe(u8, "");
        const files = walked.files;
        const bytes = walked.bytes;
        const skip = walked.skip;
        walked.files = std.ArrayList(Rec).init(self.a);
        walked_owned = false;
        walked.deinit(self.a);
        return .{
            .id = id,
            .cwd = cwd_owned,
            .bytes = bytes,
            .files = files,
            .skip = skip,
        };
    }

    pub fn load(self: *Store, id: []const u8) !Snapshot {
        if (!safeId(id)) return error.UnsafePath;
        var name_buf: [128]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "snaps/{s}.manifest", .{id});
        const text = try self.root.readFileAlloc(self.a, name, 32 * 1024 * 1024);
        defer self.a.free(text);
        return parseManifest(self.a, id, text);
    }

    /// Put `snap` back into its own directory. Refuses any other directory.
    /// Files are copied or reflinked, never hardlinked.
    pub fn restore(self: *Store, snap: *const Snapshot, cwd: []const u8) !void {
        if (!snap.saved()) return error.NotSaved;
        if (!std.fs.path.isAbsolute(cwd)) return error.RelativePath;
        for (snap.files.items) |rec| if (!safeRel(rec.path)) return error.UnsafePath;
        var tree = try std.fs.openDirAbsolute(cwd, .{ .iterate = true });
        defer tree.close();
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = try tree.realpath(".", &real_buf);
        if (!std.mem.eql(u8, real, snap.cwd)) return error.PathMismatch;
        try self.restoreInto(tree, snap, &.{});
    }

    pub fn restoreExcluding(self: *Store, snap: *const Snapshot, cwd: []const u8, excludes: []const []const u8) !void {
        if (!snap.saved()) return error.NotSaved;
        if (!std.fs.path.isAbsolute(cwd)) return error.RelativePath;
        for (snap.files.items) |rec| if (!safeRel(rec.path)) return error.UnsafePath;
        var tree = try std.fs.openDirAbsolute(cwd, .{ .iterate = true });
        defer tree.close();
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = try tree.realpath(".", &real_buf);
        if (!std.mem.eql(u8, real, snap.cwd)) return error.PathMismatch;
        try self.restoreInto(tree, snap, excludes);
    }

    fn restoreInto(self: *Store, tree: std.fs.Dir, snap: *const Snapshot, excludes: []const []const u8) !void {
        var rules = try loadRules(self.a, tree, excludes);
        defer rules.deinit();
        var live = try walk(self.a, tree, rules.items(), .{ .max_bytes = std.math.maxInt(u64), .prior = snap.files.items });
        defer live.deinit(self.a);

        var keep = std.StringHashMap(void).init(self.a);
        defer keep.deinit();
        for (snap.files.items) |rec| {
            if (!safeRel(rec.path)) return error.UnsafePath;
            try keep.put(rec.path, {});
        }
        for (live.files.items) |rec| if (rec.kind == .unread) {
            try keep.put(rec.path, {});
        };

        var doomed = std.ArrayList([]const u8).init(self.a);
        defer doomed.deinit();
        for (live.files.items) |rec| {
            if (rec.kind == .unread) continue;
            if (keep.get(rec.path) != null) continue;
            try doomed.append(rec.path);
        }
        std.mem.sort([]const u8, doomed.items, {}, deeperFirst);
        for (doomed.items) |rel| {
            const rec = findRec(live.files.items, rel) orelse continue;
            removeRel(tree, rel, rec.kind) catch {};
        }

        for (snap.files.items) |rec| {
            if (rec.kind == .unread) continue;
            if (!safeRel(rec.path)) return error.UnsafePath;
            switch (rec.kind) {
                .dir => try ensureDir(tree, rec.path),
                .symlink => try writeLink(tree, rec.path, rec.link),
                .file => try self.writeFile(tree, rec),
                .unread => {},
            }
        }
    }

    /// Drop manifests that are neither in `keep` nor among the newest
    /// `retention` snapshots, then delete blobs nothing references.
    pub fn prune(self: *Store, keep: []const []const u8, retention: usize) !void {
        var names = std.ArrayList([]u8).init(self.a);
        defer {
            for (names.items) |n| self.a.free(n);
            names.deinit();
        }
        var snaps = try self.root.openDir("snaps", .{ .iterate = true });
        defer snaps.close();
        var it = snaps.iterate();
        while (try it.next()) |ent| {
            if (!std.mem.endsWith(u8, ent.name, ".manifest")) continue;
            try names.append(try self.a.dupe(u8, ent.name));
        }
        std.mem.sort([]u8, names.items, {}, idLess);

        var keep_disk = std.StringHashMap(void).init(self.a);
        defer keep_disk.deinit();
        const newest = if (names.items.len > retention) names.items.len - retention else 0;
        for (names.items, 0..) |name, i| {
            const id = name[0 .. name.len - ".manifest".len];
            const pinned = for (keep) |k| {
                if (std.mem.eql(u8, k, id)) break true;
            } else false;
            if (pinned or i >= newest) {
                try keep_disk.put(id, {});
            } else {
                snaps.deleteFile(name) catch {};
                var tree_name: [160]u8 = undefined;
                if (std.fmt.bufPrint(&tree_name, "{s}.tree", .{id})) |tn| {
                    snaps.deleteTree(tn) catch {};
                } else |_| {}
            }
        }

        var referenced = std.StringHashMap(void).init(self.a);
        defer {
            var kit = referenced.keyIterator();
            while (kit.next()) |k| self.a.free(k.*);
            referenced.deinit();
        }
        var kit = keep_disk.keyIterator();
        while (kit.next()) |id| {
            const snap = self.load(id.*) catch continue;
            var owned = snap;
            defer owned.deinit(self.a);
            for (owned.files.items) |rec| {
                if (rec.kind != .file) continue;
                const hex = try hexAlloc(self.a, rec.hash);
                if (referenced.get(hex) != null) {
                    self.a.free(hex);
                } else {
                    try referenced.put(hex, {});
                }
            }
        }

        var objects = try self.root.openDir("objects", .{ .iterate = true });
        defer objects.close();
        var oit = objects.iterate();
        while (try oit.next()) |dirent| {
            if (dirent.kind != .directory) continue;
            var sub = objects.openDir(dirent.name, .{ .iterate = true }) catch continue;
            defer sub.close();
            var fit = sub.iterate();
            while (try fit.next()) |fent| {
                if (fent.kind != .file) continue;
                var hex_buf: [64]u8 = undefined;
                if (dirent.name.len + fent.name.len != 64) continue;
                @memcpy(hex_buf[0..dirent.name.len], dirent.name);
                @memcpy(hex_buf[dirent.name.len..][0..fent.name.len], fent.name);
                if (referenced.get(hex_buf[0..64]) == null) sub.deleteFile(fent.name) catch {};
            }
        }
    }

    fn nextId(self: *Store) ![]u8 {
        const id = try std.fmt.allocPrint(self.a, "{d}-{d}", .{ std.time.milliTimestamp(), self.seq });
        self.seq += 1;
        return id;
    }

    fn ingest(self: *Store, tree: std.fs.Dir, rel: []const u8, out_hash: *[32]u8) !void {
        const src = try openRelFile(tree, rel);
        defer src.close();
        self.seq += 1;
        var tmp_name: [64]u8 = undefined;
        const tmp_rel = try std.fmt.bufPrint(&tmp_name, "tmp/{d}.bin", .{self.seq});
        const dst = try self.root.createFile(tmp_rel, .{ .exclusive = true, .truncate = true });
        var dst_open = true;
        errdefer if (dst_open) dst.close();
        errdefer self.root.deleteFile(tmp_rel) catch {};
        var hashed = false;
        if (comptime builtin.os.tag == .linux) {
            const FICLONE = std.os.linux.IOCTL.IOW(0x94, 9, c_int);
            const rc = std.os.linux.ioctl(dst.handle, FICLONE, @as(usize, @intCast(src.handle)));
            // Raw syscall: 0 is success. libc errno() would treat -EOPNOTSUPP as success.
            if (rc == 0) {
                try src.seekTo(0);
                out_hash.* = try hashReader(src);
                hashed = true;
            }
        }
        if (!hashed) {
            try src.seekTo(0);
            out_hash.* = try copyHash(src, dst);
        }
        dst.close();
        dst_open = false;
        var obj_buf: [96]u8 = undefined;
        const obj = objectRel(&obj_buf, out_hash.*);
        if (self.root.statFile(obj)) |_| {
            self.root.deleteFile(tmp_rel) catch {};
        } else |_| {
            const parent = std.fs.path.dirname(obj) orelse return error.UnsafePath;
            try self.root.makePath(parent);
            self.root.rename(tmp_rel, obj) catch |err| {
                self.root.deleteFile(tmp_rel) catch {};
                return err;
            };
        }
    }

    fn linkIntoTree(self: *Store, id: []const u8, rec: *const Rec) !void {
        if (!safeId(id) or !safeRel(rec.path)) return error.UnsafePath;
        var obj_buf: [96]u8 = undefined;
        const obj = objectRel(&obj_buf, rec.hash);
        var obj_abs: [std.fs.max_path_bytes]u8 = undefined;
        const obj_path = try std.fmt.bufPrint(&obj_abs, "{s}/{s}", .{ self.root_path, obj });
        var dest_rel: [std.fs.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrint(&dest_rel, "snaps/{s}.tree/{s}", .{ id, rec.path });
        if (std.fs.path.dirname(rel)) |parent| try self.root.makePath(parent);
        var dest_abs: [std.fs.max_path_bytes]u8 = undefined;
        const dest_path = try std.fmt.bufPrint(&dest_abs, "{s}/{s}", .{ self.root_path, rel });
        _ = copy.place(obj_path, dest_path, true) catch {
            self.root.deleteFile(rel) catch {};
            return error.LinkFailed;
        };
    }

    fn writeFile(self: *Store, tree: std.fs.Dir, rec: Rec) !void {
        var obj_buf: [96]u8 = undefined;
        const obj = objectRel(&obj_buf, rec.hash);
        var obj_abs: [std.fs.max_path_bytes]u8 = undefined;
        const obj_path = try std.fmt.bufPrint(&obj_abs, "{s}/{s}", .{ self.root_path, obj });

        try ensureDir(tree, parentOf(rec.path));
        var parent = try openRelDir(tree, parentOf(rec.path));
        defer if (parentOf(rec.path).len > 0) parent.close();
        const base = std.fs.path.basename(rec.path);
        // Replace the directory entry. createFile would follow a symlink.
        parent.deleteFile(base) catch {};
        self.seq += 1;
        var tmp_name: [80]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_name, ".tt-{d}.tmp", .{self.seq});
        var parent_real: [std.fs.max_path_bytes]u8 = undefined;
        const preal = try parent.realpath(".", &parent_real);
        var tmp_abs: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_abs, "{s}/{s}", .{ preal, tmp });
        const method = copy.place(obj_path, tmp_path, false) catch {
            parent.deleteFile(tmp) catch {};
            const obj_f = try self.root.openFile(obj, .{});
            defer obj_f.close();
            const out = try parent.createFile(tmp, .{ .exclusive = true, .truncate = true });
            defer out.close();
            var buf: [64 * 1024]u8 = undefined;
            while (true) {
                const n = try obj_f.read(&buf);
                if (n == 0) break;
                try out.writeAll(buf[0..n]);
            }
            try finishWrite(parent, tmp, base, rec.mode);
            return;
        };
        _ = method;
        try finishWrite(parent, tmp, base, rec.mode);
    }

    fn writeManifest(self: *Store, snap: *const Snapshot) !void {
        var body = std.ArrayList(u8).init(self.a);
        defer body.deinit();
        const w = body.writer();
        try w.writeAll("youneek-time-travel 1\n");
        try w.writeAll("cwd ");
        try writeEncoded(w, snap.cwd);
        try w.print("\nbytes {d}\n", .{snap.bytes});
        for (snap.files.items) |rec| {
            switch (rec.kind) {
                .file => try w.writeAll("f "),
                .dir => try w.writeAll("d "),
                .symlink => try w.writeAll("l "),
                .unread => try w.writeAll("u "),
            }
            try w.print("{d} {d} {d} ", .{ rec.mode, rec.size, rec.mtime_ns });
            if (rec.kind == .file) {
                var hex_buf: [64]u8 = undefined;
                try w.writeAll(hexFmt(&hex_buf, rec.hash));
            } else try w.writeAll("-");
            try w.writeAll(" ");
            try writeEncoded(w, rec.path);
            if (rec.kind == .symlink) {
                try w.writeAll(" ");
                try writeEncoded(w, rec.link);
            }
            try w.writeByte('\n');
        }
        var name: [160]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "snaps/{s}.manifest", .{snap.id});
        try self.root.writeFile(.{ .sub_path = path, .data = body.items });
    }
};

fn finishWrite(parent: std.fs.Dir, tmp: []const u8, base: []const u8, mode: u32) !void {
    if (comptime builtin.os.tag != .windows) {
        if (mode != 0) {
            if (parent.openFile(tmp, .{ .mode = .write_only })) |f| {
                defer f.close();
                f.chmod(@intCast(mode & 0o777)) catch {};
            } else |_| {}
        }
    }
    parent.deleteFile(base) catch {};
    try parent.rename(tmp, base);
}

const Rules = struct {
    list: std.ArrayList(exclude.Rule),
    gitignore: []u8,

    fn deinit(self: *Rules) void {
        self.list.allocator.free(self.gitignore);
        self.list.deinit();
    }

    fn items(self: *const Rules) []const exclude.Rule {
        return self.list.items;
    }
};

fn loadRules(a: std.mem.Allocator, tree: std.fs.Dir, patterns: []const []const u8) !Rules {
    var list = std.ArrayList(exclude.Rule).init(a);
    errdefer list.deinit();
    for (patterns) |p| if (exclude.parsePattern(p)) |r| try list.append(r);
    const gitignore = readGitignore(a, tree) catch try a.dupe(u8, "");
    errdefer a.free(gitignore);
    try exclude.parseFile(gitignore, &list);
    return .{
        .list = list,
        .gitignore = gitignore,
    };
}

fn readGitignore(a: std.mem.Allocator, tree: std.fs.Dir) ![]u8 {
    const f = openNoFollow(tree, ".gitignore") catch return error.FileNotFound;
    defer f.close();
    const st = try f.stat();
    if (st.kind != .file) return error.NotFile;
    return f.readToEndAlloc(a, 256 * 1024);
}

const WalkOut = struct {
    files: std.ArrayList(Rec),
    bytes: u64 = 0,
    skip: ?Skip = null,

    fn deinit(self: *WalkOut, a: std.mem.Allocator) void {
        for (self.files.items) |*r| r.deinit(a);
        self.files.deinit();
    }
};

fn walk(a: std.mem.Allocator, tree: std.fs.Dir, rules: []const exclude.Rule, opts: CaptureOpts) !WalkOut {
    var out = WalkOut{ .files = std.ArrayList(Rec).init(a) };
    errdefer out.deinit(a);
    try walkDir(a, tree, "", 0, rules, opts, &out);
    std.mem.sort(Rec, out.files.items, {}, shallowerRec);
    return out;
}

fn walkDir(
    a: std.mem.Allocator,
    dir: std.fs.Dir,
    rel: []const u8,
    depth: u16,
    rules: []const exclude.Rule,
    opts: CaptureOpts,
    out: *WalkOut,
) !void {
    if (out.skip != null) return;
    if (depth > max_depth) return;
    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (out.skip != null) return;
        if (ent.name.len == 0 or std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
        if (std.mem.indexOfAny(u8, ent.name, "/\\\x00") != null) continue;
        const path = try joinRel(a, rel, ent.name);
        const is_dir = ent.kind == .directory;
        if (exclude.excluded(rules, path, is_dir)) {
            a.free(path);
            continue;
        }
        if (out.files.items.len >= max_files) {
            a.free(path);
            out.skip = .too_many;
            return;
        }
        switch (ent.kind) {
            .directory => {
                var child = dir.openDir(ent.name, .{ .iterate = true, .no_follow = true }) catch {
                    try pushUnread(a, out, path);
                    continue;
                };
                defer child.close();
                try appendRec(a, out, try makeRec(a, path, .dir, "", 0o755, 0, 0));
                try walkDir(a, child, path, depth + 1, rules, opts, out);
            },
            .sym_link => {
                var buf: [4096]u8 = undefined;
                const target = dir.readLink(ent.name, &buf) catch {
                    try pushUnread(a, out, path);
                    continue;
                };
                try appendRec(a, out, try makeRec(a, path, .symlink, target, 0o777, 0, 0));
            },
            .file => {
                const opened = openNoFollow(dir, ent.name) catch {
                    try pushUnread(a, out, path);
                    continue;
                };
                var file = opened;
                defer file.close();
                const st = file.stat() catch {
                    try pushUnread(a, out, path);
                    continue;
                };
                if (st.kind != .file) {
                    try pushUnread(a, out, path);
                    continue;
                }
                out.bytes +|= st.size;
                if (out.bytes > opts.max_bytes) {
                    a.free(path);
                    out.skip = .too_big;
                    return;
                }
                var rec = try makeRec(a, path, .file, "", unixMode(st.mode), st.size, st.mtime);
                if (priorMatch(opts.prior, rec.path, rec.size, rec.mtime_ns)) |prev| {
                    rec.hash = prev.hash;
                } else {
                    file.seekTo(0) catch {};
                    rec.hash = hashReader(file) catch blk: {
                        rec.kind = .unread;
                        break :blk [_]u8{0} ** 32;
                    };
                }
                try appendRec(a, out, rec);
            },
            else => a.free(path),
        }
    }
}

fn appendRec(a: std.mem.Allocator, out: *WalkOut, rec: Rec) !void {
    var owned = rec;
    out.files.append(owned) catch |err| {
        owned.deinit(a);
        return err;
    };
}

fn pushUnread(a: std.mem.Allocator, out: *WalkOut, path: []u8) !void {
    try appendRec(a, out, try makeRec(a, path, .unread, "", 0, 0, 0));
}

fn unixMode(mode: anytype) u32 {
    if (comptime @bitSizeOf(@TypeOf(mode)) < 9) {
        return 0o644;
    } else {
        return @as(u32, @intCast(mode & 0o777));
    }
}

fn makeRec(a: std.mem.Allocator, path: []u8, kind: Kind, link: []const u8, mode: u32, size: u64, mtime: i128) !Rec {
    errdefer a.free(path);
    const link_owned = try a.dupe(u8, if (kind == .symlink) link else "");
    return .{
        .path = path,
        .kind = kind,
        .mode = mode,
        .size = size,
        .mtime_ns = mtime,
        .link = link_owned,
    };
}

fn priorMatch(prior: ?[]const Rec, path: []const u8, size: u64, mtime: i128) ?Rec {
    const list = prior orelse return null;
    for (list) |rec| {
        if (rec.kind == .file and rec.size == size and rec.mtime_ns == mtime and std.mem.eql(u8, rec.path, path)) return rec;
    }
    return null;
}

fn joinRel(a: std.mem.Allocator, parent: []const u8, name: []const u8) ![]u8 {
    if (parent.len == 0) return a.dupe(u8, name);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ parent, name });
}

fn openNoFollow(dir: std.fs.Dir, name: []const u8) !std.fs.File {
    if (comptime builtin.os.tag == .windows) return dir.openFile(name, .{});
    const fd = try posix.openat(dir.fd, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    return .{ .handle = fd };
}

fn openRelFile(root: std.fs.Dir, rel: []const u8) !std.fs.File {
    if (!safeRel(rel)) return error.UnsafePath;
    const parent = parentOf(rel);
    var dir = try openRelDir(root, parent);
    defer if (parent.len > 0) dir.close();
    return openNoFollow(dir, std.fs.path.basename(rel));
}

fn openRelDir(root: std.fs.Dir, rel: []const u8) !std.fs.Dir {
    if (rel.len == 0) return root;
    if (!safeRel(rel)) return error.UnsafePath;
    var current = root;
    var first = true;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |comp| {
        const next = current.openDir(comp, .{ .iterate = true, .no_follow = true }) catch {
            if (!first) current.close();
            return error.NotDir;
        };
        if (!first) current.close();
        first = false;
        current = next;
    }
    return current;
}

fn ensureDir(root: std.fs.Dir, rel: []const u8) !void {
    if (rel.len == 0) return;
    if (!safeRel(rel)) return error.UnsafePath;
    var current = root;
    var first = true;
    defer if (!first) current.close();
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |comp| {
        current.makeDir(comp) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                if (!first) current.close();
                first = true;
                return err;
            },
        };
        const next = current.openDir(comp, .{ .iterate = true, .no_follow = true }) catch {
            if (!first) current.close();
            first = true;
            return error.NotDir;
        };
        if (!first) current.close();
        first = false;
        current = next;
    }
}

fn writeLink(root: std.fs.Dir, rel: []const u8, target: []const u8) !void {
    if (std.mem.indexOfScalar(u8, target, 0) != null) return error.UnsafePath;
    try ensureDir(root, parentOf(rel));
    var parent = try openRelDir(root, parentOf(rel));
    defer if (parentOf(rel).len > 0) parent.close();
    const base = std.fs.path.basename(rel);
    parent.deleteFile(base) catch {};
    parent.deleteDir(base) catch {};
    try parent.symLink(target, base, .{});
}

fn removeRel(root: std.fs.Dir, rel: []const u8, kind: Kind) !void {
    if (!safeRel(rel)) return error.UnsafePath;
    var parent = try openRelDir(root, parentOf(rel));
    defer if (parentOf(rel).len > 0) parent.close();
    const base = std.fs.path.basename(rel);
    switch (kind) {
        .dir => parent.deleteDir(base) catch {},
        else => parent.deleteFile(base) catch {},
    }
}

fn parentOf(rel: []const u8) []const u8 {
    return std.fs.path.dirname(rel) orelse "";
}

pub fn safeRel(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfAny(u8, path, "\\\x00") != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    var any = false;
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return false;
        any = true;
    }
    return any;
}

fn safeId(id: []const u8) bool {
    if (id.len == 0 or id.len > 80) return false;
    for (id) |c| {
        if (!std.ascii.isDigit(c) and c != '-') return false;
    }
    return true;
}

fn hashReader(file: std.fs.File) ![32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    return h.finalResult();
}

fn copyHash(src: std.fs.File, dst: std.fs.File) ![32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
        try dst.writeAll(buf[0..n]);
    }
    return h.finalResult();
}

fn objectRel(buf: []u8, hash: [32]u8) []const u8 {
    var hex_buf: [64]u8 = undefined;
    const hex = hexFmt(&hex_buf, hash);
    return std.fmt.bufPrint(buf, "objects/{s}/{s}", .{ hex[0..2], hex[2..] }) catch "objects/xx/x";
}

fn hexFmt(buf: *[64]u8, hash: [32]u8) []const u8 {
    const hexdigits = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        buf[i * 2] = hexdigits[b >> 4];
        buf[i * 2 + 1] = hexdigits[b & 0xf];
    }
    return buf;
}

fn hexAlloc(a: std.mem.Allocator, hash: [32]u8) ![]u8 {
    var buf: [64]u8 = undefined;
    return a.dupe(u8, hexFmt(&buf, hash));
}

fn idLess(_: void, x: []u8, y: []u8) bool {
    const xs = idStamp(x);
    const ys = idStamp(y);
    if (xs.ms != ys.ms) return xs.ms < ys.ms;
    return xs.seq < ys.seq;
}

fn idStamp(name: []const u8) struct { ms: i64, seq: u64 } {
    const dash = std.mem.indexOfScalar(u8, name, '-') orelse return .{ .ms = 0, .seq = 0 };
    const end = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    const seq_s = if (dash + 1 < end) name[dash + 1 .. end] else "";
    return .{
        .ms = std.fmt.parseInt(i64, name[0..dash], 10) catch 0,
        .seq = std.fmt.parseInt(u64, seq_s, 10) catch 0,
    };
}

fn shallowerRec(_: void, x: Rec, y: Rec) bool {
    const dx = std.mem.count(u8, x.path, "/");
    const dy = std.mem.count(u8, y.path, "/");
    if (dx != dy) return dx < dy;
    return std.mem.lessThan(u8, x.path, y.path);
}

fn deeperFirst(_: void, x: []const u8, y: []const u8) bool {
    const dx = std.mem.count(u8, x, "/");
    const dy = std.mem.count(u8, y, "/");
    if (dx != dy) return dx > dy;
    return std.mem.lessThan(u8, y, x);
}

fn findRec(files: []const Rec, path: []const u8) ?Rec {
    for (files) |r| if (std.mem.eql(u8, r.path, path)) return r;
    return null;
}

pub fn diffRecs(a: std.mem.Allocator, before: []const Rec, after: []const Rec) !Diff {
    var out = Diff{
        .added = std.ArrayList([]u8).init(a),
        .removed = std.ArrayList([]u8).init(a),
        .modified = std.ArrayList([]u8).init(a),
    };
    errdefer out.deinit(a);
    var index = std.StringHashMap(usize).init(a);
    defer index.deinit();
    for (before, 0..) |rec, i| try index.put(rec.path, i);
    var seen = try a.alloc(bool, before.len);
    defer a.free(seen);
    @memset(seen, false);
    for (after) |rec| {
        if (index.get(rec.path)) |i| {
            seen[i] = true;
            const prev = before[i];
            if (prev.kind == .unread or rec.kind == .unread) continue;
            if (changed(prev, rec)) try out.modified.append(try a.dupe(u8, rec.path));
        } else if (rec.kind != .unread) {
            try out.added.append(try a.dupe(u8, rec.path));
        }
    }
    for (before, 0..) |rec, i| {
        if (seen[i] or rec.kind == .unread) continue;
        try out.removed.append(try a.dupe(u8, rec.path));
    }
    return out;
}

fn changed(prev: Rec, next: Rec) bool {
    if (prev.kind != next.kind) return true;
    switch (prev.kind) {
        .dir, .unread => return false,
        .symlink => return !std.mem.eql(u8, prev.link, next.link),
        .file => return !std.mem.eql(u8, &prev.hash, &next.hash) or prev.mode != next.mode,
    }
}

fn writeEncoded(w: anytype, text: []const u8) !void {
    const hexdigits = "0123456789abcdef";
    for (text) |c| {
        const plain = std.ascii.isAlphanumeric(c) or c == '/' or c == '.' or c == '_' or c == '-' or c == '+';
        if (plain) {
            try w.writeByte(c);
        } else {
            try w.print("%{c}{c}", .{ hexdigits[c >> 4], hexdigits[c & 0xf] });
        }
    }
}

fn decodeAlloc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            const v = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch {
                try out.append(text[i]);
                continue;
            };
            try out.append(v);
            i += 2;
            continue;
        }
        try out.append(text[i]);
    }
    return out.toOwnedSlice();
}

fn parseManifest(a: std.mem.Allocator, id: []const u8, text: []const u8) !Snapshot {
    var files = std.ArrayList(Rec).init(a);
    errdefer {
        for (files.items) |*r| r.deinit(a);
        files.deinit();
    }
    var cwd: ?[]u8 = null;
    errdefer if (cwd) |c| a.free(c);
    var bytes: u64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    const magic = it.next() orelse return error.BadManifest;
    if (!std.mem.eql(u8, magic, "youneek-time-travel 1")) return error.BadManifest;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "cwd ")) {
            if (cwd) |c| a.free(c);
            cwd = try decodeAlloc(a, line[4..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "bytes ")) {
            bytes = std.fmt.parseInt(u64, line[6..], 10) catch return error.BadManifest;
            continue;
        }
        var cols = std.ArrayList([]const u8).init(a);
        defer cols.deinit();
        var cit = std.mem.splitScalar(u8, line, ' ');
        while (cit.next()) |c| try cols.append(c);
        if (cols.items.len < 6) return error.BadManifest;
        const kind: Kind = switch (cols.items[0][0]) {
            'f' => .file,
            'd' => .dir,
            'l' => .symlink,
            'u' => .unread,
            else => return error.BadManifest,
        };
        const mode = std.fmt.parseInt(u32, cols.items[1], 10) catch return error.BadManifest;
        const size = std.fmt.parseInt(u64, cols.items[2], 10) catch return error.BadManifest;
        const mtime = std.fmt.parseInt(i128, cols.items[3], 10) catch return error.BadManifest;
        var hash = [_]u8{0} ** 32;
        if (!std.mem.eql(u8, cols.items[4], "-")) {
            if (cols.items[4].len != 64) return error.BadManifest;
            hash = parseHex(cols.items[4]) orelse return error.BadManifest;
        }
        const path = try decodeAlloc(a, cols.items[5]);
        if (!safeRel(path)) {
            a.free(path);
            return error.UnsafePath;
        }
        const link = if (kind == .symlink and cols.items.len >= 7) try decodeAlloc(a, cols.items[6]) else try a.dupe(u8, "");
        try files.append(.{
            .path = path,
            .kind = kind,
            .mode = mode,
            .size = size,
            .mtime_ns = mtime,
            .hash = hash,
            .link = link,
        });
    }
    return .{
        .id = try a.dupe(u8, id),
        .cwd = cwd orelse return error.BadManifest,
        .bytes = bytes,
        .files = files,
    };
}

fn parseHex(text: []const u8) ?[32]u8 {
    var out: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        out[i] = std.fmt.parseInt(u8, text[i * 2 .. i * 2 + 2], 16) catch return null;
    }
    return out;
}

test "safeRel rejects escape paths" {
    try std.testing.expect(safeRel("a/b"));
    try std.testing.expect(!safeRel("../etc/passwd"));
    try std.testing.expect(!safeRel("/etc/passwd"));
    try std.testing.expect(!safeRel("a/../b"));
    try std.testing.expect(!safeRel("a//b"));
}

test "snapshot, diff, and restore stay inside the tree" {
    const a = std.testing.allocator;
    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.makeDir("outside");
    try parent.dir.makeDir("work");
    try parent.dir.writeFile(.{ .sub_path = "outside/secret", .data = "TOP-SECRET-BYTES" });
    try parent.dir.writeFile(.{ .sub_path = "work/a.txt", .data = "hello" });
    try parent.dir.makeDir("work/sub");
    try parent.dir.writeFile(.{ .sub_path = "work/sub/b.txt", .data = "bee" });
    try parent.dir.symLink("../outside/secret", "work/link", .{});
    try parent.dir.makeDir("work/node_modules");
    try parent.dir.writeFile(.{ .sub_path = "work/node_modules/pkg.js", .data = "SHOULD-NOT-SNAPSHOT" });
    try parent.dir.makePath("work/.git/objects/ab");
    try parent.dir.writeFile(.{ .sub_path = "work/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try parent.dir.writeFile(.{ .sub_path = "work/.git/objects/ab/cd", .data = "git-object-bytes" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try parent.dir.realpath(".", &root_buf);
    var work_buf: [std.fs.max_path_bytes]u8 = undefined;
    var store_buf: [std.fs.max_path_bytes]u8 = undefined;
    const work = try std.fmt.bufPrint(&work_buf, "{s}/work", .{root});
    const store_path = try std.fmt.bufPrint(&store_buf, "{s}/store", .{root});

    var store = try Store.open(a, store_path);
    defer store.deinit();
    var snap = try store.capture(work, .{ .max_bytes = 1024 * 1024, .excludes = &exclude.default_patterns });
    defer snap.deinit(a);
    try std.testing.expect(snap.saved());
    try std.testing.expect(findRec(snap.files.items, "a.txt") != null);
    try std.testing.expect(findRec(snap.files.items, "sub/b.txt") != null);
    try std.testing.expect(findRec(snap.files.items, ".git/HEAD") != null);
    try std.testing.expect(findRec(snap.files.items, ".git/objects/ab/cd") == null);
    try std.testing.expect(findRec(snap.files.items, "node_modules/pkg.js") == null);
    const link = findRec(snap.files.items, "link") orelse return error.TestExpectedEqual;
    try std.testing.expect(link.kind == .symlink);
    try std.testing.expectEqualStrings("../outside/secret", link.link);

    // The secret and the excluded file never became blobs.
    const objects = try store.root.openDir("objects", .{ .iterate = true });
    defer {
        var mut = objects;
        mut.close();
    }
    try expectNoBlob(a, store.root, "TOP-SECRET-BYTES");
    try expectNoBlob(a, store.root, "SHOULD-NOT-SNAPSHOT");
    try expectNoBlob(a, store.root, "git-object-bytes");

    // Hardlink (or a byte copy) of the blob into the snapshot tree.
    var tree_rel: [128]u8 = undefined;
    const tree_file = try std.fmt.bufPrint(&tree_rel, "snaps/{s}.tree/a.txt", .{snap.id});
    const tree_bytes = try store.root.readFileAlloc(a, tree_file, 64);
    defer a.free(tree_bytes);
    try std.testing.expectEqualStrings("hello", tree_bytes);

    try parent.dir.writeFile(.{ .sub_path = "work/a.txt", .data = "changed" });
    try parent.dir.deleteFile("work/sub/b.txt");
    try parent.dir.writeFile(.{ .sub_path = "work/c.txt", .data = "new" });
    var after = try store.scan(work, .{ .max_bytes = 1024 * 1024, .excludes = &exclude.default_patterns, .prior = snap.files.items });
    defer after.deinit(a);
    var delta = try diffRecs(a, snap.files.items, after.files.items);
    defer delta.deinit(a);
    try std.testing.expect(contains(delta.modified.items, "a.txt"));
    try std.testing.expect(contains(delta.removed.items, "sub/b.txt"));
    try std.testing.expect(contains(delta.added.items, "c.txt"));

    try store.restoreExcluding(&snap, work, &exclude.default_patterns);
    const a_now = try parent.dir.readFileAlloc(a, "work/a.txt", 64);
    defer a.free(a_now);
    try std.testing.expectEqualStrings("hello", a_now);
    const b_now = try parent.dir.readFileAlloc(a, "work/sub/b.txt", 64);
    defer a.free(b_now);
    try std.testing.expectEqualStrings("bee", b_now);
    try std.testing.expectError(error.FileNotFound, parent.dir.statFile("work/c.txt"));
    var link_buf: [128]u8 = undefined;
    const link_now = try parent.dir.readLink("work/link", &link_buf);
    try std.testing.expectEqualStrings("../outside/secret", link_now);

    // Editing the restored file must not change the stored blob.
    try parent.dir.writeFile(.{ .sub_path = "work/a.txt", .data = "mutated-after-restore" });
    const again = try store.root.readFileAlloc(a, tree_file, 64);
    defer a.free(again);
    try std.testing.expectEqualStrings("hello", again);

    // A second capture of identical bytes reuses the blob (one object file).
    try parent.dir.writeFile(.{ .sub_path = "work/a.txt", .data = "hello" });
    var snap2 = try store.capture(work, .{ .max_bytes = 1024 * 1024, .excludes = &exclude.default_patterns });
    defer snap2.deinit(a);
    const h1 = (findRec(snap.files.items, "a.txt") orelse return error.TestExpectedEqual).hash;
    const h2 = (findRec(snap2.files.items, "a.txt") orelse return error.TestExpectedEqual).hash;
    try std.testing.expect(std.mem.eql(u8, &h1, &h2));

    var reloaded = try store.load(snap.id);
    defer reloaded.deinit(a);
    try std.testing.expectEqualStrings(snap.cwd, reloaded.cwd);
    try std.testing.expect(findRec(reloaded.files.items, "sub/b.txt") != null);

    // Huge trees are skipped and write no manifest.
    var big = try parent.dir.createFile("work/big.bin", .{});
    defer big.close();
    try big.writeAll("0123456789abcdef");
    var skipped = try store.capture(work, .{ .max_bytes = 8, .excludes = &exclude.default_patterns });
    defer skipped.deinit(a);
    try std.testing.expect(skipped.skip == .too_big);
    try std.testing.expect(!skipped.saved());
}

fn contains(items: []const []const u8, needle: []const u8) bool {
    for (items) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

fn expectNoBlob(a: std.mem.Allocator, root: std.fs.Dir, needle: []const u8) !void {
    var objects = try root.openDir("objects", .{ .iterate = true });
    defer objects.close();
    var it = objects.iterate();
    while (try it.next()) |dirent| {
        if (dirent.kind != .directory) continue;
        var sub = try objects.openDir(dirent.name, .{ .iterate = true });
        defer sub.close();
        var fit = sub.iterate();
        while (try fit.next()) |fent| {
            if (fent.kind != .file) continue;
            const body = try sub.readFileAlloc(a, fent.name, 1024 * 1024);
            defer a.free(body);
            try std.testing.expect(std.mem.indexOf(u8, body, needle) == null);
        }
    }
}
