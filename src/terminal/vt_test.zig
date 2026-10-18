//! Emulation tests: feed escape sequences, inspect the grid.

const std = @import("std");
const t = std.testing;
const terminal = @import("terminal.zig");
const unicode = @import("unicode.zig");
const color = @import("color.zig");
const Terminal = terminal.Terminal;
const Cell = terminal.Cell;

fn mk(rows: u16, cols: u16) !Terminal {
    return Terminal.initBuffer(t.allocator, rows, cols, 16);
}

fn rowText(term: *Terminal, row: u16) ![]u8 {
    var list = std.ArrayList(u8).init(t.allocator);
    errdefer list.deinit();
    try terminal.appendRowText(term.buffer[@as(usize, row) * term.cols ..][0..term.cols], list.writer());
    const trimmed_len = std.mem.trimRight(u8, list.items, " ").len;
    list.shrinkRetainingCapacity(trimmed_len);
    return list.toOwnedSlice();
}

fn expectRow(term: *Terminal, row: u16, expected: []const u8) !void {
    const s = try rowText(term, row);
    defer t.allocator.free(s);
    try t.expectEqualStrings(expected, s);
}

fn expectCursor(term: *Terminal, row: u16, col: u16) !void {
    try t.expectEqual(row, term.cursor_row);
    try t.expectEqual(col, term.cursor_col);
}

fn ch(term: *Terminal, row: u16, col: u16) u21 {
    return term.getCell(row, col).?.char;
}

// ---------------------------------------------------------------- basics

test "Cell defaults" {
    const cell = Cell.init();
    try t.expectEqual(@as(u21, ' '), cell.char);
    try t.expectEqual(color.default_fg, cell.fg_color);
    try t.expectEqual(color.default_bg, cell.bg_color);
    try t.expect(!cell.bold and !cell.inverse and !cell.strikethrough);
}

test "buffer emulation and title" {
    var term = try mk(24, 80);
    defer term.deinit();
    try term.processOutput("hello\r\nworld");
    try t.expectEqual(@as(u21, 'h'), ch(&term, 0, 0));
    try t.expectEqual(@as(u21, 'w'), ch(&term, 1, 0));
    try term.processOutput("\x1b]0;ssh prod\x07");
    try t.expectEqualStrings("ssh prod", term.title);
    try t.expect(term.title_changed);
    try term.processOutput("\x1b]2;two\x1b\\");
    try t.expectEqualStrings("two", term.title);
    try term.processOutput("\x1b[2J\x1b[H");
    try expectCursor(&term, 0, 0);
    try t.expectEqual(@as(u21, ' '), ch(&term, 0, 0));
}

test "title strips control characters" {
    var term = try mk(2, 10);
    defer term.deinit();
    try term.processOutput("\x1b]2;a\x7fb\xc3\xa9\x07");
    try t.expectEqualStrings("ab\u{e9}", term.title);
}

test "buffer resize copies cells and clamps cursor" {
    var term = try mk(4, 8);
    defer term.deinit();
    term.getCell(0, 0).?.char = 'A';
    term.cursor_row = 1;
    term.cursor_col = 7;
    try term.resize(2, 4);
    try t.expectEqual(@as(u16, 2), term.rows);
    try t.expectEqual(@as(u16, 4), term.cols);
    try t.expectEqual(@as(u21, 'A'), ch(&term, 0, 0));
    try expectCursor(&term, 1, 3);
}

test "resize below the cursor keeps the cursor line" {
    var term = try mk(4, 4);
    defer term.deinit();
    try term.processOutput("a\r\nb\r\nc\r\nd");
    try term.resize(2, 4);
    try expectRow(&term, 0, "c");
    try expectRow(&term, 1, "d");
    try expectCursor(&term, 1, 1);
    try t.expectEqual(@as(usize, 2), term.scrollbackLen());
}

// ---------------------------------------------------------------- wrap

test "pending wrap: last column then wrap on next char" {
    var term = try mk(3, 4);
    defer term.deinit();
    try term.processOutput("abcd");
    try expectCursor(&term, 0, 3);
    try t.expect(term.wrap_pending);
    try term.processOutput("e");
    try expectRow(&term, 0, "abcd");
    try expectRow(&term, 1, "e");
    try expectCursor(&term, 1, 1);
}

test "pending wrap is cancelled by CR and cursor moves" {
    var term = try mk(3, 4);
    defer term.deinit();
    try term.processOutput("abcd\rX");
    try expectRow(&term, 0, "Xbcd");
    try term.processOutput("\x1b[1;4HYZ");
    try expectRow(&term, 0, "XbcY");
    try expectRow(&term, 1, "Z");
}

test "DECAWM off overwrites the last column" {
    var term = try mk(2, 4);
    defer term.deinit();
    try term.processOutput("\x1b[?7labcdef");
    try expectRow(&term, 0, "abcf");
    try expectRow(&term, 1, "");
    try term.processOutput("\x1b[?7h");
    try t.expect(term.modes.autowrap);
}

test "scrollback receives scrolled line" {
    var term = try mk(2, 4);
    defer term.deinit();
    try term.processOutput("AAAA\r\nBBBB\r\nCC");
    try t.expect(term.scrollbackLen() >= 1);
}

// ---------------------------------------------------------------- scroll regions

test "DECSTBM limits LF scrolling to the region" {
    var term = try mk(5, 4);
    defer term.deinit();
    try term.processOutput("1\r\n2\r\n3\r\n4\r\n5");
    try term.processOutput("\x1b[2;4r");
    try expectCursor(&term, 0, 0); // DECSTBM homes the cursor
    try term.processOutput("\x1b[4;1H\nX");
    try expectRow(&term, 0, "1");
    try expectRow(&term, 1, "3");
    try expectRow(&term, 2, "4");
    try expectRow(&term, 3, "X");
    try expectRow(&term, 4, "5");
    try t.expectEqual(@as(usize, 0), term.scrollbackLen());
}

test "invalid DECSTBM is ignored" {
    var term = try mk(5, 4);
    defer term.deinit();
    try term.processOutput("\x1b[4;2r");
    try t.expectEqual(@as(u16, 0), term.scroll_top);
    try t.expectEqual(@as(u16, 4), term.scroll_bottom);
    try term.processOutput("\x1b[r");
    try t.expectEqual(@as(u16, 4), term.scroll_bottom);
}

test "SU and SD scroll the region" {
    var term = try mk(4, 4);
    defer term.deinit();
    try term.processOutput("a\r\nb\r\nc\r\nd\x1b[2;3r\x1b[S");
    try expectRow(&term, 0, "a");
    try expectRow(&term, 1, "c");
    try expectRow(&term, 2, "");
    try expectRow(&term, 3, "d");
    try term.processOutput("\x1b[2T");
    try expectRow(&term, 1, "");
    try expectRow(&term, 2, "");
    try expectRow(&term, 3, "d");
}

test "IND, RI and NEL" {
    var term = try mk(3, 4);
    defer term.deinit();
    try term.processOutput("a\r\nb\r\nc");
    try term.processOutput("\x1b[1;1H\x1bM"); // RI at top scrolls down
    try expectRow(&term, 0, "");
    try expectRow(&term, 1, "a");
    try expectRow(&term, 2, "b");
    try term.processOutput("\x1b[3;3H\x1bD"); // IND at bottom scrolls up
    try expectRow(&term, 0, "a");
    try expectCursor(&term, 2, 2);
    try term.processOutput("\x1b[1;3H\x1bE");
    try expectCursor(&term, 1, 0);
}

test "CUU/CUD stop at scroll margins" {
    var term = try mk(6, 4);
    defer term.deinit();
    try term.processOutput("\x1b[2;4r\x1b[3;1H\x1b[10A");
    try expectCursor(&term, 1, 0);
    try term.processOutput("\x1b[10B");
    try expectCursor(&term, 3, 0);
    try term.processOutput("\x1b[6;1H\x1b[10A"); // below region: stops at the top margin
    try expectCursor(&term, 1, 0);
}

test "origin mode addresses relative to the region" {
    var term = try mk(6, 6);
    defer term.deinit();
    try term.processOutput("\x1b[3;5r\x1b[?6h");
    try expectCursor(&term, 2, 0);
    try term.processOutput("\x1b[2;3HX");
    try t.expectEqual(@as(u21, 'X'), ch(&term, 3, 2));
    try term.processOutput("\x1b[99;1H");
    try expectCursor(&term, 4, 0);
    try term.processOutput("\x1b[6n");
    try t.expectEqualStrings("\x1b[3;1R", term.replies.items);
    try term.processOutput("\x1b[?6l");
    try expectCursor(&term, 0, 0);
}

// ---------------------------------------------------------------- insert / delete

test "IL and DL inside the region" {
    var term = try mk(5, 4);
    defer term.deinit();
    try term.processOutput("1\r\n2\r\n3\r\n4\r\n5\x1b[1;4r\x1b[2;3H\x1b[L");
    try expectCursor(&term, 1, 0);
    try expectRow(&term, 1, "");
    try expectRow(&term, 2, "2");
    try expectRow(&term, 3, "3");
    try expectRow(&term, 4, "5"); // outside the region: untouched
    try term.processOutput("\x1b[2M");
    try expectRow(&term, 1, "3");
    try expectRow(&term, 2, "");
    try expectRow(&term, 3, "");
    try expectRow(&term, 4, "5");
}

test "IL outside the region is ignored" {
    var term = try mk(4, 4);
    defer term.deinit();
    try term.processOutput("a\r\nb\r\nc\r\nd\x1b[1;2r\x1b[4;1H\x1b[L");
    try expectRow(&term, 3, "d");
}

test "ICH, DCH and ECH" {
    var term = try mk(1, 6);
    defer term.deinit();
    try term.processOutput("abcdef\x1b[1;2H\x1b[2@");
    try expectRow(&term, 0, "a  bcd");
    try term.processOutput("\x1b[3P");
    try expectRow(&term, 0, "acd");
    try term.processOutput("\x1b[1;1H\x1b[2X");
    try expectRow(&term, 0, "  d");
    try expectCursor(&term, 0, 0);
}

test "IRM insert mode shifts text right" {
    var term = try mk(1, 6);
    defer term.deinit();
    try term.processOutput("abc\x1b[1;2H\x1b[4hXY\x1b[4lZ");
    try expectRow(&term, 0, "aXYZc");
}

test "REP repeats the last character" {
    var term = try mk(1, 8);
    defer term.deinit();
    try term.processOutput("x\x1b[3b");
    try expectRow(&term, 0, "xxxx");
    try expectCursor(&term, 0, 4);
}

// ---------------------------------------------------------------- erase

test "ED/EL use the current background (bce)" {
    var term = try mk(2, 4);
    defer term.deinit();
    try term.processOutput("abcd\x1b[44m\x1b[1;3H\x1b[K");
    try t.expectEqual(@as(u21, 'b'), ch(&term, 0, 1));
    try t.expectEqual(color.ansi16[4], term.getCell(0, 2).?.bg_color);
    try t.expectEqual(color.ansi16[4], term.getCell(0, 3).?.bg_color);
    try term.processOutput("\x1b[2J");
    try t.expectEqual(color.ansi16[4], term.getCell(1, 0).?.bg_color);
    try expectCursor(&term, 0, 2); // ED 2 does not move the cursor
}

test "ED 3 clears scrollback" {
    var term = try mk(2, 4);
    defer term.deinit();
    try term.processOutput("a\r\nb\r\nc\r\nd");
    try t.expect(term.scrollbackLen() > 0);
    try term.processOutput("\x1b[3J");
    try t.expectEqual(@as(usize, 0), term.scrollbackLen());
}

test "erase with pending-wrap cursor stays in bounds" {
    var term = try mk(2, 4);
    defer term.deinit();
    try term.processOutput("\x1b[2;1Habcd\x1b[1K");
    try term.processOutput("abcd\x1b[1J");
    try t.expectEqual(@as(u21, ' '), ch(&term, 1, 3));
}

// ---------------------------------------------------------------- tabs

test "tab stops: default, HTS, TBC, CHT, CBT" {
    var term = try mk(1, 40);
    defer term.deinit();
    try term.processOutput("\t");
    try expectCursor(&term, 0, 8);
    try term.processOutput("\x1b[3g\x1b[1;5H\x1bH\x1b[1;20H\x1bH\x1b[1;1H\t");
    try expectCursor(&term, 0, 4);
    try term.processOutput("\x1b[I");
    try expectCursor(&term, 0, 19);
    try term.processOutput("\x1b[I"); // no more stops: last column
    try expectCursor(&term, 0, 39);
    try term.processOutput("\x1b[Z");
    try expectCursor(&term, 0, 19);
    try term.processOutput("\x1b[2Z");
    try expectCursor(&term, 0, 0);
    try term.processOutput("\x1b[1;5H\x1b[g\x1b[1;1H\t");
    try expectCursor(&term, 0, 19);
}

// ---------------------------------------------------------------- cursor save

test "DECSC/DECRC and CSI s/u save position and attributes" {
    var term = try mk(4, 10);
    defer term.deinit();
    try term.processOutput("\x1b[2;3H\x1b[1;31m\x1b7\x1b[0m\x1b[4;1H\x1b8X");
    try t.expectEqual(@as(u21, 'X'), ch(&term, 1, 2));
    try t.expect(term.getCell(1, 2).?.bold);
    try t.expectEqual(color.ansi16[1], term.getCell(1, 2).?.fg_color);
    try term.processOutput("\x1b[3;5H\x1b[s\x1b[H\x1b[uY");
    try t.expectEqual(@as(u21, 'Y'), ch(&term, 2, 4));
}

// ---------------------------------------------------------------- alt screen

test "1049 alternate screen saves cursor and restores primary" {
    var term = try mk(3, 6);
    defer term.deinit();
    try term.processOutput("shell\x1b[?1049h");
    try t.expect(term.alt_active);
    try expectRow(&term, 0, "");
    try term.processOutput("\x1b[HVIM");
    try expectRow(&term, 0, "VIM");
    try term.processOutput("\x1b[?1049l");
    try t.expect(!term.alt_active);
    try expectRow(&term, 0, "shell");
    try expectCursor(&term, 0, 5);
    // Alt screen lines never reach scrollback.
    try term.processOutput("\x1b[?1049h\r\n\r\n\r\n\r\n\x1b[?1049l");
    try t.expectEqual(@as(usize, 0), term.scrollbackLen());
}

test "47 and 1047 alternate screen" {
    var term = try mk(2, 6);
    defer term.deinit();
    try term.processOutput("main\x1b[?47h\x1b[Halt");
    try expectRow(&term, 0, "alt");
    try term.processOutput("\x1b[?47l");
    try expectRow(&term, 0, "main");
    try term.processOutput("\x1b[?47h");
    try expectRow(&term, 0, "alt"); // 47 does not clear
    try term.processOutput("\x1b[?47l\x1b[?1047h\x1b[?1047l\x1b[?1047h");
    try expectRow(&term, 0, ""); // 1047 cleared on exit
}

// ---------------------------------------------------------------- modes

test "DECCKM, keypad, bracketed paste, focus, mouse modes" {
    var term = try mk(2, 4);
    defer term.deinit();
    try term.processOutput("\x1b[?1h\x1b=\x1b[?2004h\x1b[?1004h\x1b[?1002h\x1b[?1006h");
    try t.expect(term.modes.app_cursor);
    try t.expect(term.modes.app_keypad);
    try t.expect(term.modes.bracketed_paste);
    try t.expect(term.modes.focus_events);
    try t.expectEqual(terminal.MouseTracking.button, term.modes.mouse);
    try t.expect(term.modes.mouse_sgr);
    try term.processOutput("\x1b[?1003h");
    try t.expectEqual(terminal.MouseTracking.any, term.modes.mouse);
    try term.processOutput("\x1b[?1l\x1b>\x1b[?2004l\x1b[?1004l\x1b[?1003l\x1b[?1006l\x1b[?1000h");
    try t.expect(!term.modes.app_cursor and !term.modes.app_keypad and !term.modes.bracketed_paste);
    try t.expectEqual(terminal.MouseTracking.normal, term.modes.mouse);
    try term.processOutput("\x1b[?25l");
    try t.expect(!term.cursor_visible);
    try term.processOutput("\x1b[?12;25h"); // multiple params
    try t.expect(term.cursor_visible and term.modes.cursor_blink);
}

test "DECSCUSR cursor shapes" {
    var term = try mk(1, 4);
    defer term.deinit();
    try term.processOutput("\x1b[6 q");
    try t.expectEqual(terminal.CursorShape.bar, term.cursor_shape);
    try t.expect(!term.modes.cursor_blink);
    try term.processOutput("\x1b[3 q");
    try t.expectEqual(terminal.CursorShape.underline, term.cursor_shape);
    try t.expect(term.modes.cursor_blink);
    try term.processOutput("\x1b[0 q");
    try t.expectEqual(terminal.CursorShape.block, term.cursor_shape);
}

test "DECRQM reports mode state" {
    var term = try mk(1, 4);
    defer term.deinit();
    try term.processOutput("\x1b[?2004h\x1b[?2004$p\x1b[?7$p\x1b[?9999$p\x1b[4$p");
    try t.expectEqualStrings("\x1b[?2004;1$y\x1b[?7;1$y\x1b[?9999;0$y\x1b[4;2$y", term.replies.items);
}

// ---------------------------------------------------------------- replies

test "DA1, DA2, DSR, CPR, XTVERSION and window size replies" {
    var term = try mk(24, 80);
    defer term.deinit();
    try term.processOutput("\x1b[c");
    try t.expectEqualStrings("\x1b[?62;22c", term.replies.items);
    term.replies.clearRetainingCapacity();
    try term.processOutput("\x1b[>c");
    try t.expectEqualStrings("\x1b[>1;10;0c", term.replies.items);
    term.replies.clearRetainingCapacity();
    try term.processOutput("\x1b[5n\x1b[3;7H\x1b[6n\x1b[?6n");
    try t.expectEqualStrings("\x1b[0n\x1b[3;7R\x1b[?3;7R", term.replies.items);
    term.replies.clearRetainingCapacity();
    try term.processOutput("\x1b[18t\x1b[>q");
    try t.expectEqualStrings("\x1b[8;24;80t\x1bP>|DeathTerminal 0.1.0\x1b\\", term.replies.items);
}

test "OSC 10/11 color queries" {
    var term = try mk(1, 4);
    defer term.deinit();
    try term.processOutput("\x1b]11;?\x07");
    try t.expectEqualStrings("\x1b]11;rgb:0000/0000/0000\x1b\\", term.replies.items);
}

// ---------------------------------------------------------------- SGR

test "SGR attributes on and off" {
    var term = try mk(1, 10);
    defer term.deinit();
    try term.processOutput("\x1b[1;2;3;4;5;7;8;9mA\x1b[22;23;24;25;27;28;29mB");
    const a = term.getCell(0, 0).?;
    try t.expect(a.bold and a.faint and a.italic and a.underline and a.blink and a.inverse and a.hidden and a.strikethrough);
    const b = term.getCell(0, 1).?;
    try t.expect(!b.bold and !b.faint and !b.italic and !b.underline and !b.blink and !b.inverse and !b.hidden and !b.strikethrough);
}

test "empty SGR resets" {
    var term = try mk(1, 4);
    defer term.deinit();
    try term.processOutput("\x1b[1;31m\x1b[mA");
    try t.expect(!term.getCell(0, 0).?.bold);
    try t.expectEqual(color.default_fg, term.getCell(0, 0).?.fg_color);
}

test "SGR 16, 256 and truecolor (semicolon and colon forms)" {
    var term = try mk(1, 10);
    defer term.deinit();
    try term.processOutput("\x1b[31;42mA\x1b[91;102mB\x1b[38;5;196;48;5;21mC\x1b[38;2;1;2;3;48;2;4;5;6mD");
    try term.processOutput("\x1b[38:2::7:8:9mE\x1b[38:2:10:11:12mF\x1b[38:5:46mG\x1b[39;49mH");
    try t.expectEqual(color.ansi16[1], term.getCell(0, 0).?.fg_color);
    try t.expectEqual(color.ansi16[2], term.getCell(0, 0).?.bg_color);
    try t.expectEqual(color.ansi16[9], term.getCell(0, 1).?.fg_color);
    try t.expectEqual(color.ansi16[10], term.getCell(0, 1).?.bg_color);
    try t.expectEqual(@as(u32, 0xFF0000), term.getCell(0, 2).?.fg_color);
    try t.expectEqual(@as(u32, 0x0000FF), term.getCell(0, 2).?.bg_color);
    try t.expectEqual(@as(u32, 0x010203), term.getCell(0, 3).?.fg_color);
    try t.expectEqual(@as(u32, 0x040506), term.getCell(0, 3).?.bg_color);
    try t.expectEqual(@as(u32, 0x070809), term.getCell(0, 4).?.fg_color);
    try t.expectEqual(@as(u32, 0x0A0B0C), term.getCell(0, 5).?.fg_color);
    try t.expectEqual(@as(u32, 0x00FF00), term.getCell(0, 6).?.fg_color);
    try t.expectEqual(color.default_fg, term.getCell(0, 7).?.fg_color);
    try t.expectEqual(color.default_bg, term.getCell(0, 7).?.bg_color);
}

test "SGR truecolor followed by more attributes; underline color is skipped" {
    var term = try mk(1, 4);
    defer term.deinit();
    try term.processOutput("\x1b[38;2;255;0;0;1;58;5;3;4mA\x1b[4:0mB\x1b[4:3mC");
    const a = term.getCell(0, 0).?;
    try t.expectEqual(@as(u32, 0xFF0000), a.fg_color);
    try t.expect(a.bold and a.underline);
    try t.expect(!term.getCell(0, 1).?.underline);
    try t.expect(term.getCell(0, 2).?.underline);
}

test "XTMODKEYS (CSI > m) is not SGR" {
    var term = try mk(1, 4);
    defer term.deinit();
    try term.processOutput("\x1b[1m\x1b[>4;1mA");
    try t.expect(term.getCell(0, 0).?.bold);
}

test "resolvedColors applies inverse, faint and hidden" {
    var cell = Cell.init();
    cell.fg_color = 0xFF0000;
    cell.bg_color = 0x0000FF;
    cell.inverse = true;
    try t.expectEqual(@as(u32, 0x0000FF), cell.resolvedColors().fg);
    try t.expectEqual(@as(u32, 0xFF0000), cell.resolvedColors().bg);
    cell.inverse = false;
    cell.faint = true;
    try t.expectEqual(@as(u32, 0x7F0000), cell.resolvedColors().fg);
    cell.hidden = true;
    try t.expectEqual(@as(u32, 0x0000FF), cell.resolvedColors().fg);
}

// ---------------------------------------------------------------- charsets, misc

test "DEC special graphics line drawing" {
    var term = try mk(1, 8);
    defer term.deinit();
    try term.processOutput("\x1b(0lqk\x1b(Bq");
    try t.expectEqual(@as(u21, 0x250C), ch(&term, 0, 0));
    try t.expectEqual(@as(u21, 0x2500), ch(&term, 0, 1));
    try t.expectEqual(@as(u21, 0x2510), ch(&term, 0, 2));
    try t.expectEqual(@as(u21, 'q'), ch(&term, 0, 3));
    try term.processOutput("\x1b)0\x0ex\x0fx");
    try t.expectEqual(@as(u21, 0x2502), ch(&term, 0, 4));
    try t.expectEqual(@as(u21, 'x'), ch(&term, 0, 5));
}

test "ESC ( B does not print B" {
    var term = try mk(1, 8);
    defer term.deinit();
    try term.processOutput("a\x1b(Bb");
    try expectRow(&term, 0, "ab");
}

test "DECALN fills with E" {
    var term = try mk(2, 3);
    defer term.deinit();
    try term.processOutput("\x1b#8");
    try expectRow(&term, 0, "EEE");
    try expectRow(&term, 1, "EEE");
}

test "RIS and DECSTR" {
    var term = try mk(3, 4);
    defer term.deinit();
    try term.processOutput("ab\x1b[2;3r\x1b[?6h\x1b[4h\x1b[1m\x1b[!p");
    try t.expect(!term.modes.origin and !term.modes.insert and !term.pen.bold);
    try t.expectEqual(@as(u16, 2), term.scroll_bottom);
    try term.processOutput("\x1b[?1049h\x1b[?2004hxx\x1bc");
    try t.expect(!term.alt_active and !term.modes.bracketed_paste);
    try expectRow(&term, 0, "");
    try expectCursor(&term, 0, 0);
}

test "OSC 8 hyperlinks are recorded on cells" {
    var term = try mk(1, 10);
    defer term.deinit();
    try term.processOutput("\x1b]8;id=1;https://example.com\x1b\\li\x1b]8;;\x1b\\x");
    const l = term.getCell(0, 0).?.link;
    try t.expect(l != 0);
    try t.expectEqualStrings("https://example.com", term.linkTarget(l).?);
    try t.expectEqual(l, term.getCell(0, 1).?.link);
    try t.expectEqual(@as(u16, 0), term.getCell(0, 2).?.link);
    // Same URI reuses the slot; control chars are rejected.
    try term.processOutput("\x1b]8;;https://example.com\x07y\x1b]8;;bad\x7furi\x07z");
    try t.expectEqual(l, term.getCell(0, 3).?.link);
    try t.expectEqual(@as(u16, 0), term.getCell(0, 4).?.link);
    try t.expectEqual(@as(usize, 1), term.links.items.len);
}

test "OSC 7 records the working directory" {
    var term = try mk(1, 4);
    defer term.deinit();
    try term.processOutput("\x1b]7;file://host/tmp\x07");
    try t.expectEqualStrings("file://host/tmp", term.cwd_uri);
}

test "BEL sets the bell flag; LNM makes LF return" {
    var term = try mk(3, 4);
    defer term.deinit();
    try term.processOutput("\x07");
    try t.expect(term.bell);
    try term.processOutput("ab\x1b[20h\nc");
    try expectRow(&term, 1, "c");
}

test "C0 inside CSI executes in place" {
    var term = try mk(2, 6);
    defer term.deinit();
    try term.processOutput("abc\x1b[\x082D"); // BS inside CSI, then CUB 2
    try expectCursor(&term, 0, 0);
}

// ---------------------------------------------------------------- UTF-8

test "UTF-8 lands in the grid as codepoints with wide cells" {
    var term = try mk(2, 20);
    defer term.deinit();
    try term.processOutput("h\xc3\xa9llo \xe6\x97\xa5\xe6\x9c\xac \xf0\x9f\x99\x82");
    try t.expectEqual(@as(u21, 0xE9), ch(&term, 0, 1));
    try t.expectEqual(@as(u21, 0x65E5), ch(&term, 0, 6));
    try t.expectEqual(@as(u2, 2), term.getCell(0, 6).?.width);
    try t.expect(term.getCell(0, 7).?.isSpacer());
    try t.expectEqual(@as(u21, 0x672C), ch(&term, 0, 8));
    try t.expect(term.getCell(0, 9).?.isSpacer());
    try t.expectEqual(@as(u21, 0x1F642), ch(&term, 0, 11));
    try t.expect(term.getCell(0, 12).?.isSpacer());
    try expectCursor(&term, 0, 13);
    try expectRow(&term, 0, "h\u{e9}llo \u{65e5}\u{672c} \u{1f642}");
}

test "combining marks attach to the previous cell" {
    var term = try mk(1, 10);
    defer term.deinit();
    try term.processOutput("e\xcc\x81x\xe6\x97\xa5\xcc\x81\xcc\x82\xcc\x83y");
    try t.expectEqual(@as(u21, 0x0301), term.getCell(0, 0).?.combining[0]);
    try t.expectEqual(@as(u21, 'x'), ch(&term, 0, 1));
    try t.expectEqual(@as(u21, 0x65E5), ch(&term, 0, 2));
    try t.expectEqual(@as(u21, 0x0301), term.getCell(0, 2).?.combining[0]);
    try t.expectEqual(@as(u21, 0x0302), term.getCell(0, 2).?.combining[1]);
    try t.expect(term.getCell(0, 3).?.isSpacer());
    try t.expectEqual(@as(u21, 'y'), ch(&term, 0, 4));
    try expectCursor(&term, 0, 5);
    try term.processOutput("\r\xcc\x81");
    try expectCursor(&term, 0, 0);
    try t.expectEqual(@as(u21, 'e'), ch(&term, 0, 0));
}

test "combining mark after a char in the last column" {
    var term = try mk(2, 3);
    defer term.deinit();
    try term.processOutput("abc\xcc\x81");
    try t.expectEqual(@as(u21, 0x0301), term.getCell(0, 2).?.combining[0]);
    try expectCursor(&term, 0, 2);
}

test "wide char wraps instead of splitting at the last column" {
    var term = try mk(2, 5);
    defer term.deinit();
    try term.processOutput("abcd\xe6\x97\xa5");
    try t.expectEqual(@as(u21, ' '), ch(&term, 0, 4));
    try t.expectEqual(@as(u2, 1), term.getCell(0, 4).?.width);
    try t.expectEqual(@as(u21, 0x65E5), ch(&term, 1, 0));
    try t.expect(term.getCell(1, 1).?.isSpacer());
    try expectCursor(&term, 1, 2);
}

test "overwriting half of a wide char clears the other half" {
    var term = try mk(1, 6);
    defer term.deinit();
    try term.processOutput("\xe6\x97\xa5\xe6\x9c\xac\x1b[1;2HXY");
    try t.expectEqual(@as(u21, ' '), ch(&term, 0, 0));
    try t.expectEqual(@as(u2, 1), term.getCell(0, 0).?.width);
    try t.expectEqual(@as(u21, 'X'), ch(&term, 0, 1));
    try t.expectEqual(@as(u21, 'Y'), ch(&term, 0, 2));
    try t.expectEqual(@as(u2, 1), term.getCell(0, 3).?.width);
}

test "erase/delete that splits a wide char leaves no orphan half" {
    var term = try mk(1, 6);
    defer term.deinit();
    try term.processOutput("\xe6\x97\xa5\xe6\x9c\xac\x1b[1;2H\x1b[K");
    try t.expectEqual(@as(u2, 1), term.getCell(0, 0).?.width);
    try term.processOutput("\x1b[1;1H\xe6\x97\xa5ab\x1b[1;2H\x1b[P");
    try t.expectEqual(@as(u2, 1), term.getCell(0, 0).?.width);
    try t.expectEqual(@as(u2, 1), term.getCell(0, 1).?.width);
}

test "invalid UTF-8 becomes U+FFFD in the grid" {
    var term = try mk(1, 8);
    defer term.deinit();
    try term.processOutput("a\xffb\xe6\x97c");
    try t.expectEqual(unicode.replacement_char, ch(&term, 0, 1));
    try t.expectEqual(@as(u21, 'b'), ch(&term, 0, 2));
    try t.expectEqual(unicode.replacement_char, ch(&term, 0, 3));
    try t.expectEqual(@as(u21, 'c'), ch(&term, 0, 4));
}

test "visibleText" {
    var term = try mk(2, 3);
    defer term.deinit();
    try term.processOutput("ab\r\ncd");
    const s = try term.visibleText(t.allocator);
    defer t.allocator.free(s);
    try t.expectEqualStrings("ab \ncd ", s);
}

test "DECCOLM clears, homes and resets margins without resizing" {
    var term = try mk(5, 10);
    defer term.deinit();
    try term.processOutput("junk\x1b[2;4r\x1b[5;5H\x1b[?3l");
    try t.expectEqual(@as(u16, 0), term.cursor_row);
    try t.expectEqual(@as(u16, 0), term.cursor_col);
    try t.expectEqual(@as(u16, 0), term.scroll_top);
    try t.expectEqual(@as(u16, 4), term.scroll_bottom);
    try t.expectEqual(@as(u21, ' '), term.buffer[0].char);
    try t.expectEqual(@as(u16, 10), term.cols);
}
