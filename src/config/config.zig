const std = @import("std");
const builtin = @import("builtin");

/// Runtime configuration for DeathTerminal.
pub const Config = struct {
    allocator: std.mem.Allocator,
    rows: u16,
    cols: u16,
    ai_enabled: bool,
    ai_endpoint: []const u8,
    scrollback_lines: usize,
    headless: bool,

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .allocator = allocator,
            .rows = 24,
            .cols = 80,
            .ai_enabled = true,
            .ai_endpoint = allocator.dupe(u8, "localhost:50051") catch "localhost:50051",
            .scrollback_lines = 10_000,
            .headless = true,
        };
    }

    pub fn deinit(self: *Config) void {
        if (!std.mem.eql(u8, self.ai_endpoint, "localhost:50051")) {
            self.allocator.free(self.ai_endpoint);
        }
    }

    pub fn loadFromArgs(self: *Config, args: []const []const u8) !void {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--no-ai")) {
                self.ai_enabled = false;
            } else if (std.mem.eql(u8, arg, "--headless")) {
                self.headless = true;
            } else if (std.mem.eql(u8, arg, "--gui")) {
                self.headless = false;
            } else if (std.mem.eql(u8, arg, "--config")) {
                if (i + 1 >= args.len) return error.MissingConfigPath;
                i += 1;
                try self.loadFromFile(args[i]);
            }
        }
    }

    pub fn loadFromFile(self: *Config, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.startsWith(u8, trimmed, "rows =")) {
                self.rows = try parseU16(trimmed["rows =".len..]);
            } else if (std.mem.startsWith(u8, trimmed, "cols =")) {
                self.cols = try parseU16(trimmed["cols =".len..]);
            } else if (std.mem.startsWith(u8, trimmed, "ai_enabled =")) {
                self.ai_enabled = std.mem.indexOf(u8, trimmed, "true") != null;
            } else if (std.mem.startsWith(u8, trimmed, "ai_endpoint =")) {
                const value = try parseString(trimmed["ai_endpoint =".len..]);
                self.allocator.free(self.ai_endpoint);
                self.ai_endpoint = try self.allocator.dupe(u8, value);
            } else if (std.mem.startsWith(u8, trimmed, "scrollback_lines =")) {
                self.scrollback_lines = try parseUsize(trimmed["scrollback_lines =".len..]);
            }
        }
    }

    pub fn defaultConfigPath(self: *Config, buffer: []u8) ![]const u8 {
        _ = self;
        const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
        return try std.fmt.bufPrint(buffer, "{s}/.config/death-terminal/config.txt", .{home});
    }

    pub fn tryLoadDefault(self: *Config) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = self.defaultConfigPath(&path_buf) catch return;
        self.loadFromFile(path) catch {};
    }

    fn parseU16(value: []const u8) !u16 {
        const trimmed = std.mem.trim(u8, value, " \t\"");
        return try std.fmt.parseInt(u16, trimmed, 10);
    }

    fn parseUsize(value: []const u8) !usize {
        const trimmed = std.mem.trim(u8, value, " \t\"");
        return try std.fmt.parseInt(usize, trimmed, 10);
    }

    fn parseString(value: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, value, " \t\"");
        return trimmed;
    }
};

test "Config defaults" {
    const testing = std.testing;
    var config = Config.init(testing.allocator);
    defer config.deinit();
    try testing.expect(config.ai_enabled);
    try testing.expectEqual(@as(u16, 24), config.rows);
}

test "Config arg parsing" {
    const testing = std.testing;
    var config = Config.init(testing.allocator);
    defer config.deinit();

    const args = [_][]const u8{ "deathterminal", "--no-ai", "--gui" };
    try config.loadFromArgs(&args);
    try testing.expect(!config.ai_enabled);
    try testing.expect(!config.headless);
}
