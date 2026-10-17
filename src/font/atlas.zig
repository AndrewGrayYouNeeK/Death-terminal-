//! CPU-side glyph atlas: premultiplied RGBA8 pixels packed with a shelf
//! allocator. Grows by doubling up to `max_size`; when it is full at the
//! maximum size the owner resets it (evicting every glyph) and re-rasterizes
//! what the next frame needs. The GPU copy is synchronised from `dirty` and
//! `generation`.

const std = @import("std");

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

const Shelf = struct { y: u32, h: u32, x: u32 };

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    size: u32,
    max_size: u32,
    /// size * size * 4 bytes, premultiplied RGBA.
    pixels: []u8,
    shelves: std.ArrayListUnmanaged(Shelf) = .{},
    /// Bumped whenever the image is reallocated or cleared; the GPU side
    /// must re-create/re-upload everything when it changes.
    generation: u32 = 1,
    /// Region written since the last `takeDirty` (null = clean).
    dirty: ?Rect = null,

    pub const padding: u32 = 1;

    pub fn init(allocator: std.mem.Allocator, initial: u32, max_size: u32) !Atlas {
        const size = @min(initial, max_size);
        const pixels = try allocator.alloc(u8, @as(usize, size) * size * 4);
        @memset(pixels, 0);
        return .{ .allocator = allocator, .size = size, .max_size = max_size, .pixels = pixels };
    }

    pub fn deinit(self: *Atlas) void {
        self.allocator.free(self.pixels);
        self.shelves.deinit(self.allocator);
        self.* = undefined;
    }

    /// Drop every glyph (keeps the current size).
    pub fn reset(self: *Atlas) void {
        @memset(self.pixels, 0);
        self.shelves.clearRetainingCapacity();
        self.generation +%= 1;
        self.dirty = null;
    }

    /// Reserve a w*h region. Returns null when it does not fit even after
    /// growing to `max_size` (caller should `reset` and retry).
    pub fn reserve(self: *Atlas, w: u32, h: u32) !?Rect {
        if (w == 0 or h == 0) return Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        while (true) {
            if (self.tryReserve(w, h)) |r| return r;
            if (self.size >= self.max_size) return null;
            try self.grow();
        }
    }

    fn tryReserve(self: *Atlas, w: u32, h: u32) ?Rect {
        const pw = w + padding;
        const ph = h + padding;
        if (pw > self.size or ph > self.size) return null;
        // Best-fit shelf: the shortest shelf that is tall enough and wastes
        // at most a third of its height.
        var best: ?usize = null;
        for (self.shelves.items, 0..) |s, i| {
            if (s.h < ph or s.x + pw > self.size) continue;
            if (s.h > ph + ph / 2 + 2) continue;
            if (best == null or s.h < self.shelves.items[best.?].h) best = i;
        }
        if (best) |i| {
            const s = &self.shelves.items[i];
            const r = Rect{ .x = s.x, .y = s.y, .w = w, .h = h };
            s.x += pw;
            return r;
        }
        var top: u32 = 0;
        for (self.shelves.items) |s| top = @max(top, s.y + s.h);
        if (top + ph > self.size) return null;
        self.shelves.append(self.allocator, .{ .y = top, .h = ph, .x = pw }) catch return null;
        return Rect{ .x = 0, .y = top, .w = w, .h = h };
    }

    /// Double the side length, keeping existing pixels in place (so
    /// already-issued rects stay valid; UVs must be renormalised).
    fn grow(self: *Atlas) !void {
        const new_size = @min(self.size * 2, self.max_size);
        const pixels = try self.allocator.alloc(u8, @as(usize, new_size) * new_size * 4);
        @memset(pixels, 0);
        var y: usize = 0;
        while (y < self.size) : (y += 1) {
            const src = self.pixels[y * self.size * 4 ..][0 .. self.size * 4];
            @memcpy(pixels[y * new_size * 4 ..][0 .. self.size * 4], src);
        }
        self.allocator.free(self.pixels);
        self.pixels = pixels;
        self.size = new_size;
        self.generation +%= 1;
        self.dirty = null;
    }

    /// Copy premultiplied RGBA rows into `r` and mark it dirty.
    pub fn write(self: *Atlas, r: Rect, rgba: []const u8) void {
        std.debug.assert(rgba.len >= @as(usize, r.w) * r.h * 4);
        var y: u32 = 0;
        while (y < r.h) : (y += 1) {
            const dst = self.pixels[((r.y + y) * self.size + r.x) * 4 ..][0 .. r.w * 4];
            @memcpy(dst, rgba[y * r.w * 4 ..][0 .. r.w * 4]);
        }
        self.markDirty(r);
    }

    /// Write single-channel coverage as (a, a, a, a).
    pub fn writeAlpha(self: *Atlas, r: Rect, alpha: []const u8) void {
        std.debug.assert(alpha.len >= @as(usize, r.w) * r.h);
        var y: u32 = 0;
        while (y < r.h) : (y += 1) {
            var x: u32 = 0;
            while (x < r.w) : (x += 1) {
                const a = alpha[y * r.w + x];
                const o = ((r.y + y) * self.size + r.x + x) * 4;
                self.pixels[o..][0..4].* = .{ a, a, a, a };
            }
        }
        self.markDirty(r);
    }

    fn markDirty(self: *Atlas, r: Rect) void {
        if (r.w == 0 or r.h == 0) return;
        if (self.dirty) |d| {
            const x0 = @min(d.x, r.x);
            const y0 = @min(d.y, r.y);
            const x1 = @max(d.x + d.w, r.x + r.w);
            const y1 = @max(d.y + d.h, r.y + r.h);
            self.dirty = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
        } else self.dirty = r;
    }

    pub fn takeDirty(self: *Atlas) ?Rect {
        const d = self.dirty;
        self.dirty = null;
        return d;
    }

    /// Premultiplied RGBA at (x, y).
    pub fn texel(self: *const Atlas, x: u32, y: u32) [4]u8 {
        const o = (@as(usize, y) * self.size + x) * 4;
        return self.pixels[o..][0..4].*;
    }
};

test "shelf packing places glyphs side by side without overlap" {
    var a = try Atlas.init(std.testing.allocator, 64, 64);
    defer a.deinit();
    const r1 = (try a.reserve(10, 12)).?;
    const r2 = (try a.reserve(10, 12)).?;
    const r3 = (try a.reserve(10, 30)).?;
    try std.testing.expectEqual(@as(u32, 0), r1.x);
    try std.testing.expectEqual(r1.y, r2.y);
    try std.testing.expect(r2.x >= r1.x + r1.w + Atlas.padding);
    try std.testing.expect(r3.y >= r1.y + r1.h); // taller glyph opens a new shelf
}

test "atlas grows and keeps existing pixels" {
    var a = try Atlas.init(std.testing.allocator, 16, 64);
    defer a.deinit();
    const r = (try a.reserve(4, 4)).?;
    a.writeAlpha(r, &([_]u8{200} ** 16));
    const gen = a.generation;
    _ = (try a.reserve(30, 30)).?;
    try std.testing.expect(a.size > 16);
    try std.testing.expect(a.generation != gen);
    try std.testing.expectEqual(@as(u8, 200), a.texel(r.x + 1, r.y + 1)[3]);
}

test "full atlas at max size reports null, reset frees space" {
    var a = try Atlas.init(std.testing.allocator, 32, 32);
    defer a.deinit();
    var n: usize = 0;
    while (try a.reserve(15, 15)) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 4), n);
    a.reset();
    try std.testing.expect((try a.reserve(15, 15)) != null);
}

test "dirty rect unions writes" {
    var a = try Atlas.init(std.testing.allocator, 32, 32);
    defer a.deinit();
    a.writeAlpha(.{ .x = 2, .y = 2, .w = 2, .h = 2 }, &([_]u8{1} ** 4));
    a.writeAlpha(.{ .x = 10, .y = 5, .w = 1, .h = 1 }, &[_]u8{1});
    const d = a.takeDirty().?;
    try std.testing.expectEqual(Rect{ .x = 2, .y = 2, .w = 9, .h = 4 }, d);
    try std.testing.expect(a.takeDirty() == null);
}
