const std = @import("std");
const vk = @import("vulkan_c.zig");
const loader_mod = @import("vk_loader.zig");
const software_mod = @import("software.zig");
const Cell = @import("../terminal/terminal.zig").Cell;

pub const Backend = enum { software, vulkan_instance };

pub const VulkanRenderer = struct {
    allocator: std.mem.Allocator,
    loader: loader_mod.Loader,
    instance: ?vk.VkInstance,
    physical_device: ?vk.VkPhysicalDevice,
    device: ?vk.VkDevice,
    graphics_queue: ?vk.VkQueue,
    graphics_queue_family: u32,
    initialized: bool,
    backend: Backend,
    software: software_mod.SoftwareRenderer,

    pub fn init(allocator: std.mem.Allocator) !VulkanRenderer {
        std.debug.print("  → Initializing renderer...\n", .{});
        var renderer = VulkanRenderer{
            .allocator = allocator,
            .loader = loader_mod.Loader.init(),
            .instance = null,
            .physical_device = null,
            .device = null,
            .graphics_queue = null,
            .graphics_queue_family = 0,
            .initialized = false,
            .backend = .software,
            .software = try software_mod.SoftwareRenderer.init(allocator, 80, 24),
        };
        if (renderer.tryCreateVulkanInstance()) {
            renderer.backend = .vulkan_instance;
            std.debug.print("  → Vulkan instance ready (present still software)\n", .{});
        } else {
            std.debug.print("  → Using software rasterizer\n", .{});
        }
        renderer.initialized = true;
        return renderer;
    }

    pub fn deinit(self: *VulkanRenderer) void {
        if (!self.initialized) return;
        self.software.deinit();
        if (self.instance) |instance| {
            if (self.loader.vkDestroyInstance) |destroy| destroy(instance, null);
            self.instance = null;
        }
        self.loader.deinit();
        self.initialized = false;
    }

    fn tryCreateVulkanInstance(self: *VulkanRenderer) bool {
        const create = self.loader.vkCreateInstance orelse return false;
        var app_info = std.mem.zeroes(vk.VkApplicationInfo);
        app_info.sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app_info.pApplicationName = "DeathTerminal";
        app_info.applicationVersion = 1;
        app_info.pEngineName = "DeathTerminal";
        app_info.engineVersion = 1;
        app_info.apiVersion = 1 << 22;
        var create_info = std.mem.zeroes(vk.VkInstanceCreateInfo);
        create_info.sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        create_info.pApplicationInfo = &app_info;
        var instance: vk.VkInstance = undefined;
        if (create(&create_info, null, &instance) != vk.VK_SUCCESS) return false;
        self.instance = instance;
        return true;
    }

    pub fn render(self: *VulkanRenderer) !void {
        if (!self.initialized) return error.NotInitialized;
    }

    pub fn resize(self: *VulkanRenderer, width: u32, height: u32) !void {
        if (!self.initialized) return error.NotInitialized;
        const cols: u16 = @intCast(@max(1, width / software_mod.CELL_W));
        const rows: u16 = @intCast(@max(1, height / software_mod.CELL_H));
        try self.software.resize(cols, rows);
    }

    pub fn renderText(self: *VulkanRenderer, text_buffer: []const u8, rows: u32, cols: u32) !void {
        if (!self.initialized) return error.NotInitialized;
        _ = text_buffer;
        _ = rows;
        _ = cols;
    }

    pub fn renderCells(self: *VulkanRenderer, cells: []const Cell, rows: u16, cols: u16, cursor_row: u16, cursor_col: u16, cursor_visible: bool) !void {
        if (!self.initialized) return error.NotInitialized;
        self.software.renderGrid(cells, rows, cols, cursor_row, cursor_col, cursor_visible);
    }

    pub fn framebuffer(self: *const VulkanRenderer) []const u32 {
        return self.software.pixels;
    }

    pub fn framebufferSize(self: *const VulkanRenderer) struct { w: u32, h: u32 } {
        return .{ .w = self.software.width, .h = self.software.height };
    }
};

test "VulkanRenderer init" {
    var renderer = try VulkanRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try std.testing.expect(renderer.initialized);
}

test "VulkanRenderer operations" {
    var renderer = try VulkanRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render();
    try renderer.resize(640, 400);
}
