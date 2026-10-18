//! VT500-style escape sequence parser (after Paul Williams' state machine).
//!
//! The parser only tokenizes; `terminal.zig` interprets the actions. It
//! decodes UTF-8 in the ground state, executes C0 controls inline (also in
//! the middle of CSI sequences, like real terminals), and swallows DCS / SOS
//! / PM / APC strings so their payload never reaches the screen.

const std = @import("std");
const unicode = @import("unicode.zig");

pub const ParserState = enum {
    Ground,
    Escape,
    EscapeIntermediate,
    CSI,
    CSIIgnore,
    OSC,
    OSCEscape,
    /// DCS, SOS, PM and APC payloads: ignored until ST.
    IgnoreString,
    IgnoreStringEscape,
};

pub const MAX_PARAMS = 32;
/// OSC payloads longer than this are dropped (titles, hyperlinks, ...).
pub const MAX_OSC_LEN = 1 << 20; // room for OSC 52 clipboard payloads

/// CSI parameters. Sub-parameters (`38:2::r:g:b`) are stored inline and
/// flagged in `colon_mask` (bit i set = param i followed a ':').
pub const CSIParams = struct {
    params: [MAX_PARAMS]u32,
    param_count: u8,
    colon_mask: u32,
    /// Private marker: '?', '>', '=', '<' or 0.
    private: u8,
    /// Last intermediate byte (0x20..0x2F) or 0.
    intermediate: u8,

    pub fn init() CSIParams {
        return .{
            .params = [_]u32{0} ** MAX_PARAMS,
            .param_count = 0,
            .colon_mask = 0,
            .private = 0,
            .intermediate = 0,
        };
    }

    pub fn addParam(self: *CSIParams, param: u32, after_colon: bool) void {
        if (self.param_count < MAX_PARAMS) {
            self.params[self.param_count] = param;
            if (after_colon) self.colon_mask |= @as(u32, 1) << @intCast(self.param_count);
            self.param_count += 1;
        }
    }

    /// Param `index`, or `default` when absent.
    pub fn getParam(self: CSIParams, index: u8, default: u32) u32 {
        if (index < self.param_count) return self.params[index];
        return default;
    }

    /// Param `index`, or `default` when absent or zero (cursor counts etc.).
    pub fn getNonZero(self: CSIParams, index: u8, default: u32) u32 {
        const v = self.getParam(index, 0);
        return if (v == 0) default else v;
    }

    pub fn isSub(self: CSIParams, index: u8) bool {
        if (index >= MAX_PARAMS) return false;
        return (self.colon_mask >> @intCast(index)) & 1 != 0;
    }
};

pub const Action = union(enum) {
    /// Printable codepoint.
    Print: u21,
    /// C0 control (BEL, BS, HT, LF, VT, FF, CR, SO, SI, ...).
    Execute: u8,
    /// ESC [intermediate] final.
    Esc: struct { intermediate: u8, final: u8 },
    CSI: struct { params: CSIParams, final_byte: u8 },
    /// OSC payload. Borrowed from the parser; valid until the next `advance`.
    OSC: []const u8,
};

pub const Parser = struct {
    state: ParserState,
    params: CSIParams,
    osc_buffer: std.ArrayList(u8),
    osc_overflow: bool = false,
    current_param: u32,
    saw_digit: bool,
    next_is_sub: bool = false,
    esc_intermediate: u8 = 0,
    allocator: std.mem.Allocator,
    utf8_cp: u21 = 0,
    utf8_need: u2 = 0,
    utf8_lo: u8 = 0x80,
    utf8_hi: u8 = 0xBF,
    /// Second action produced by one byte: when a byte interrupts a UTF-8
    /// sequence, `advance` returns U+FFFD and the byte's own action lands
    /// here. Drain with `takePending` after every `advance`.
    pending: ?Action = null,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .state = .Ground,
            .params = CSIParams.init(),
            .osc_buffer = std.ArrayList(u8).init(allocator),
            .current_param = 0,
            .saw_digit = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.osc_buffer.deinit();
    }

    pub fn reset(self: *Parser) void {
        self.state = .Ground;
        self.clearParams();
        self.osc_buffer.clearRetainingCapacity();
        self.utf8_need = 0;
        self.pending = null;
    }

    pub fn takePending(self: *Parser) ?Action {
        const a = self.pending;
        self.pending = null;
        return a;
    }

    fn clearParams(self: *Parser) void {
        self.params = CSIParams.init();
        self.current_param = 0;
        self.saw_digit = false;
        self.next_is_sub = false;
    }

    /// Feed one byte; returns a completed action, if any.
    pub fn advance(self: *Parser, byte: u8) !?Action {
        // CAN and SUB abort any sequence; ESC always starts a new one.
        if (self.state != .Ground) {
            if (byte == 0x18 or byte == 0x1A) {
                self.state = .Ground;
                return null;
            }
            if (byte == 0x1B and self.state != .OSC and self.state != .IgnoreString) {
                self.enterEscape();
                return null;
            }
        }
        return switch (self.state) {
            .Ground => self.handleGround(byte),
            .Escape => self.handleEscape(byte),
            .EscapeIntermediate => self.handleEscapeIntermediate(byte),
            .CSI => self.handleCSI(byte),
            .CSIIgnore => self.handleCSIIgnore(byte),
            .OSC => self.handleOSC(byte),
            .OSCEscape => self.handleOSCEscape(byte),
            .IgnoreString => self.handleIgnoreString(byte),
            .IgnoreStringEscape => self.handleIgnoreStringEscape(byte),
        };
    }

    fn enterEscape(self: *Parser) void {
        self.state = .Escape;
        self.esc_intermediate = 0;
    }

    fn handleGround(self: *Parser, byte: u8) !?Action {
        if (self.utf8_need > 0) {
            if (byte >= self.utf8_lo and byte <= self.utf8_hi) {
                self.utf8_cp = (self.utf8_cp << 6) | @as(u21, byte & 0x3F);
                self.utf8_need -= 1;
                self.utf8_lo = 0x80;
                self.utf8_hi = 0xBF;
                if (self.utf8_need == 0) return Action{ .Print = self.utf8_cp };
                return null;
            }
            // Truncated sequence: emit U+FFFD, then process this byte afresh.
            self.utf8_need = 0;
            self.pending = self.groundStart(byte);
            return Action{ .Print = unicode.replacement_char };
        }
        return self.groundStart(byte);
    }

    fn beginUtf8(self: *Parser, bits: u21, need: u2, lo: u8, hi: u8) ?Action {
        self.utf8_cp = bits;
        self.utf8_need = need;
        self.utf8_lo = lo;
        self.utf8_hi = hi;
        return null;
    }

    fn groundStart(self: *Parser, byte: u8) ?Action {
        return switch (byte) {
            0x1B => {
                self.enterEscape();
                return null;
            },
            0x00...0x1A, 0x1C...0x1F => Action{ .Execute = byte },
            0x20...0x7E => Action{ .Print = byte },
            0x7F => null, // DEL is ignored
            // Lead bytes, with the valid range of the second byte so overlong
            // forms and surrogates are rejected (RFC 3629).
            0xC2...0xDF => self.beginUtf8(byte & 0x1F, 1, 0x80, 0xBF),
            0xE0 => self.beginUtf8(byte & 0x0F, 2, 0xA0, 0xBF),
            0xE1...0xEC, 0xEE, 0xEF => self.beginUtf8(byte & 0x0F, 2, 0x80, 0xBF),
            0xED => self.beginUtf8(byte & 0x0F, 2, 0x80, 0x9F),
            0xF0 => self.beginUtf8(byte & 0x07, 3, 0x90, 0xBF),
            0xF1...0xF3 => self.beginUtf8(byte & 0x07, 3, 0x80, 0xBF),
            0xF4 => self.beginUtf8(byte & 0x07, 3, 0x80, 0x8F),
            // Stray continuation bytes, C0/C1 overlong leads, F5..FF.
            0x80...0xC1, 0xF5...0xFF => Action{ .Print = unicode.replacement_char },
        };
    }

    fn handleEscape(self: *Parser, byte: u8) !?Action {
        switch (byte) {
            0x00...0x17, 0x19, 0x1C...0x1F => return Action{ .Execute = byte },
            0x20...0x2F => {
                self.esc_intermediate = byte;
                self.state = .EscapeIntermediate;
                return null;
            },
            '[' => {
                self.clearParams();
                self.state = .CSI;
                return null;
            },
            ']' => {
                self.osc_buffer.clearRetainingCapacity();
                self.osc_overflow = false;
                self.state = .OSC;
                return null;
            },
            'P', 'X', '^', '_' => {
                self.state = .IgnoreString;
                return null;
            },
            0x30...0x4F, 0x51...0x57, 0x59, 0x5A, 0x5C, 0x60...0x7E => {
                self.state = .Ground;
                return Action{ .Esc = .{ .intermediate = 0, .final = byte } };
            },
            else => {
                self.state = .Ground;
                return null;
            },
        }
    }

    fn handleEscapeIntermediate(self: *Parser, byte: u8) !?Action {
        switch (byte) {
            0x00...0x17, 0x19, 0x1C...0x1F => return Action{ .Execute = byte },
            0x20...0x2F => {
                self.esc_intermediate = byte;
                return null;
            },
            0x30...0x7E => {
                self.state = .Ground;
                return Action{ .Esc = .{ .intermediate = self.esc_intermediate, .final = byte } };
            },
            else => {
                self.state = .Ground;
                return null;
            },
        }
    }

    fn finishParam(self: *Parser) void {
        self.params.addParam(self.current_param, self.next_is_sub);
        self.current_param = 0;
        self.saw_digit = false;
    }

    fn handleCSI(self: *Parser, byte: u8) !?Action {
        switch (byte) {
            0x00...0x17, 0x19, 0x1C...0x1F => return Action{ .Execute = byte },
            '0'...'9' => {
                if (self.params.intermediate != 0) {
                    self.state = .CSIIgnore;
                    return null;
                }
                self.current_param = std.math.mul(u32, self.current_param, 10) catch 65535;
                self.current_param = @min(65535, self.current_param + (byte - '0'));
                self.saw_digit = true;
                return null;
            },
            ';', ':' => {
                if (self.params.intermediate != 0) {
                    self.state = .CSIIgnore;
                    return null;
                }
                self.finishParam();
                self.next_is_sub = byte == ':';
                return null;
            },
            '<'...'?' => {
                // Private marker: only valid before any parameter.
                if (self.saw_digit or self.params.param_count > 0 or self.params.private != 0 or self.params.intermediate != 0) {
                    self.state = .CSIIgnore;
                    return null;
                }
                self.params.private = byte;
                return null;
            },
            0x20...0x2F => {
                self.params.intermediate = byte;
                return null;
            },
            0x40...0x7E => {
                if (self.saw_digit or self.params.param_count > 0) self.finishParam();
                const action = Action{ .CSI = .{ .params = self.params, .final_byte = byte } };
                self.state = .Ground;
                self.clearParams();
                return action;
            },
            else => return null, // DEL and high bytes are ignored
        }
    }

    fn handleCSIIgnore(self: *Parser, byte: u8) !?Action {
        switch (byte) {
            0x00...0x17, 0x19, 0x1C...0x1F => return Action{ .Execute = byte },
            0x40...0x7E => self.state = .Ground,
            else => {},
        }
        return null;
    }

    fn handleOSC(self: *Parser, byte: u8) !?Action {
        switch (byte) {
            0x07 => return self.finishOSC(),
            0x1B => {
                self.state = .OSCEscape;
                return null;
            },
            0x00...0x06, 0x08...0x1A, 0x1C...0x1F => return null,
            else => {
                if (self.osc_buffer.items.len >= MAX_OSC_LEN) {
                    self.osc_overflow = true;
                } else {
                    try self.osc_buffer.append(byte);
                }
                return null;
            },
        }
    }

    fn finishOSC(self: *Parser) ?Action {
        self.state = .Ground;
        if (self.osc_overflow) return null;
        return Action{ .OSC = self.osc_buffer.items };
    }

    fn handleOSCEscape(self: *Parser, byte: u8) !?Action {
        if (byte == '\\') return self.finishOSC();
        // Any other byte aborts the OSC and starts a new escape sequence.
        self.enterEscape();
        return self.handleEscape(byte);
    }

    fn handleIgnoreString(self: *Parser, byte: u8) !?Action {
        if (byte == 0x1B) self.state = .IgnoreStringEscape;
        return null;
    }

    fn handleIgnoreStringEscape(self: *Parser, byte: u8) !?Action {
        if (byte == '\\') {
            self.state = .Ground;
            return null;
        }
        self.enterEscape();
        return self.handleEscape(byte);
    }
};

// ---------------------------------------------------------------- tests

fn feed(parser: *Parser, bytes: []const u8, out: *std.ArrayList(Action)) !void {
    for (bytes) |b| {
        if (try parser.advance(b)) |a| try out.append(a);
        if (parser.takePending()) |a| try out.append(a);
    }
}

fn collectPrints(parser: *Parser, bytes: []const u8, out: *std.ArrayList(u21)) !void {
    for (bytes) |b| {
        if (try parser.advance(b)) |a| if (a == .Print) try out.append(a.Print);
        if (parser.takePending()) |a| if (a == .Print) try out.append(a.Print);
    }
}

test "Parser basic" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    const action = try parser.advance('A');
    try testing.expectEqual(@as(u21, 'A'), action.?.Print);
}

test "Parser CSI cursor position" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var out = std.ArrayList(Action).init(testing.allocator);
    defer out.deinit();
    try feed(&parser, "\x1b[1;2H", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const csi = out.items[0].CSI;
    try testing.expectEqual(@as(u8, 'H'), csi.final_byte);
    try testing.expectEqual(@as(u32, 1), csi.params.getParam(0, 0));
    try testing.expectEqual(@as(u32, 2), csi.params.getParam(1, 0));
}

test "Parser CSI defaults, empty and zero params" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var out = std.ArrayList(Action).init(testing.allocator);
    defer out.deinit();
    try feed(&parser, "\x1b[H\x1b[;5H\x1b[0A", &out);
    try testing.expectEqual(@as(u8, 0), out.items[0].CSI.params.param_count);
    try testing.expectEqual(@as(u32, 1), out.items[1].CSI.params.getNonZero(0, 1));
    try testing.expectEqual(@as(u32, 5), out.items[1].CSI.params.getNonZero(1, 1));
    try testing.expectEqual(@as(u32, 1), out.items[2].CSI.params.getNonZero(0, 1));
}

test "Parser private marker and intermediate" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var out = std.ArrayList(Action).init(testing.allocator);
    defer out.deinit();
    try feed(&parser, "\x1b[?2004h\x1b[5 q\x1b[>c", &out);
    try testing.expectEqual(@as(u8, '?'), out.items[0].CSI.params.private);
    try testing.expectEqual(@as(u32, 2004), out.items[0].CSI.params.getParam(0, 0));
    try testing.expectEqual(@as(u8, ' '), out.items[1].CSI.params.intermediate);
    try testing.expectEqual(@as(u8, 'q'), out.items[1].CSI.final_byte);
    try testing.expectEqual(@as(u8, '>'), out.items[2].CSI.params.private);
}

test "Parser colon sub-parameters" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var out = std.ArrayList(Action).init(testing.allocator);
    defer out.deinit();
    try feed(&parser, "\x1b[38:2::10:20:30m", &out);
    const p = out.items[0].CSI.params;
    try testing.expectEqual(@as(u8, 6), p.param_count);
    try testing.expect(!p.isSub(0));
    try testing.expect(p.isSub(1) and p.isSub(5));
    try testing.expectEqual(@as(u32, 30), p.getParam(5, 0));
}

test "Parser huge params saturate instead of overflowing" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var out = std.ArrayList(Action).init(testing.allocator);
    defer out.deinit();
    try feed(&parser, "\x1b[99999999999999999999A", &out);
    try testing.expectEqual(@as(u32, 65535), out.items[0].CSI.params.getParam(0, 0));
}

test "Parser executes C0 inside CSI" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var out = std.ArrayList(Action).init(testing.allocator);
    defer out.deinit();
    try feed(&parser, "\x1b[1\r;2H", &out);
    try testing.expectEqual(@as(u8, '\r'), out.items[0].Execute);
    try testing.expectEqual(@as(u32, 2), out.items[1].CSI.params.getParam(1, 0));
}

test "Parser C0 controls" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    try testing.expectEqual(@as(u8, 0x07), (try parser.advance(0x07)).?.Execute);
    try testing.expectEqual(@as(u8, 0x0A), (try parser.advance(0x0A)).?.Execute);
    try testing.expectEqual(@as(u8, 0x0D), (try parser.advance(0x0D)).?.Execute);
}

test "Parser ESC with intermediate (charset, DECALN)" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var out = std.ArrayList(Action).init(testing.allocator);
    defer out.deinit();
    try feed(&parser, "\x1b(0\x1b#8\x1b7", &out);
    try testing.expectEqual(@as(u8, '('), out.items[0].Esc.intermediate);
    try testing.expectEqual(@as(u8, '0'), out.items[0].Esc.final);
    try testing.expectEqual(@as(u8, '#'), out.items[1].Esc.intermediate);
    try testing.expectEqual(@as(u8, '7'), out.items[2].Esc.final);
    try testing.expectEqual(@as(usize, 3), out.items.len);
}

test "Parser OSC terminated by BEL and by ST" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var titles = std.ArrayList(u8).init(testing.allocator);
    defer titles.deinit();
    for ("\x1b]0;one\x07\x1b]2;two\x1b\\x") |b| {
        if (try parser.advance(b)) |a| switch (a) {
            .OSC => |d| {
                try titles.appendSlice(d);
                try titles.append('|');
            },
            .Print => |c| try titles.append(@intCast(c)),
            else => {},
        };
    }
    try testing.expectEqualStrings("0;one|2;two|x", titles.items);
}

test "Parser swallows DCS and APC payloads" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var out = std.ArrayList(u21).init(testing.allocator);
    defer out.deinit();
    try collectPrints(&parser, "a\x1bP+q544e\x1b\\b\x1b_payload\x1b\\c", &out);
    try testing.expectEqualSlices(u21, &.{ 'a', 'b', 'c' }, out.items);
}

test "Parser drops oversized OSC" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    _ = try parser.advance(0x1b);
    _ = try parser.advance(']');
    var i: usize = 0;
    while (i < MAX_OSC_LEN + 10) : (i += 1) _ = try parser.advance('x');
    try testing.expect((try parser.advance(0x07)) == null);
    try testing.expectEqual(ParserState.Ground, parser.state);
}

test "Parser CAN aborts a sequence" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var out = std.ArrayList(u21).init(testing.allocator);
    defer out.deinit();
    try collectPrints(&parser, "\x1b[12\x18A", &out);
    try testing.expectEqualSlices(u21, &.{'A'}, out.items);
}

test "Parser decodes UTF-8" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var out = std.ArrayList(u21).init(testing.allocator);
    defer out.deinit();
    try collectPrints(&parser, "h\xc3\xa9 \xe6\x97\xa5\xf0\x9f\x99\x82", &out);
    try testing.expectEqualSlices(u21, &.{ 'h', 0xE9, ' ', 0x65E5, 0x1F642 }, out.items);
}

test "Parser UTF-8 split across chunks" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var out = std.ArrayList(u21).init(testing.allocator);
    defer out.deinit();
    try collectPrints(&parser, "\xe6\x97", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try collectPrints(&parser, "\xa5", &out);
    try testing.expectEqualSlices(u21, &.{0x65E5}, out.items);
}

test "Parser replaces invalid UTF-8" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var out = std.ArrayList(u21).init(testing.allocator);
    defer out.deinit();
    // stray continuation, overlong C0 lead, truncated sequence followed by
    // ASCII, surrogate (ED A0 80), F5 lead, overlong E0 80 80
    try collectPrints(&parser, "\x80\xc0A\xe6\x97B\xed\xa0\x80\xf5\xe0\x80", &out);
    const R = unicode.replacement_char;
    try testing.expectEqualSlices(u21, &.{ R, R, 'A', R, 'B', R, R, R, R, R, R }, out.items);
}

test "Parser: ESC interrupting UTF-8 still starts a sequence" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    try testing.expect((try parser.advance(0xC3)) == null);
    const a = try parser.advance(0x1B);
    try testing.expectEqual(unicode.replacement_char, a.?.Print);
    try testing.expect(parser.takePending() == null);
    try testing.expectEqual(ParserState.Escape, parser.state);
    _ = try parser.advance('[');
    const h = try parser.advance('H');
    try testing.expect(h.? == .CSI);
}
