//! Procedurally drawn sprites: box drawing (U+2500–U+257F), block elements
//! (U+2580–U+259F), braille (U+2800–U+28FF), powerline arrows
//! (U+E0B0–U+E0B3), underline styles and the missing-glyph box. Drawing
//! these ourselves keeps lines pixel-aligned and seamless between cells,
//! whatever the font does.

const std = @import("std");

/// Pseudo-codepoints for sprites that are not characters.
pub const sprite_base: u21 = 0x110000;
pub const sprite_curly: u21 = sprite_base + 1;
pub const sprite_dotted: u21 = sprite_base + 2;
pub const sprite_dashed: u21 = sprite_base + 3;
pub const sprite_missing: u21 = sprite_base + 4;

pub fn isSprite(cp: u21) bool {
    return switch (cp) {
        0x2500...0x259F, 0x2800...0x28FF, 0xE0B0...0xE0B3 => true,
        sprite_curly, sprite_dotted, sprite_dashed, sprite_missing => true,
        else => false,
    };
}

/// Line metrics shared by the box drawer and underline sprites.
pub const Metrics = struct {
    /// Cell height and the span width (cell width × columns).
    w: u32,
    h: u32,
    /// Underline centre line (px from the top) and thickness.
    underline_y: u32 = 0,
    underline_thickness: u32 = 1,
};

const Canvas = struct {
    w: u32,
    h: u32,
    buf: []u8,

    fn set(c: Canvas, x: i64, y: i64, a: u8) void {
        if (x < 0 or y < 0 or x >= c.w or y >= c.h) return;
        const i = @as(usize, @intCast(y)) * c.w + @as(usize, @intCast(x));
        c.buf[i] = @max(c.buf[i], a);
    }

    /// Fill [x0,x1) × [y0,y1) in pixels (clamped).
    fn rect(c: Canvas, x0: i64, y0: i64, x1: i64, y1: i64, a: u8) void {
        var y = @max(y0, 0);
        while (y < @min(y1, @as(i64, c.h))) : (y += 1) {
            var x = @max(x0, 0);
            while (x < @min(x1, @as(i64, c.w))) : (x += 1) c.set(x, y, a);
        }
    }

    /// Anti-aliased coverage via 4×4 supersampling of `inside(px, py)`.
    fn shade(c: Canvas, ctx: anytype, comptime inside: fn (@TypeOf(ctx), f32, f32) bool) void {
        var y: u32 = 0;
        while (y < c.h) : (y += 1) {
            var x: u32 = 0;
            while (x < c.w) : (x += 1) {
                var hits: u32 = 0;
                var sy: u32 = 0;
                while (sy < 4) : (sy += 1) {
                    var sx: u32 = 0;
                    while (sx < 4) : (sx += 1) {
                        const fx = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / 4.0;
                        const fy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / 4.0;
                        if (inside(ctx, fx, fy)) hits += 1;
                    }
                }
                if (hits > 0) c.set(x, y, @intCast(@min(255, hits * 16)));
            }
        }
    }
};

/// Light line thickness for a cell.
pub fn lightThickness(w: u32, h: u32) u32 {
    const base = @min(w, h / 2);
    return @max(1, (base + 4) / 8);
}

fn heavyThickness(light: u32) u32 {
    return if (light == 1) 2 else light * 2;
}

// Arm weights: 0 none, 1 light, 2 heavy, 3 double.
const Arms = struct { up: u2 = 0, right: u2 = 0, down: u2 = 0, left: u2 = 0 };

fn arms(u: u2, r: u2, d: u2, l: u2) Arms {
    return .{ .up = u, .right = r, .down = d, .left = l };
}

/// URDL weights for U+2500..U+254B and U+2550..U+256C, U+2574..U+257F.
fn armsFor(cp: u21) ?Arms {
    return switch (cp) {
        0x2500 => arms(0, 1, 0, 1),
        0x2501 => arms(0, 2, 0, 2),
        0x2502 => arms(1, 0, 1, 0),
        0x2503 => arms(2, 0, 2, 0),
        0x250C => arms(0, 1, 1, 0),
        0x250D => arms(0, 2, 1, 0),
        0x250E => arms(0, 1, 2, 0),
        0x250F => arms(0, 2, 2, 0),
        0x2510 => arms(0, 0, 1, 1),
        0x2511 => arms(0, 0, 1, 2),
        0x2512 => arms(0, 0, 2, 1),
        0x2513 => arms(0, 0, 2, 2),
        0x2514 => arms(1, 1, 0, 0),
        0x2515 => arms(1, 2, 0, 0),
        0x2516 => arms(2, 1, 0, 0),
        0x2517 => arms(2, 2, 0, 0),
        0x2518 => arms(1, 0, 0, 1),
        0x2519 => arms(1, 0, 0, 2),
        0x251A => arms(2, 0, 0, 1),
        0x251B => arms(2, 0, 0, 2),
        0x251C => arms(1, 1, 1, 0),
        0x251D => arms(1, 2, 1, 0),
        0x251E => arms(2, 1, 1, 0),
        0x251F => arms(1, 1, 2, 0),
        0x2520 => arms(2, 1, 2, 0),
        0x2521 => arms(2, 2, 1, 0),
        0x2522 => arms(1, 2, 2, 0),
        0x2523 => arms(2, 2, 2, 0),
        0x2524 => arms(1, 0, 1, 1),
        0x2525 => arms(1, 0, 1, 2),
        0x2526 => arms(2, 0, 1, 1),
        0x2527 => arms(1, 0, 2, 1),
        0x2528 => arms(2, 0, 2, 1),
        0x2529 => arms(2, 0, 1, 2),
        0x252A => arms(1, 0, 2, 2),
        0x252B => arms(2, 0, 2, 2),
        0x252C => arms(0, 1, 1, 1),
        0x252D => arms(0, 1, 1, 2),
        0x252E => arms(0, 2, 1, 1),
        0x252F => arms(0, 2, 1, 2),
        0x2530 => arms(0, 1, 2, 1),
        0x2531 => arms(0, 1, 2, 2),
        0x2532 => arms(0, 2, 2, 1),
        0x2533 => arms(0, 2, 2, 2),
        0x2534 => arms(1, 1, 0, 1),
        0x2535 => arms(1, 1, 0, 2),
        0x2536 => arms(1, 2, 0, 1),
        0x2537 => arms(1, 2, 0, 2),
        0x2538 => arms(2, 1, 0, 1),
        0x2539 => arms(2, 1, 0, 2),
        0x253A => arms(2, 2, 0, 1),
        0x253B => arms(2, 2, 0, 2),
        0x253C => arms(1, 1, 1, 1),
        0x253D => arms(1, 1, 1, 2),
        0x253E => arms(1, 2, 1, 1),
        0x253F => arms(1, 2, 1, 2),
        0x2540 => arms(2, 1, 1, 1),
        0x2541 => arms(1, 1, 2, 1),
        0x2542 => arms(2, 1, 2, 1),
        0x2543 => arms(2, 1, 1, 2),
        0x2544 => arms(2, 2, 1, 1),
        0x2545 => arms(1, 1, 2, 2),
        0x2546 => arms(1, 2, 2, 1),
        0x2547 => arms(2, 2, 1, 2),
        0x2548 => arms(1, 2, 2, 2),
        0x2549 => arms(2, 1, 2, 2),
        0x254A => arms(2, 2, 2, 1),
        0x254B => arms(2, 2, 2, 2),
        0x2550 => arms(0, 3, 0, 3),
        0x2551 => arms(3, 0, 3, 0),
        0x2552 => arms(0, 3, 1, 0),
        0x2553 => arms(0, 1, 3, 0),
        0x2554 => arms(0, 3, 3, 0),
        0x2555 => arms(0, 0, 1, 3),
        0x2556 => arms(0, 0, 3, 1),
        0x2557 => arms(0, 0, 3, 3),
        0x2558 => arms(1, 3, 0, 0),
        0x2559 => arms(3, 1, 0, 0),
        0x255A => arms(3, 3, 0, 0),
        0x255B => arms(1, 0, 0, 3),
        0x255C => arms(3, 0, 0, 1),
        0x255D => arms(3, 0, 0, 3),
        0x255E => arms(1, 3, 1, 0),
        0x255F => arms(3, 1, 3, 0),
        0x2560 => arms(3, 3, 3, 0),
        0x2561 => arms(1, 0, 1, 3),
        0x2562 => arms(3, 0, 3, 1),
        0x2563 => arms(3, 0, 3, 3),
        0x2564 => arms(0, 3, 1, 3),
        0x2565 => arms(0, 1, 3, 1),
        0x2566 => arms(0, 3, 3, 3),
        0x2567 => arms(1, 3, 0, 3),
        0x2568 => arms(3, 1, 0, 1),
        0x2569 => arms(3, 3, 0, 3),
        0x256A => arms(1, 3, 1, 3),
        0x256B => arms(3, 1, 3, 1),
        0x256C => arms(3, 3, 3, 3),
        0x2574 => arms(0, 0, 0, 1),
        0x2575 => arms(1, 0, 0, 0),
        0x2576 => arms(0, 1, 0, 0),
        0x2577 => arms(0, 0, 1, 0),
        0x2578 => arms(0, 0, 0, 2),
        0x2579 => arms(2, 0, 0, 0),
        0x257A => arms(0, 2, 0, 0),
        0x257B => arms(0, 0, 2, 0),
        0x257C => arms(0, 2, 0, 1),
        0x257D => arms(1, 0, 2, 0),
        0x257E => arms(0, 1, 0, 2),
        0x257F => arms(2, 0, 1, 0),
        else => null,
    };
}

const Geo = struct {
    w: i64,
    h: i64,
    cx: i64, // left edge of a centred vertical light line
    cy: i64, // top edge of a centred horizontal light line
    light: i64,
    heavy: i64,

    fn init(w: u32, h: u32) Geo {
        const light: i64 = lightThickness(w, h);
        return .{
            .w = w,
            .h = h,
            .light = light,
            .heavy = heavyThickness(@intCast(light)),
            .cx = @divFloor(@as(i64, w) - light, 2),
            .cy = @divFloor(@as(i64, h) - light, 2),
        };
    }

    fn thick(g: Geo, weight: u2) i64 {
        return if (weight == 2) g.heavy else g.light;
    }

    /// Start of a centred band of thickness t (light band starts at cx/cy).
    fn bandX(g: Geo, t: i64) i64 {
        return g.cx + @divFloor(g.light - t, 2);
    }
    fn bandY(g: Geo, t: i64) i64 {
        return g.cy + @divFloor(g.light - t, 2);
    }
};

fn drawArms(c: Canvas, a: Arms) void {
    const g = Geo.init(c.w, c.h);
    const gap = g.light; // between the two strokes of a double line
    // Double strokes sit at band ± (light + gap)/2 around the centre.
    const d_lo_x = g.cx - gap;
    const d_hi_x = g.cx + gap;
    const d_lo_y = g.cy - gap;
    const d_hi_y = g.cy + gap;

    const vert_t = @max(if (a.up != 0) g.thick(a.up) else 0, if (a.down != 0) g.thick(a.down) else 0);
    const horz_t = @max(if (a.left != 0) g.thick(a.left) else 0, if (a.right != 0) g.thick(a.right) else 0);
    const vert_double = a.up == 3 or a.down == 3;
    const horz_double = a.left == 3 or a.right == 3;

    // Horizontal arms.
    inline for (.{ .left, .right }) |side| {
        const weight = @field(a, @tagName(side));
        if (weight != 0) {
            const is_right = side == .right;
            if (weight == 3) {
                // Upper stroke meets an up arm, lower stroke meets a down arm.
                inline for (.{ .{ d_lo_y, a.up }, .{ d_hi_y, a.down } }) |pair| {
                    const y = pair[0];
                    const perp = pair[1];
                    // Stop short (inside) when a perpendicular arm is on this side,
                    // otherwise run across to the far stroke.
                    // How far past the centre this stroke reaches: across to the far
                    // stroke when nothing joins on this side, to the centre for a
                    // single join, and stopping short of a double join.
                    const reach: i64 = if (perp == 3) -gap else if (perp != 0) 0 else gap;
                    if (is_right) c.rect(g.cx - reach, y, g.w, y + g.light, 255) else c.rect(0, y, g.cx + g.light + reach, y + g.light, 255);
                }
            } else {
                const t = g.thick(weight);
                const y = g.bandY(t);
                const ext = if (vert_double) gap + g.light else @divFloor(vert_t + 1, 2);
                if (is_right) c.rect(g.cx + @divFloor(g.light, 2) - ext, y, g.w, y + t, 255) else c.rect(0, y, g.cx + @divFloor(g.light + 1, 2) + ext, y + t, 255);
            }
        }
    }
    // Vertical arms.
    inline for (.{ .up, .down }) |side| {
        const weight = @field(a, @tagName(side));
        if (weight != 0) {
            const is_down = side == .down;
            if (weight == 3) {
                inline for (.{ .{ d_lo_x, a.left }, .{ d_hi_x, a.right } }) |pair| {
                    const x = pair[0];
                    const perp = pair[1];
                    // How far past the centre this stroke reaches: across to the far
                    // stroke when nothing joins on this side, to the centre for a
                    // single join, and stopping short of a double join.
                    const reach: i64 = if (perp == 3) -gap else if (perp != 0) 0 else gap;
                    if (is_down) c.rect(x, g.cy - reach, x + g.light, g.h, 255) else c.rect(x, 0, x + g.light, g.cy + g.light + reach, 255);
                }
            } else {
                const t = g.thick(weight);
                const x = g.bandX(t);
                const ext = if (horz_double) gap + g.light else @divFloor(horz_t + 1, 2);
                if (is_down) c.rect(x, g.cy + @divFloor(g.light, 2) - ext, x + t, g.h, 255) else c.rect(x, 0, x + t, g.cy + @divFloor(g.light + 1, 2) + ext, 255);
            }
        }
    }
}

fn drawDashes(c: Canvas, horizontal: bool, heavy: bool, n: u32) void {
    const g = Geo.init(c.w, c.h);
    const t = if (heavy) g.heavy else g.light;
    const len: i64 = if (horizontal) g.w else g.h;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const seg0 = @divFloor(len * i, n);
        const seg1 = @divFloor(len * (i + 1), n);
        const gap = @max(1, @divFloor(seg1 - seg0, 3));
        const a = seg0 + @divFloor(gap, 2);
        const b = seg1 - (gap - @divFloor(gap, 2));
        if (horizontal) c.rect(a, g.bandY(t), b, g.bandY(t) + t, 255) else c.rect(g.bandX(t), a, g.bandX(t) + t, b, 255);
    }
}

const ArcCtx = struct { ox: f32, oy: f32, r: f32, half: f32, qx: f32, qy: f32 };

fn arcInside(ctx: ArcCtx, x: f32, y: f32) bool {
    // Only the quadrant facing the cell centre.
    if ((x - ctx.ox) * ctx.qx < 0 or (y - ctx.oy) * ctx.qy < 0) return false;
    const d = @sqrt((x - ctx.ox) * (x - ctx.ox) + (y - ctx.oy) * (y - ctx.oy));
    return @abs(d - ctx.r) <= ctx.half;
}

fn drawArc(c: Canvas, cp: u21) void {
    const g = Geo.init(c.w, c.h);
    const t: f32 = @floatFromInt(g.light);
    const mx = @as(f32, @floatFromInt(g.cx)) + t / 2;
    const my = @as(f32, @floatFromInt(g.cy)) + t / 2;
    const r = @min(@as(f32, @floatFromInt(c.w)), @as(f32, @floatFromInt(c.h))) / 2.0 - t / 2;
    // Arc centre offset from the cell centre toward the arms; sx/sy: arm direction.
    const sx: f32 = switch (cp) {
        0x256D, 0x2570 => 1,
        else => -1,
    };
    const sy: f32 = switch (cp) {
        0x256D, 0x256E => 1,
        else => -1,
    };
    const ctx = ArcCtx{ .ox = mx + sx * r, .oy = my + sy * r, .r = r, .half = t / 2, .qx = -sx, .qy = -sy };
    c.shade(ctx, arcInside);
    // Straight runs from the arc ends to the cell edges.
    const ax: i64 = @intFromFloat(@round(mx + sx * r));
    const ay: i64 = @intFromFloat(@round(my + sy * r));
    if (sx > 0) c.rect(ax, g.cy, g.w, g.cy + g.light, 255) else c.rect(0, g.cy, ax, g.cy + g.light, 255);
    if (sy > 0) c.rect(g.cx, ay, g.cx + g.light, g.h, 255) else c.rect(g.cx, 0, g.cx + g.light, ay, 255);
}

const DiagCtx = struct { w: f32, h: f32, half: f32, rising: bool, falling: bool };

fn diagInside(ctx: DiagCtx, x: f32, y: f32) bool {
    const len = @sqrt(ctx.w * ctx.w + ctx.h * ctx.h);
    if (ctx.rising) {
        // From bottom-left to top-right: h*x + w*y - w*h = 0
        if (@abs(ctx.h * x + ctx.w * y - ctx.w * ctx.h) / len <= ctx.half) return true;
    }
    if (ctx.falling) {
        if (@abs(ctx.h * x - ctx.w * y) / len <= ctx.half) return true;
    }
    return false;
}

fn drawBlock(c: Canvas, cp: u21) void {
    const w: i64 = c.w;
    const h: i64 = c.h;
    const eighth_h = struct {
        fn f(hh: i64, n: i64) i64 {
            return @divFloor(hh * n + 4, 8);
        }
    }.f;
    const hw = @divFloor(w, 2);
    const hh = @divFloor(h, 2);
    switch (cp) {
        0x2580 => c.rect(0, 0, w, hh, 255),
        0x2581...0x2588 => c.rect(0, h - eighth_h(h, cp - 0x2580), w, h, 255),
        0x2589...0x258F => c.rect(0, 0, eighth_h(w, 8 - (cp - 0x2588)), h, 255),
        0x2590 => c.rect(hw, 0, w, h, 255),
        0x2591 => c.rect(0, 0, w, h, 64),
        0x2592 => c.rect(0, 0, w, h, 128),
        0x2593 => c.rect(0, 0, w, h, 191),
        0x2594 => c.rect(0, 0, w, eighth_h(h, 1), 255),
        0x2595 => c.rect(w - eighth_h(w, 1), 0, w, h, 255),
        else => {
            // Quadrants: bits UL=1 UR=2 LL=4 LR=8
            const q: u4 = switch (cp) {
                0x2596 => 4,
                0x2597 => 8,
                0x2598 => 1,
                0x2599 => 1 | 4 | 8,
                0x259A => 1 | 8,
                0x259B => 1 | 2 | 4,
                0x259C => 1 | 2 | 8,
                0x259D => 2,
                0x259E => 2 | 4,
                0x259F => 2 | 4 | 8,
                else => 0,
            };
            if (q & 1 != 0) c.rect(0, 0, hw, hh, 255);
            if (q & 2 != 0) c.rect(hw, 0, w, hh, 255);
            if (q & 4 != 0) c.rect(0, hh, hw, h, 255);
            if (q & 8 != 0) c.rect(hw, hh, w, h, 255);
        },
    }
}

fn drawBraille(c: Canvas, cp: u21) void {
    const bits: u8 = @intCast(cp - 0x2800);
    const w: i64 = c.w;
    const h: i64 = c.h;
    const dot = @max(1, @divFloor(w, 4));
    // (column, row) for dots 1..8
    const pos = [8][2]u8{ .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 1, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 0, 3 }, .{ 1, 3 } };
    for (pos, 0..) |p, i| {
        if (bits & (@as(u8, 1) << @intCast(i)) == 0) continue;
        const x = @divFloor(w * (1 + 2 * @as(i64, p[0])), 4) - @divFloor(dot, 2);
        const y = @divFloor(h * (1 + 2 * @as(i64, p[1])), 8) - @divFloor(dot, 2);
        c.rect(x, y, x + dot, y + dot, 255);
    }
}

const TriCtx = struct { w: f32, h: f32, left: bool, thin: bool, half: f32 };

fn triInside(ctx: TriCtx, x0: f32, y: f32) bool {
    const x = if (ctx.left) ctx.w - x0 else x0;
    // Apex at (w, h/2); edges from (0,0) and (0,h).
    const mid = ctx.h / 2;
    const edge = @abs(y - mid) / mid; // 0 at apex row, 1 at top/bottom
    const boundary = ctx.w * (1 - edge);
    if (!ctx.thin) return x <= boundary;
    const len = @sqrt(ctx.w * ctx.w + mid * mid);
    const dist = @abs(x - boundary) * mid / len;
    return dist <= ctx.half;
}

fn drawUnderline(c: Canvas, cp: u21, m: Metrics) void {
    const t: i64 = @max(1, m.underline_thickness);
    const y0: i64 = @as(i64, m.underline_y) - @divFloor(t, 2);
    const w: i64 = c.w;
    switch (cp) {
        sprite_dotted => {
            var x: i64 = 0;
            while (x < w) : (x += 2 * t) c.rect(x, y0, x + t, y0 + t, 255);
        },
        sprite_dashed => {
            const seg = @max(2, @divFloor(w, 3));
            var x: i64 = 0;
            while (x < w) : (x += seg) c.rect(x, y0, x + @divFloor(seg * 2, 3), y0 + t, 255);
        },
        sprite_curly => {
            const Ctx = struct { w: f32, cy: f32, amp: f32, half: f32 };
            const amp = @max(1.0, @as(f32, @floatFromInt(t)) * 1.2);
            const ctx = Ctx{ .w = @floatFromInt(c.w), .cy = @floatFromInt(m.underline_y), .amp = amp, .half = @as(f32, @floatFromInt(t)) * 0.6 };
            c.shade(ctx, struct {
                fn f(k: Ctx, x: f32, y: f32) bool {
                    const yy = k.cy + k.amp * @sin(x / k.w * 2.0 * std.math.pi);
                    return @abs(y - yy) <= k.half;
                }
            }.f);
        },
        else => {},
    }
}

fn drawMissing(c: Canvas) void {
    const w: i64 = c.w;
    const h: i64 = c.h;
    const t: i64 = 1;
    const x0 = @divFloor(w, 8);
    const x1 = w - x0;
    const y0 = @divFloor(h, 6);
    const y1 = h - y0;
    c.rect(x0, y0, x1, y0 + t, 255);
    c.rect(x0, y1 - t, x1, y1, 255);
    c.rect(x0, y0, x0 + t, y1, 255);
    c.rect(x1 - t, y0, x1, y1, 255);
}

/// Render sprite `cp` as coverage into `out` (w*h bytes, zeroed here).
/// Returns false if `cp` isn't a sprite.
pub fn render(cp: u21, m: Metrics, out: []u8) bool {
    if (!isSprite(cp)) return false;
    std.debug.assert(out.len >= @as(usize, m.w) * m.h);
    @memset(out[0 .. @as(usize, m.w) * m.h], 0);
    const c = Canvas{ .w = m.w, .h = m.h, .buf = out };
    if (armsFor(cp)) |a| {
        drawArms(c, a);
        return true;
    }
    switch (cp) {
        0x2504 => drawDashes(c, true, false, 3),
        0x2505 => drawDashes(c, true, true, 3),
        0x2506 => drawDashes(c, false, false, 3),
        0x2507 => drawDashes(c, false, true, 3),
        0x2508 => drawDashes(c, true, false, 4),
        0x2509 => drawDashes(c, true, true, 4),
        0x250A => drawDashes(c, false, false, 4),
        0x250B => drawDashes(c, false, true, 4),
        0x254C => drawDashes(c, true, false, 2),
        0x254D => drawDashes(c, true, true, 2),
        0x254E => drawDashes(c, false, false, 2),
        0x254F => drawDashes(c, false, true, 2),
        0x256D...0x2570 => drawArc(c, cp),
        0x2571...0x2573 => {
            const g = Geo.init(m.w, m.h);
            c.shade(DiagCtx{
                .w = @floatFromInt(m.w),
                .h = @floatFromInt(m.h),
                .half = @as(f32, @floatFromInt(g.light)) / 2.0 + 0.15,
                .rising = cp != 0x2572,
                .falling = cp != 0x2571,
            }, diagInside);
        },
        0x2580...0x259F => drawBlock(c, cp),
        0x2800...0x28FF => drawBraille(c, cp),
        0xE0B0...0xE0B3 => {
            const g = Geo.init(m.w, m.h);
            c.shade(TriCtx{
                .w = @floatFromInt(m.w),
                .h = @floatFromInt(m.h),
                .left = cp == 0xE0B2 or cp == 0xE0B3,
                .thin = cp == 0xE0B1 or cp == 0xE0B3,
                .half = @as(f32, @floatFromInt(g.light)) / 2.0 + 0.2,
            }, triInside);
        },
        sprite_curly, sprite_dotted, sprite_dashed => drawUnderline(c, cp, m),
        sprite_missing => drawMissing(c),
        else => return false,
    }
    return true;
}

fn testRender(cp: u21, w: u32, h: u32) ![]u8 {
    const buf = try std.testing.allocator.alloc(u8, w * h);
    try std.testing.expect(render(cp, .{ .w = w, .h = h }, buf));
    return buf;
}

test "horizontal line spans the full width at the centre and nothing else" {
    const b = try testRender(0x2500, 10, 20);
    defer std.testing.allocator.free(b);
    var row: u32 = 0;
    var lit_rows: u32 = 0;
    while (row < 20) : (row += 1) {
        const line = b[row * 10 ..][0..10];
        if (line[0] == 255) {
            lit_rows += 1;
            for (line) |px| try std.testing.expectEqual(@as(u8, 255), px);
            try std.testing.expect(row >= 8 and row <= 11);
        }
    }
    try std.testing.expectEqual(@as(u32, 1), lit_rows);
}

test "vertical lines in adjacent rows join seamlessly" {
    const b = try testRender(0x2502, 9, 18);
    defer std.testing.allocator.free(b);
    // Same column lit in the first and last rows -> continuous across cells.
    var x: u32 = 0;
    while (x < 9) : (x += 1) try std.testing.expectEqual(b[x], b[17 * 9 + x]);
    try std.testing.expect(std.mem.indexOfScalar(u8, b[0..9], 255) != null);
}

test "corner connects right and down arms only" {
    const b = try testRender(0x250C, 10, 20);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u8, 0), b[0]); // top-left empty
    try std.testing.expect(std.mem.indexOfScalar(u8, b[19 * 10 ..][0..10], 255) != null); // reaches bottom
    try std.testing.expectEqual(@as(u8, 0), b[19 * 10]); // not at left edge
    var reaches_right = false;
    var row: u32 = 0;
    while (row < 20) : (row += 1) {
        if (b[row * 10 + 9] == 255) reaches_right = true;
    }
    try std.testing.expect(reaches_right);
}

test "heavy line is thicker than light" {
    const l = try testRender(0x2500, 10, 20);
    defer std.testing.allocator.free(l);
    const hv = try testRender(0x2501, 10, 20);
    defer std.testing.allocator.free(hv);
    var nl: u32 = 0;
    var nh: u32 = 0;
    for (l) |p| nl += @intFromBool(p == 255);
    for (hv) |p| nh += @intFromBool(p == 255);
    try std.testing.expect(nh > nl);
}

test "full block fills, half blocks fill halves, shades are uniform" {
    const full = try testRender(0x2588, 8, 16);
    defer std.testing.allocator.free(full);
    for (full) |p| try std.testing.expectEqual(@as(u8, 255), p);
    const upper = try testRender(0x2580, 8, 16);
    defer std.testing.allocator.free(upper);
    try std.testing.expectEqual(@as(u8, 255), upper[0]);
    try std.testing.expectEqual(@as(u8, 0), upper[15 * 8]);
    const shade = try testRender(0x2592, 8, 16);
    defer std.testing.allocator.free(shade);
    for (shade) |p| try std.testing.expectEqual(@as(u8, 128), p);
}

test "double line draws two strokes" {
    const b = try testRender(0x2550, 10, 20);
    defer std.testing.allocator.free(b);
    var strokes: u32 = 0;
    var prev: u8 = 0;
    var row: u32 = 0;
    while (row < 20) : (row += 1) {
        const v = b[row * 10 + 5];
        if (v == 255 and prev != 255) strokes += 1;
        prev = v;
    }
    try std.testing.expectEqual(@as(u32, 2), strokes);
}

test "braille dots and arcs render something" {
    const br = try testRender(0x28FF, 8, 16);
    defer std.testing.allocator.free(br);
    var n: u32 = 0;
    for (br) |p| n += @intFromBool(p > 0);
    try std.testing.expect(n >= 8);
    const arc = try testRender(0x256D, 10, 20);
    defer std.testing.allocator.free(arc);
    try std.testing.expect(arc[19 * 10 + 4] > 0 or arc[19 * 10 + 5] > 0); // reaches bottom near centre
}

test "non-sprites are rejected" {
    var buf: [4]u8 = undefined;
    try std.testing.expect(!render('A', .{ .w = 2, .h = 2 }, &buf));
    try std.testing.expect(isSprite(0x2500));
    try std.testing.expect(!isSprite(0x2600));
}
