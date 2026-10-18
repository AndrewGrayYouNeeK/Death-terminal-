//! Split-pane layout of one tab: a binary tree whose leaves are panes and
//! whose inner nodes split their area side by side (`.right`) or one above
//! the other (`.down`), with a one-cell divider between the halves.
//!
//! Everything is in cells. `compute` lays the tree out over an area and
//! remembers each node's rectangle; the other queries (neighbours,
//! dividers, resizing) use the last computed layout.

const std = @import("std");

pub const PaneId = u32;

/// `.right`: the second pane is to the right (vertical divider).
/// `.down`: the second pane is below (horizontal divider).
pub const Dir = enum {
    right,
    down,

    pub fn parse(s: []const u8) ?Dir {
        if (std.mem.eql(u8, s, "right") or std.mem.eql(u8, s, "horizontal")) return .right;
        if (std.mem.eql(u8, s, "down") or std.mem.eql(u8, s, "vertical")) return .down;
        return null;
    }
};

/// Directions for focus moves and resizing.
pub const Side = enum {
    left,
    right,
    up,
    down,

    fn axis(self: Side) Dir {
        return switch (self) {
            .left, .right => .right,
            .up, .down => .down,
        };
    }
};

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,

    pub fn contains(r: Rect, x: u16, y: u16) bool {
        return x >= r.x and y >= r.y and x < @as(u32, r.x) + r.w and y < @as(u32, r.y) + r.h;
    }

    pub fn empty(r: Rect) bool {
        return r.w == 0 or r.h == 0;
    }
};

pub const NodeId = u16;
const none: NodeId = std.math.maxInt(NodeId);

pub const Node = struct {
    parent: NodeId = none,
    kind: union(enum) {
        leaf: PaneId,
        split: struct { dir: Dir, ratio: f32, a: NodeId, b: NodeId },
        free,
    },
    /// From the last `compute`.
    rect: Rect = .{},
};

pub const PaneRect = struct { pane: PaneId, rect: Rect };
pub const Divider = struct { node: NodeId, dir: Dir, rect: Rect };

pub const min_ratio: f32 = 0.05;

pub const Layout = struct {
    a: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .{},
    root: NodeId = none,
    area: Rect = .{},

    pub fn init(a: std.mem.Allocator, first_pane: PaneId) !Layout {
        var l = Layout{ .a = a };
        l.root = try l.alloc(.{ .kind = .{ .leaf = first_pane } });
        return l;
    }

    pub fn deinit(self: *Layout) void {
        self.nodes.deinit(self.a);
    }

    fn alloc(self: *Layout, n: Node) !NodeId {
        for (self.nodes.items, 0..) |*slot, i| if (slot.kind == .free) {
            slot.* = n;
            return @intCast(i);
        };
        if (self.nodes.items.len >= none - 1) return error.TooManyPanes;
        try self.nodes.append(self.a, n);
        return @intCast(self.nodes.items.len - 1);
    }

    fn node(self: *const Layout, id: NodeId) *Node {
        return &self.nodes.items[id];
    }

    pub fn leafOf(self: *const Layout, pane: PaneId) ?NodeId {
        for (self.nodes.items, 0..) |n, i| if (n.kind == .leaf and n.kind.leaf == pane) return @intCast(i);
        return null;
    }

    pub fn contains(self: *const Layout, pane: PaneId) bool {
        return self.leafOf(pane) != null;
    }

    pub fn count(self: *const Layout) usize {
        var c: usize = 0;
        for (self.nodes.items) |n| c += @intFromBool(n.kind == .leaf);
        return c;
    }

    /// Panes in reading order (left to right, top to bottom in the tree).
    pub fn panes(self: *const Layout, out: *std.ArrayList(PaneId)) !void {
        out.clearRetainingCapacity();
        if (self.root != none) try self.collect(self.root, out);
    }

    fn collect(self: *const Layout, id: NodeId, out: *std.ArrayList(PaneId)) !void {
        switch (self.node(id).kind) {
            .leaf => |p| try out.append(p),
            .split => |s| {
                try self.collect(s.a, out);
                try self.collect(s.b, out);
            },
            .free => {},
        }
    }

    pub fn first(self: *const Layout) ?PaneId {
        var id = self.root;
        if (id == none) return null;
        while (true) switch (self.node(id).kind) {
            .leaf => |p| return p,
            .split => |s| id = s.a,
            .free => return null,
        };
    }

    /// Split `pane`'s area: `new_pane` goes right of / below it.
    pub fn split(self: *Layout, pane: PaneId, dir: Dir, new_pane: PaneId, ratio: f32) !void {
        const leaf = self.leafOf(pane) orelse return error.NoSuchPane;
        const parent = self.node(leaf).parent;
        const a = try self.alloc(.{ .kind = .{ .leaf = pane } });
        errdefer self.node(a).kind = .free;
        const b = try self.alloc(.{ .kind = .{ .leaf = new_pane } });
        // The old leaf becomes the split (keeps its place in the tree).
        const n = self.node(leaf);
        n.kind = .{ .split = .{ .dir = dir, .ratio = std.math.clamp(ratio, min_ratio, 1 - min_ratio), .a = a, .b = b } };
        n.parent = parent;
        self.node(a).parent = leaf;
        self.node(b).parent = leaf;
    }

    /// Remove `pane`; its sibling takes the parent's place. Returns the
    /// pane that should get the focus (null when the layout is now empty).
    pub fn remove(self: *Layout, pane: PaneId) ?PaneId {
        const leaf = self.leafOf(pane) orelse return self.first();
        const parent = self.node(leaf).parent;
        self.node(leaf).kind = .free;
        if (parent == none) {
            self.root = none;
            return null;
        }
        const s = self.node(parent).kind.split;
        const sibling = if (s.a == leaf) s.b else s.a;
        // Move the sibling into the parent's slot.
        const keep_parent = self.node(parent).parent;
        self.node(parent).* = self.node(sibling).*;
        self.node(parent).parent = keep_parent;
        self.node(sibling).kind = .free;
        switch (self.node(parent).kind) {
            .split => |ss| {
                self.node(ss.a).parent = parent;
                self.node(ss.b).parent = parent;
            },
            else => {},
        }
        // Focus the pane nearest to where the removed one was.
        var id = parent;
        while (true) switch (self.node(id).kind) {
            .leaf => |p| return p,
            .split => |ss| id = if (s.a == leaf) ss.a else ss.b,
            .free => return self.first(),
        };
    }

    /// Lay the tree out over `area`. Dividers take one cell.
    pub fn compute(self: *Layout, area: Rect) void {
        self.area = area;
        if (self.root != none) self.place(self.root, area);
    }

    fn place(self: *Layout, id: NodeId, r: Rect) void {
        const n = self.node(id);
        n.rect = r;
        switch (n.kind) {
            .leaf, .free => {},
            .split => |s| {
                const total: u16 = if (s.dir == .right) r.w else r.h;
                const usable: u16 = total -| 1;
                var first_len: u16 = if (usable >= 2)
                    @intFromFloat(@round(@as(f32, @floatFromInt(usable)) * s.ratio))
                else
                    usable;
                if (usable >= 2) first_len = std.math.clamp(first_len, 1, usable - 1);
                const second_len: u16 = usable - first_len;
                const gap: u16 = if (total > first_len) 1 else 0;
                var ra = r;
                var rb = r;
                if (s.dir == .right) {
                    ra.w = first_len;
                    rb.x = r.x + first_len + gap;
                    rb.w = second_len;
                } else {
                    ra.h = first_len;
                    rb.y = r.y + first_len + gap;
                    rb.h = second_len;
                }
                self.place(s.a, ra);
                self.place(s.b, rb);
            },
        }
    }

    pub fn rectOf(self: *const Layout, pane: PaneId) ?Rect {
        const l = self.leafOf(pane) orelse return null;
        return self.node(l).rect;
    }

    pub fn paneRects(self: *const Layout, out: *std.ArrayList(PaneRect)) !void {
        out.clearRetainingCapacity();
        for (self.nodes.items) |n| if (n.kind == .leaf) try out.append(.{ .pane = n.kind.leaf, .rect = n.rect });
    }

    pub fn dividers(self: *const Layout, out: *std.ArrayList(Divider)) !void {
        out.clearRetainingCapacity();
        for (self.nodes.items, 0..) |n, i| if (n.kind == .split) {
            const s = n.kind.split;
            const ra = self.node(s.a).rect;
            var d = Divider{ .node = @intCast(i), .dir = s.dir, .rect = n.rect };
            if (s.dir == .right) {
                d.rect.x = ra.x + ra.w;
                d.rect.w = 1;
            } else {
                d.rect.y = ra.y + ra.h;
                d.rect.h = 1;
            }
            if (!d.rect.empty() and d.rect.x < n.rect.x + n.rect.w and d.rect.y < n.rect.y + n.rect.h) try out.append(d);
        };
    }

    /// The pane at a cell, if any.
    pub fn paneAt(self: *const Layout, x: u16, y: u16) ?PaneId {
        for (self.nodes.items) |n| if (n.kind == .leaf and n.rect.contains(x, y)) return n.kind.leaf;
        return null;
    }

    /// The divider at a cell, if any.
    pub fn dividerAt(self: *const Layout, x: u16, y: u16) ?Divider {
        for (self.nodes.items, 0..) |n, i| if (n.kind == .split) {
            const s = n.kind.split;
            const ra = self.node(s.a).rect;
            const hit = if (s.dir == .right)
                x == ra.x + ra.w and y >= n.rect.y and y < n.rect.y + n.rect.h
            else
                y == ra.y + ra.h and x >= n.rect.x and x < n.rect.x + n.rect.w;
            if (hit) return .{ .node = @intCast(i), .dir = s.dir, .rect = n.rect };
        };
        return null;
    }

    /// The pane next to `pane` on `side` (most overlap, then nearest).
    pub fn neighbor(self: *const Layout, pane: PaneId, side: Side) ?PaneId {
        const r = self.rectOf(pane) orelse return null;
        var best: ?PaneId = null;
        var best_overlap: i32 = 0;
        var best_dist: i32 = std.math.maxInt(i32);
        const rx: i32 = r.x;
        const ry: i32 = r.y;
        const rw: i32 = r.w;
        const rh: i32 = r.h;
        for (self.nodes.items) |n| if (n.kind == .leaf and n.kind.leaf != pane and !n.rect.empty()) {
            const o = n.rect;
            const ox: i32 = o.x;
            const oy: i32 = o.y;
            const ow: i32 = o.w;
            const oh: i32 = o.h;
            const dist: i32 = switch (side) {
                .right => ox - (rx + rw),
                .left => rx - (ox + ow),
                .down => oy - (ry + rh),
                .up => ry - (oy + oh),
            };
            if (dist < 0) continue;
            const overlap: i32 = switch (side) {
                .left, .right => @min(ry + rh, oy + oh) - @max(ry, oy),
                .up, .down => @min(rx + rw, ox + ow) - @max(rx, ox),
            };
            if (overlap <= 0) continue;
            if (dist < best_dist or (dist == best_dist and overlap > best_overlap)) {
                best = n.kind.leaf;
                best_dist = dist;
                best_overlap = overlap;
            }
        };
        return best;
    }

    /// Move the border of `pane` on `side` by `cells` (tmux resize-pane
    /// style: right/down grow towards that side when there is a border
    /// there, otherwise the opposite border moves). True if anything moved.
    pub fn resize(self: *Layout, pane: PaneId, side: Side, cells: u16) bool {
        var child = self.leafOf(pane) orelse return false;
        const want = side.axis();
        var fallback: ?NodeId = null;
        var parent = self.node(child).parent;
        while (parent != none) : ({
            child = parent;
            parent = self.node(parent).parent;
        }) {
            const s = self.node(parent).kind.split;
            if (s.dir != want) continue;
            const in_a = s.a == child;
            // The border on `side` exists when the pane is in `a` and the
            // side points to `b` (right/down), or vice versa.
            const border_here = (in_a and (side == .right or side == .down)) or (!in_a and (side == .left or side == .up));
            if (border_here) return self.moveDivider(parent, side, cells);
            if (fallback == null) fallback = parent;
        }
        if (fallback) |f| return self.moveDivider(f, side, cells);
        return false;
    }

    fn moveDivider(self: *Layout, id: NodeId, side: Side, cells: u16) bool {
        const n = self.node(id);
        const s = &n.kind.split;
        const total: u16 = if (s.dir == .right) n.rect.w else n.rect.h;
        const usable: f32 = @floatFromInt(@max(total -| 1, 1));
        const delta = @as(f32, @floatFromInt(cells)) / usable;
        const old = s.ratio;
        s.ratio = std.math.clamp(if (side == .right or side == .down) s.ratio + delta else s.ratio - delta, min_ratio, 1 - min_ratio);
        if (self.area.w > 0) self.compute(self.area);
        return s.ratio != old;
    }

    /// Put divider `id` at absolute cell `pos` (x for `.right`, y for `.down`).
    pub fn dragDivider(self: *Layout, id: NodeId, pos: u16) void {
        if (id >= self.nodes.items.len or self.node(id).kind != .split) return;
        const n = self.node(id);
        const s = &n.kind.split;
        const start: f32 = @floatFromInt(if (s.dir == .right) n.rect.x else n.rect.y);
        const total: u16 = if (s.dir == .right) n.rect.w else n.rect.h;
        const usable: f32 = @floatFromInt(@max(total -| 1, 1));
        s.ratio = std.math.clamp((@as(f32, @floatFromInt(pos)) - start) / usable, min_ratio, 1 - min_ratio);
        if (self.area.w > 0) self.compute(self.area);
    }

    /// Make panes in a row (column) equally wide (tall).
    pub fn equalize(self: *Layout) void {
        if (self.root != none) _ = self.even(self.root);
        if (self.area.w > 0) self.compute(self.area);
    }

    /// Returns the subtree's pane count across .right and .down.
    fn even(self: *Layout, id: NodeId) [2]f32 {
        switch (self.node(id).kind) {
            .leaf, .free => return .{ 1, 1 },
            .split => |s| {
                const ca = self.even(s.a);
                const cb = self.even(s.b);
                const k: usize = if (s.dir == .right) 0 else 1;
                self.node(id).kind.split.ratio = ca[k] / (ca[k] + cb[k]);
                var out: [2]f32 = undefined;
                out[k] = ca[k] + cb[k];
                out[1 - k] = @max(ca[1 - k], cb[1 - k]);
                return out;
            },
        }
    }
};

// ------------------------------------------------------------------- tests

const t = std.testing;

fn rect(x: u16, y: u16, w: u16, h: u16) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

test "layout: split, compute and remove" {
    var l = try Layout.init(t.allocator, 1);
    defer l.deinit();
    try l.split(1, .right, 2, 0.5);
    l.compute(rect(0, 0, 81, 24));
    try t.expectEqual(rect(0, 0, 40, 24), l.rectOf(1).?);
    try t.expectEqual(rect(41, 0, 40, 24), l.rectOf(2).?);
    try l.split(2, .down, 3, 0.5);
    l.compute(rect(0, 0, 81, 24));
    try t.expectEqual(rect(41, 0, 40, 12), l.rectOf(2).?);
    try t.expectEqual(rect(41, 13, 40, 11), l.rectOf(3).?);
    var ds = std.ArrayList(Divider).init(t.allocator);
    defer ds.deinit();
    try l.dividers(&ds);
    try t.expectEqual(@as(usize, 2), ds.items.len);
    try t.expectEqual(@as(?PaneId, 3), l.paneAt(50, 20));
    try t.expect(l.paneAt(40, 5) == null); // the divider
    try t.expect(l.dividerAt(40, 5) != null);
    try t.expect(l.dividerAt(60, 12).?.dir == .down);

    var order = std.ArrayList(PaneId).init(t.allocator);
    defer order.deinit();
    try l.panes(&order);
    try t.expectEqualSlices(PaneId, &.{ 1, 2, 3 }, order.items);

    // Removing 2: 3 takes the right half; focus goes to 3.
    try t.expectEqual(@as(?PaneId, 3), l.remove(2));
    l.compute(rect(0, 0, 81, 24));
    try t.expectEqual(rect(41, 0, 40, 24), l.rectOf(3).?);
    try t.expectEqual(@as(?PaneId, 3), l.remove(1));
    l.compute(rect(0, 0, 81, 24));
    try t.expectEqual(rect(0, 0, 81, 24), l.rectOf(3).?);
    try t.expectEqual(@as(usize, 1), l.count());
    try t.expect(l.remove(3) == null);
    try t.expectEqual(@as(usize, 0), l.count());
}

test "layout: directional focus" {
    // +---+---+
    // | 1 | 2 |
    // |   +---+
    // |   | 3 |
    // +---+---+
    // |   4   |
    var l = try Layout.init(t.allocator, 1);
    defer l.deinit();
    try l.split(1, .down, 4, 0.75);
    try l.split(1, .right, 2, 0.5);
    try l.split(2, .down, 3, 0.5);
    l.compute(rect(0, 0, 80, 40));
    try t.expectEqual(@as(?PaneId, 2), l.neighbor(1, .right));
    try t.expectEqual(@as(?PaneId, 4), l.neighbor(1, .down));
    try t.expectEqual(@as(?PaneId, 3), l.neighbor(2, .down));
    try t.expectEqual(@as(?PaneId, 4), l.neighbor(3, .down));
    try t.expectEqual(@as(?PaneId, 1), l.neighbor(3, .left));
    try t.expectEqual(@as(?PaneId, 2), l.neighbor(3, .up));
    try t.expect(l.neighbor(1, .left) == null);
    try t.expect(l.neighbor(1, .up) == null);
    // 4 spans both columns: up goes to the one overlapping most (1, 40 cols
    // vs 2/3's 39).
    try t.expectEqual(@as(?PaneId, 1), l.neighbor(4, .up));
}

test "layout: keyboard resize, divider drag, equalize, tiny areas" {
    var l = try Layout.init(t.allocator, 1);
    defer l.deinit();
    try l.split(1, .right, 2, 0.5);
    l.compute(rect(0, 0, 81, 24));
    try t.expect(l.resize(1, .right, 10));
    try t.expectEqual(@as(u16, 50), l.rectOf(1).?.w);
    // Pane 2 has no right border: its left border moves right instead.
    try t.expect(l.resize(2, .right, 10));
    try t.expectEqual(@as(u16, 60), l.rectOf(1).?.w);
    try t.expect(l.resize(2, .left, 20));
    try t.expectEqual(@as(u16, 40), l.rectOf(1).?.w);
    // No vertical split to move.
    try t.expect(!l.resize(1, .down, 3));
    // Clamped.
    _ = l.resize(1, .right, 500);
    try t.expect(l.rectOf(2).?.w >= 1);

    const d = l.dividerAt(l.rectOf(1).?.w, 3).?;
    l.dragDivider(d.node, 20);
    try t.expectEqual(@as(u16, 20), l.rectOf(1).?.w);

    // Three columns made even.
    try l.split(2, .right, 3, 0.5);
    try l.split(1, .down, 4, 0.5);
    l.equalize();
    const w1 = l.rectOf(1).?.w;
    const w2 = l.rectOf(2).?.w;
    const w3 = l.rectOf(3).?.w;
    try t.expectEqual(@as(u16, 79), w1 + w2 + w3); // 81 minus two dividers
    try t.expect(@max(w1, w2, w3) - @min(w1, w2, w3) <= 1);
    try t.expectEqual(@as(u16, 12), l.rectOf(1).?.h); // the down split is even too

    // A 2-column area cannot hold two panes plus a divider: no zero-size
    // crash, the second pane is just empty.
    l.compute(rect(0, 0, 2, 1));
    var rs = std.ArrayList(PaneRect).init(t.allocator);
    defer rs.deinit();
    try l.paneRects(&rs);
    for (rs.items) |pr| try t.expect(pr.rect.x + pr.rect.w <= 2);
}
