const std = @import("std");

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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return Parser{
            .state = .Ground,
            .params = CSIParams.init(),
            .osc_buffer = std.ArrayList(u8).init(allocator),
            .current_param = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.osc_buffer.deinit();
    }

    pub fn reset(self: *Parser) void {
        self.state = .Ground;
        self.params = CSIParams.init();
        self.current_param = 0;
        self.osc_buffer.clearRetainingCapacity();
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
        return switch (byte) {
            0x00...0x1F => self.handleC0(byte),
            0x20...0x7E => Action{ .Print = byte },
            0x7F => Action.Execute,
            0x1B => {
                self.state = .Escape;
                return null;
            },
            else => Action{ .Print = byte }, // UTF-8 will be handled at a higher level
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
                return null;
            },
            ';' => {
                self.params.addParam(self.current_param);
                self.current_param = 0;
                return null;
            },
            ':' => {
                // Sub-parameter separator (not commonly used)
                self.params.addParam(self.current_param);
                self.current_param = 0;
                return null;
            },
            ' '...'/' => {
                // Intermediate byte
                self.params.intermediate = byte;
                return null;
            },
            '@'...'~' => {
                // Final byte
                self.params.addParam(self.current_param);
                self.current_param = 0;

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
                // Extended foreground color
                // TODO: Handle 256-color and RGB
            },
            39 => try terminal.resetFgColor(),
            40...47 => try terminal.setBgColor(param - 40),
            48 => {
                // Extended background color
                // TODO: Handle 256-color and RGB
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
