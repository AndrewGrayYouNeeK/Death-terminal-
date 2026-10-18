const std = @import("std");
const unicode = @import("unicode.zig");

/// ANSI escape sequence parser state
pub const ParserState = enum {
    Ground,
    Escape,
    CSI,
    OSC,
    DCS,
};

/// CSI (Control Sequence Introducer) parameters
pub const CSIParams = struct {
    params: [16]u32,
    param_count: u8,
    intermediate: ?u8,

    pub fn init() CSIParams {
        return CSIParams{
            .params = [_]u32{0} ** 16,
            .param_count = 0,
            .intermediate = null,
        };
    }

    pub fn addParam(self: *CSIParams, param: u32) void {
        if (self.param_count < 16) {
            self.params[self.param_count] = param;
            self.param_count += 1;
        }
    }

    pub fn getParam(self: CSIParams, index: u8, default: u32) u32 {
        if (index < self.param_count) {
            return self.params[index];
        }
        return default;
    }
};

/// ANSI escape sequence action
pub const Action = union(enum) {
    Print: u21, // Print character
    Execute: u8, // Execute control character (C0/C1)
    CSI: struct {
        params: CSIParams,
        final_byte: u8,
    },
    OSC: []const u8, // Operating System Command
    Clear, // Clear screen
    Bell, // Audible bell
    Backspace,
    Tab,
    LineFeed,
    CarriageReturn,
};

/// ANSI escape sequence parser
pub const Parser = struct {
    state: ParserState,
    params: CSIParams,
    osc_buffer: std.ArrayList(u8),
    current_param: u32,
    saw_digit: bool,
    allocator: std.mem.Allocator,
    /// In-progress UTF-8 sequence (Ground state only).
    utf8_cp: u21 = 0,
    utf8_need: u2 = 0,
    utf8_lo: u8 = 0x80,
    utf8_hi: u8 = 0xBF,
    /// Second action produced by one byte: when a byte interrupts a UTF-8
    /// sequence, `advance` returns U+FFFD and the byte's own action lands
    /// here. Drain with `takePending` after every `advance`.
    pending: ?Action = null,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return Parser{
            .state = .Ground,
            .params = CSIParams.init(),
            .osc_buffer = std.ArrayList(u8).init(allocator),
            .current_param = 0,
            .saw_digit = false,
            .allocator = allocator,
        };
    }

    pub fn takePending(self: *Parser) ?Action {
        const a = self.pending;
        self.pending = null;
        return a;
    }

    pub fn deinit(self: *Parser) void {
        self.osc_buffer.deinit();
    }

    pub fn reset(self: *Parser) void {
        self.state = .Ground;
        self.params = CSIParams.init();
        self.current_param = 0;
        self.saw_digit = false;
        self.osc_buffer.clearRetainingCapacity();
        self.utf8_need = 0;
        self.pending = null;
    }

    /// Parse next byte and return action if complete
    pub fn advance(self: *Parser, byte: u8) !?Action {
        switch (self.state) {
            .Ground => return try self.handleGround(byte),
            .Escape => return try self.handleEscape(byte),
            .CSI => return try self.handleCSI(byte),
            .OSC => return try self.handleOSC(byte),
            .DCS => return try self.handleDCS(byte),
        }
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
            self.pending = try self.groundStart(byte);
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

    fn groundStart(self: *Parser, byte: u8) !?Action {
        return switch (byte) {
            0x1B => {
                self.state = .Escape;
                return null;
            },
            0x00...0x1A, 0x1C...0x1F => self.handleC0(byte),
            0x20...0x7E => Action{ .Print = byte },
            0x7F => Action{ .Execute = byte },
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

    fn handleC0(self: *Parser, byte: u8) ?Action {
        _ = self;
        return switch (byte) {
            0x07 => Action.Bell,
            0x08 => Action.Backspace,
            0x09 => Action.Tab,
            0x0A => Action.LineFeed,
            0x0D => Action.CarriageReturn,
            else => Action{ .Execute = byte },
        };
    }

    fn handleEscape(self: *Parser, byte: u8) !?Action {
        return switch (byte) {
            '[' => {
                self.state = .CSI;
                self.params = CSIParams.init();
                self.current_param = 0;
                self.saw_digit = false;
                return null;
            },
            ']' => {
                self.state = .OSC;
                self.osc_buffer.clearRetainingCapacity();
                return null;
            },
            'P' => {
                self.state = .DCS;
                return null;
            },
            'c' => {
                // RIS - Reset to Initial State
                self.state = .Ground;
                return Action.Clear;
            },
            'D' => {
                // IND - Index (move down with scroll)
                self.state = .Ground;
                return Action.LineFeed;
            },
            'M' => {
                // RI - Reverse Index (move up with scroll)
                self.state = .Ground;
                return Action{ .CSI = .{
                    .params = CSIParams.init(),
                    .final_byte = 'A',
                } };
            },
            else => {
                self.state = .Ground;
                return null;
            },
        };
    }

    fn handleCSI(self: *Parser, byte: u8) !?Action {
        switch (byte) {
            '0'...'9' => {
                self.current_param = self.current_param * 10 + (byte - '0');
                self.saw_digit = true;
                return null;
            },
            ';' => {
                self.params.addParam(self.current_param);
                self.current_param = 0;
                self.saw_digit = false;
                return null;
            },
            ':' => {
                // Sub-parameter separator (not commonly used)
                self.params.addParam(self.current_param);
                self.current_param = 0;
                self.saw_digit = false;
                return null;
            },
            ' '...'/' => {
                // Intermediate byte
                self.params.intermediate = byte;
                return null;
            },
            '?', '>', '=' => {
                // DEC private / ANSI mode markers (CSI ? 2004 h, CSI > ...)
                self.params.intermediate = byte;
                return null;
            },
            '@'...'~' => {
                // Final byte. Empty CSI (ESC[H) has no params so callers use defaults.
                if (self.saw_digit or self.params.param_count > 0) {
                    self.params.addParam(self.current_param);
                }
                self.current_param = 0;
                self.saw_digit = false;

                const action = Action{
                    .CSI = .{
                        .params = self.params,
                        .final_byte = byte,
                    },
                };

                self.state = .Ground;
                self.params = CSIParams.init();

                return action;
            },
            else => {
                // Invalid sequence, reset
                self.state = .Ground;
                self.params = CSIParams.init();
                self.current_param = 0;
                self.saw_digit = false;
                return null;
            },
        }
    }

    fn handleOSC(self: *Parser, byte: u8) !?Action {
        switch (byte) {
            0x07 => {
                // BEL terminates OSC
                const action = Action{ .OSC = try self.osc_buffer.toOwnedSlice() };
                self.state = .Ground;
                return action;
            },
            0x1B => {
                // ESC might be starting ST (String Terminator: ESC \)
                // We'll handle this in a simple way
                if (self.osc_buffer.items.len > 0 and self.osc_buffer.getLast() == '\\') {
                    _ = self.osc_buffer.pop();
                    const action = Action{ .OSC = try self.osc_buffer.toOwnedSlice() };
                    self.state = .Ground;
                    return action;
                }
                try self.osc_buffer.append(byte);
                return null;
            },
            else => {
                try self.osc_buffer.append(byte);
                return null;
            },
        }
    }

    fn handleDCS(self: *Parser, byte: u8) !?Action {
        // DCS (Device Control String) - not commonly used, just skip for now
        if (byte == 0x1B) {
            self.state = .Ground;
        }
        return null;
    }
};

/// Apply ANSI action to terminal
pub fn applyAction(action: Action, terminal: anytype) !void {
    switch (action) {
        .Print => |ch| {
            try terminal.putChar(ch);
        },
        .Execute => |byte| {
            _ = byte;
            // Handle other control characters
        },
        .CSI => |csi| {
            try applyCSI(csi.params, csi.final_byte, terminal);
        },
        .OSC => |data| {
            defer terminal.allocator.free(data);
            try applyOSC(data, terminal);
        },
        .Clear => {
            try terminal.clear();
        },
        .Bell => {
            // Trigger visual/audio bell
        },
        .Backspace => {
            try terminal.backspace();
        },
        .Tab => {
            try terminal.tab();
        },
        .LineFeed => {
            try terminal.lineFeed();
        },
        .CarriageReturn => {
            try terminal.carriageReturn();
        },
    }
}

fn applyCSI(params: CSIParams, final_byte: u8, terminal: anytype) !void {
    switch (final_byte) {
        'A' => {
            // CUU - Cursor Up
            const n = params.getParam(0, 1);
            try terminal.cursorUp(n);
        },
        'B' => {
            // CUD - Cursor Down
            const n = params.getParam(0, 1);
            try terminal.cursorDown(n);
        },
        'C' => {
            // CUF - Cursor Forward
            const n = params.getParam(0, 1);
            try terminal.cursorForward(n);
        },
        'D' => {
            // CUB - Cursor Back
            const n = params.getParam(0, 1);
            try terminal.cursorBack(n);
        },
        'E' => {
            // CNL - Cursor Next Line
            const n = params.getParam(0, 1);
            try terminal.cursorDown(n);
            terminal.cursor_col = 0;
        },
        'F' => {
            // CPL - Cursor Previous Line
            const n = params.getParam(0, 1);
            try terminal.cursorUp(n);
            terminal.cursor_col = 0;
        },
        'G' => {
            // CHA - Cursor Horizontal Absolute
            const col = params.getParam(0, 1);
            terminal.cursor_col = @min(col - 1, terminal.cols - 1);
        },
        'H', 'f' => {
            // CUP - Cursor Position
            const row = params.getParam(0, 1);
            const col = params.getParam(1, 1);
            terminal.moveCursor(@min(row - 1, terminal.rows - 1), @min(col - 1, terminal.cols - 1));
        },
        'J' => {
            // ED - Erase in Display
            const mode = params.getParam(0, 0);
            try terminal.eraseDisplay(mode);
        },
        'K' => {
            // EL - Erase in Line
            const mode = params.getParam(0, 0);
            try terminal.eraseLine(mode);
        },
        'S' => {
            // SU - Scroll Up
            const n = params.getParam(0, 1);
            try terminal.scrollUp(n);
        },
        'T' => {
            // SD - Scroll Down
            const n = params.getParam(0, 1);
            try terminal.scrollDown(n);
        },
        'm' => {
            // SGR - Select Graphic Rendition
            try applySGR(params, terminal);
        },
        's' => {
            // SCP - Save Cursor Position
            try terminal.saveCursor();
        },
        'u' => {
            // RCP - Restore Cursor Position
            try terminal.restoreCursor();
        },
        'h' => {
            // SM - Set Mode
            try terminal.setMode(params);
        },
        'l' => {
            // RM - Reset Mode
            try terminal.resetMode(params);
        },
        else => {
            // Unknown or unimplemented sequence
        },
    }
}

fn applySGR(params: CSIParams, terminal: anytype) !void {
    var i: u8 = 0;
    while (i < params.param_count) : (i += 1) {
        const param = params.params[i];
        switch (param) {
            0 => try terminal.resetAttributes(),
            1 => try terminal.setBold(true),
            3 => try terminal.setItalic(true),
            4 => try terminal.setUnderline(true),
            22 => try terminal.setBold(false),
            23 => try terminal.setItalic(false),
            24 => try terminal.setUnderline(false),
            30...37 => try terminal.setFgColor(param - 30),
            38 => {
                if (i + 2 < params.param_count and params.params[i + 1] == 5) {
                    try terminal.setFgColor(params.params[i + 2] % 16);
                    i += 2;
                } else if (i + 4 < params.param_count and params.params[i + 1] == 2) {
                    const r = params.params[i + 2];
                    const g = params.params[i + 3];
                    const b = params.params[i + 4];
                    terminal.current_fg = (r << 16) | (g << 8) | b;
                    i += 4;
                }
            },
            39 => try terminal.resetFgColor(),
            40...47 => try terminal.setBgColor(param - 40),
            48 => {
                if (i + 2 < params.param_count and params.params[i + 1] == 5) {
                    try terminal.setBgColor(params.params[i + 2] % 16);
                    i += 2;
                } else if (i + 4 < params.param_count and params.params[i + 1] == 2) {
                    const r = params.params[i + 2];
                    const g = params.params[i + 3];
                    const b = params.params[i + 4];
                    terminal.current_bg = (r << 16) | (g << 8) | b;
                    i += 4;
                }
            },
            49 => try terminal.resetBgColor(),
            90...97 => try terminal.setFgColor(param - 90 + 8), // Bright colors
            100...107 => try terminal.setBgColor(param - 100 + 8), // Bright colors
            else => {},
        }
    }
}

fn applyOSC(data: []const u8, terminal: anytype) !void {
    // OSC sequences typically format: number ; text
    // Common ones: 0 (set title), 1 (set icon), 2 (set both)
    if (data.len > 2 and data[1] == ';') {
        const command = data[0];
        const text = data[2..];
        switch (command) {
            '0', '1', '2' => {
                try terminal.setTitle(text);
            },
            else => {},
        }
    }
}

test "Parser basic" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();

    // Test simple character
    const action = try parser.advance('A');
    try testing.expect(action != null);
    if (action) |a| {
        try testing.expect(a == .Print);
        try testing.expectEqual(@as(u21, 'A'), a.Print);
    }
}

test "Parser CSI" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();

    // Test CSI sequence: ESC [ 1 ; 2 H (cursor position)
    _ = try parser.advance(0x1B); // ESC
    _ = try parser.advance('['); // [
    _ = try parser.advance('1');
    _ = try parser.advance(';');
    _ = try parser.advance('2');
    const action = try parser.advance('H');

    try testing.expect(action != null);
    if (action) |a| {
        try testing.expect(a == .CSI);
        try testing.expectEqual(@as(u8, 'H'), a.CSI.final_byte);
        try testing.expectEqual(@as(u32, 1), a.CSI.params.getParam(0, 0));
        try testing.expectEqual(@as(u32, 2), a.CSI.params.getParam(1, 0));
    }
}

test "Parser empty CUP uses no params" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();

    _ = try parser.advance(0x1B);
    _ = try parser.advance('[');
    const action = try parser.advance('H');
    try testing.expect(action != null);
    try testing.expectEqual(@as(u8, 0), action.?.CSI.params.param_count);
}

test "Parser CSI private mode DECSET" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();

    _ = try parser.advance(0x1B);
    _ = try parser.advance('[');
    _ = try parser.advance('?');
    _ = try parser.advance('2');
    _ = try parser.advance('0');
    _ = try parser.advance('0');
    _ = try parser.advance('4');
    const action = try parser.advance('h');
    try testing.expect(action != null);
    try testing.expectEqual(@as(u8, 'h'), action.?.CSI.final_byte);
    try testing.expectEqual(@as(u8, '?'), action.?.CSI.params.intermediate.?);
    try testing.expectEqual(@as(u32, 2004), action.?.CSI.params.getParam(0, 0));
}

test "Parser control characters" {
    const testing = std.testing;
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();

    // Test bell
    const bell = try parser.advance(0x07);
    try testing.expect(bell != null);
    try testing.expect(bell.? == .Bell);

    // Test line feed
    const lf = try parser.advance(0x0A);
    try testing.expect(lf != null);
    try testing.expect(lf.? == .LineFeed);

    // Test carriage return
    const cr = try parser.advance(0x0D);
    try testing.expect(cr != null);
    try testing.expect(cr.? == .CarriageReturn);
}

fn collectPrints(parser: *Parser, bytes: []const u8, out: *std.ArrayList(u21)) !void {
    for (bytes) |b| {
        if (try parser.advance(b)) |a| if (a == .Print) try out.append(a.Print);
        if (parser.takePending()) |a| if (a == .Print) try out.append(a.Print);
    }
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

    const r = try parser.advance(0xC3);
    try testing.expect(r == null);
    const a = try parser.advance(0x1B);
    try testing.expect(a.? == .Print);
    try testing.expectEqual(unicode.replacement_char, a.?.Print);
    try testing.expect(parser.takePending() == null);
    try testing.expectEqual(ParserState.Escape, parser.state);
    _ = try parser.advance('[');
    const h = try parser.advance('H');
    try testing.expect(h.? == .CSI);
}
