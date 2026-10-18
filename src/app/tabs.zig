//! Tabs of a window: each has a split layout, a focused pane and an
//! optional zoom. Also the tab bar's geometry (pure, for drawing and
//! hit-testing).

const std = @import("std");
const layout = @import("layout.zig");
pub const PaneId = layout.PaneId;

pub const TabId = u32;

pub const Tab = struct {
    id: TabId,
    layout: layout.Layout,
    focused: PaneId,
    /// The focused pane fills the tab.
    zoomed: bool = false,
    /// Set by renaming (owned); null = use the focused pane's title.
    name: ?[]u8 = null,

    pub fn setName(self: *Tab, a: std.mem.Allocator, name: ?[]const u8) !void {
        const n: ?[]u8 = if (name) |s| (if (s.len == 0) null else try a.dupe(u8, s[0..@min(s.len, 64)])) else null;
        if (self.name) |old| a.free(old);
        self.name = n;
    }
};

pub const TabSet = struct {
    a: std.mem.Allocator,
    tabs: std.ArrayListUnmanaged(*Tab) = .{},
    active: usize = 0,
    next_tab: TabId = 1,
    next_pane: PaneId = 1,

    pub fn init(a: std.mem.Allocator) TabSet {
        return .{ .a = a };
    }

    pub fn deinit(self: *TabSet) void {
        for (self.tabs.items) |tab| self.freeTab(tab);
        self.tabs.deinit(self.a);
    }

    fn freeTab(self: *TabSet, tab: *Tab) void {
        tab.layout.deinit();
        if (tab.name) |n| self.a.free(n);
        self.a.destroy(tab);
    }

    pub fn newPaneId(self: *TabSet) PaneId {
        const id = self.next_pane;
        self.next_pane += 1;
        return id;
    }

    /// A tab holding `pane`, inserted after the active one (or at the end)
    /// and made active.
    pub fn add(self: *TabSet, pane: PaneId, after_active: bool) !*Tab {
        const tab = try self.a.create(Tab);
        errdefer self.a.destroy(tab);
        tab.* = .{ .id = self.next_tab, .layout = try layout.Layout.init(self.a, pane), .focused = pane };
        errdefer tab.layout.deinit();
        const at = if (after_active and self.tabs.items.len > 0) self.active + 1 else self.tabs.items.len;
        try self.tabs.insert(self.a, at, tab);
        self.next_tab += 1;
        self.active = at;
        return tab;
    }

    pub fn current(self: *const TabSet) ?*Tab {
        if (self.tabs.items.len == 0) return null;
        return self.tabs.items[self.active];
    }

    pub fn indexOf(self: *const TabSet, id: TabId) ?usize {
        for (self.tabs.items, 0..) |tab, i| if (tab.id == id) return i;
        return null;
    }

    /// The tab containing `pane`.
    pub fn tabOf(self: *const TabSet, pane: PaneId) ?*Tab {
        for (self.tabs.items) |tab| if (tab.layout.contains(pane)) return tab;
        return null;
    }

    /// Remove tab `index` (its panes must already be gone or closed by the
    /// caller). The tab to its left becomes active, like most terminals.
    pub fn remove(self: *TabSet, index: usize) void {
        if (index >= self.tabs.items.len) return;
        self.freeTab(self.tabs.orderedRemove(index));
        if (self.tabs.items.len == 0) {
            self.active = 0;
        } else if (index < self.active or self.active >= self.tabs.items.len) {
            self.active -|= 1;
        }
    }

    pub fn select(self: *TabSet, index: usize) void {
        if (index < self.tabs.items.len) self.active = index;
    }

    pub fn cycle(self: *TabSet, delta: i32) void {
        const n: i32 = @intCast(self.tabs.items.len);
        if (n == 0) return;
        self.active = @intCast(@mod(@as(i32, @intCast(self.active)) + delta, n));
    }

    /// Move tab `from` to position `to` (the active tab follows its tab).
    pub fn move(self: *TabSet, from: usize, to_in: usize) void {
        const n = self.tabs.items.len;
        if (from >= n) return;
        const to = @min(to_in, n - 1);
        if (from == to) return;
        const active_tab = self.tabs.items[self.active];
        const tab = self.tabs.orderedRemove(from);
        self.tabs.insertAssumeCapacity(to, tab);
        for (self.tabs.items, 0..) |x, i| if (x == active_tab) {
            self.active = i;
        };
    }
};

// ----------------------------------------------------------- tab bar

pub const Slot = struct {
    x: u16,
    w: u16,
    /// Column of the close button ("×"), inside the slot.
    close_x: u16,
};

pub const Bar = struct {
    slots: [max_slots]Slot = undefined,
    n: usize = 0,
    /// Column of the "+" (new tab) button, if it fits.
    plus_x: ?u16 = null,
    /// First tab shown (the bar scrolls to keep the active tab visible).
    first: usize = 0,

    pub const max_slots = 64;
    pub const min_w = 8;
    pub const max_w = 32;

    pub const Hit = union(enum) { none, tab: usize, close: usize, new_tab };

    pub fn hit(self: *const Bar, x: u16) Hit {
        for (self.slots[0..self.n], 0..) |s, i| {
            if (x >= s.x and x < s.x + s.w) {
                return if (x == s.close_x or x == s.close_x + 1) .{ .close = self.first + i } else .{ .tab = self.first + i };
            }
        }
        if (self.plus_x) |p| if (x >= p and x < p + 3) return .new_tab;
        return .none;
    }
};

/// Lay out `n` tabs whose labels want `want[i]` columns over `cols`.
/// Every tab gets the same width (between min_w and max_w); when they don't
/// all fit, a window around `active` is shown.
pub fn layoutBar(want: []const u16, active: usize, cols: u16) Bar {
    var bar = Bar{};
    const n = @min(want.len, Bar.max_slots);
    if (n == 0 or cols < Bar.min_w) return bar;
    const plus_room: u16 = 3;
    const room: u16 = cols -| plus_room;
    var longest: u16 = 0;
    for (want[0..n]) |w| longest = @max(longest, w);
    var w: u16 = std.math.clamp(longest + 4, Bar.min_w, Bar.max_w);
    const fit_all = @as(usize, w) * n <= room;
    if (!fit_all) w = @max(Bar.min_w, @as(u16, @intCast(room / n)));
    const visible: usize = @max(1, @min(n, room / w));
    var first: usize = 0;
    if (active >= visible) first = active + 1 - visible;
    bar.first = first;
    var x: u16 = 0;
    var i: usize = first;
    while (i < n and i < first + visible) : (i += 1) {
        bar.slots[bar.n] = .{ .x = x, .w = w, .close_x = x + w - 3 };
        bar.n += 1;
        x += w;
    }
    if (x + plus_room <= cols) bar.plus_x = x;
    return bar;
}

// ------------------------------------------------------------------- tests

const t = std.testing;

test "tabs: add, cycle, move, remove keeps a sensible active tab" {
    var ts = TabSet.init(t.allocator);
    defer ts.deinit();
    const p1 = ts.newPaneId();
    _ = try ts.add(p1, true);
    _ = try ts.add(ts.newPaneId(), true);
    _ = try ts.add(ts.newPaneId(), true);
    try t.expectEqual(@as(usize, 2), ts.active);
    ts.select(0);
    _ = try ts.add(ts.newPaneId(), true); // inserted after tab 0
    try t.expectEqual(@as(usize, 1), ts.active);
    try t.expectEqual(@as(TabId, 4), ts.current().?.id);
    ts.cycle(-1);
    try t.expectEqual(@as(usize, 0), ts.active);
    ts.cycle(-1);
    try t.expectEqual(@as(usize, 3), ts.active);
    ts.cycle(1);
    try t.expectEqual(@as(usize, 0), ts.active);
    // Moving the active tab: the selection follows it.
    ts.move(0, 3);
    try t.expectEqual(@as(usize, 3), ts.active);
    try t.expectEqual(@as(TabId, 1), ts.current().?.id);
    try t.expect(ts.tabOf(p1).?.id == 1);
    ts.remove(3);
    try t.expectEqual(@as(usize, 2), ts.active);
    ts.remove(0);
    try t.expectEqual(@as(usize, 1), ts.active);
    try ts.current().?.setName(t.allocator, "build");
    try t.expectEqualStrings("build", ts.current().?.name.?);
    ts.remove(0);
    ts.remove(0);
    try t.expect(ts.current() == null);
}

test "tab bar: widths, scrolling and hits" {
    const want = [_]u16{ 5, 12, 40 };
    const b = layoutBar(&want, 0, 120);
    try t.expectEqual(@as(usize, 3), b.n);
    try t.expectEqual(@as(u16, Bar.max_w), b.slots[0].w);
    try t.expect(b.hit(1) == .tab);
    try t.expectEqual(@as(usize, 1), b.hit(b.slots[1].x + 2).tab);
    try t.expectEqual(@as(usize, 2), b.hit(b.slots[2].close_x).close);
    try t.expect(b.hit(b.plus_x.? + 1) == .new_tab);
    try t.expect(b.hit(119) == .none);

    // 20 tabs in 60 columns: the bar scrolls to the active one.
    var many: [20]u16 = undefined;
    @memset(&many, 10);
    const s = layoutBar(&many, 19, 60);
    try t.expect(s.n >= 1 and s.n < 20);
    try t.expectEqual(@as(usize, 19), s.first + s.n - 1);
    try t.expectEqual(@as(usize, 19), s.hit(s.slots[s.n - 1].x).tab);
    try t.expectEqual(@as(usize, 0), layoutBar(&many, 0, 4).n);
}
