const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan_c.zig");

fn libNames() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &[_][]const u8{"vulkan-1.dll"},
        .macos, .ios => &[_][]const u8{ "libvulkan.1.dylib", "libvulkan.dylib" },
        else => &[_][]const u8{ "libvulkan.so.1", "libvulkan.so" },
    };
}

const GetInstanceProcAddrFn = *const fn (vk.VkInstance, [*:0]const u8) callconv(.C) vk.PFN_vkVoidFunction;
const CreateInstanceFn = *const fn ([*c]const vk.VkInstanceCreateInfo, ?*const anyopaque, *vk.VkInstance) callconv(.C) vk.VkResult;
const DestroyInstanceFn = *const fn (vk.VkInstance, ?*const anyopaque) callconv(.C) void;
const EnumeratePhysicalDevicesFn = *const fn (vk.VkInstance, *u32, ?[*]vk.VkPhysicalDevice) callconv(.C) vk.VkResult;
const GetPhysicalDevicePropertiesFn = *const fn (vk.VkPhysicalDevice, *vk.VkPhysicalDeviceProperties) callconv(.C) void;
const GetPhysicalDeviceQueueFamilyPropertiesFn = *const fn (vk.VkPhysicalDevice, *u32, ?[*]vk.VkQueueFamilyProperties) callconv(.C) void;
const CreateDeviceFn = *const fn (vk.VkPhysicalDevice, [*c]const vk.VkDeviceCreateInfo, ?*const anyopaque, *vk.VkDevice) callconv(.C) vk.VkResult;
const DestroyDeviceFn = *const fn (vk.VkDevice, ?*const anyopaque) callconv(.C) void;
const GetDeviceQueueFn = *const fn (vk.VkDevice, u32, u32, *vk.VkQueue) callconv(.C) void;

fn loadSymbol(comptime T: type, get_proc: GetInstanceProcAddrFn, instance: vk.VkInstance, name: [*:0]const u8) ?T {
    const raw_fn = get_proc(instance, name) orelse return null;
    return @ptrCast(raw_fn);
}

/// VulkanRenderer handles GPU-accelerated rendering via the Vulkan loader.
/// Instance/device creation is real; presentation stays stubbed until a window exists.
pub const VulkanRenderer = struct {
    allocator: std.mem.Allocator,
    lib: ?std.DynLib,
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    graphics_queue_family: u32,
    initialized: bool,
    has_instance: bool,
    has_device: bool,

    vkGetInstanceProcAddr: ?GetInstanceProcAddrFn,
    vkCreateInstance: ?CreateInstanceFn,
    vkDestroyInstance: ?DestroyInstanceFn,
    vkEnumeratePhysicalDevices: ?EnumeratePhysicalDevicesFn,
    vkGetPhysicalDeviceProperties: ?GetPhysicalDevicePropertiesFn,
    vkGetPhysicalDeviceQueueFamilyProperties: ?GetPhysicalDeviceQueueFamilyPropertiesFn,
    vkCreateDevice: ?CreateDeviceFn,
    vkDestroyDevice: ?DestroyDeviceFn,
    vkGetDeviceQueue: ?GetDeviceQueueFn,

    pub fn init(allocator: std.mem.Allocator) !VulkanRenderer {
        std.debug.print("  → Initializing Vulkan renderer...\n", .{});

        var renderer = VulkanRenderer{
            .allocator = allocator,
            .lib = null,
            .instance = null,
            .physical_device = null,
            .device = null,
            .graphics_queue = null,
            .graphics_queue_family = 0,
            .initialized = false,
            .has_instance = false,
            .has_device = false,
            .vkGetInstanceProcAddr = null,
            .vkCreateInstance = null,
            .vkDestroyInstance = null,
            .vkEnumeratePhysicalDevices = null,
            .vkGetPhysicalDeviceProperties = null,
            .vkGetPhysicalDeviceQueueFamilyProperties = null,
            .vkCreateDevice = null,
            .vkDestroyDevice = null,
            .vkGetDeviceQueue = null,
        };

        renderer.loadLibrary() catch {
            std.debug.print("    → Vulkan loader not found; renderer stays stubbed\n", .{});
            renderer.initialized = true;
            return renderer;
        };

        renderer.createInstance() catch |err| {
            std.debug.print("    → vkCreateInstance failed ({s}); renderer stays stubbed\n", .{@errorName(err)});
            renderer.initialized = true;
            return renderer;
        };

        renderer.selectPhysicalDevice() catch |err| {
            std.debug.print("    → No usable GPU ({s}); instance only\n", .{@errorName(err)});
        };

        if (renderer.physical_device != null) {
            renderer.createDevice() catch |err| {
                std.debug.print("    → vkCreateDevice failed ({s}); instance only\n", .{@errorName(err)});
            };
        }

        renderer.initialized = true;
        if (renderer.has_device) {
            std.debug.print("  → Vulkan renderer initialized (instance + device)\n", .{});
        } else if (renderer.has_instance) {
            std.debug.print("  → Vulkan renderer initialized (instance, no device)\n", .{});
        } else {
            std.debug.print("  → Vulkan renderer initialized (stubbed)\n", .{});
        }

        return renderer;
    }

    pub fn deinit(self: *VulkanRenderer) void {
        if (!self.initialized) return;

        self.destroyDevice();
        self.destroyInstance();
        if (self.lib) |*lib| {
            lib.close();
            self.lib = null;
        }
        self.initialized = false;
    }

    fn loadLibrary(self: *VulkanRenderer) !void {
        var opened: ?std.DynLib = null;
        for (libNames()) |name| {
            opened = std.DynLib.open(name) catch continue;
            break;
        }
        self.lib = opened orelse return error.VulkanLoaderMissing;

        const get_proc = self.lib.?.lookup(GetInstanceProcAddrFn, "vkGetInstanceProcAddr") orelse {
            self.lib.?.close();
            self.lib = null;
            return error.MissingVkGetInstanceProcAddr;
        };
        self.vkGetInstanceProcAddr = get_proc;

        const null_instance: vk.VkInstance = null;
        self.vkCreateInstance = loadSymbol(CreateInstanceFn, get_proc, null_instance, "vkCreateInstance") orelse
            return error.MissingVkCreateInstance;
        self.vkEnumeratePhysicalDevices = loadSymbol(EnumeratePhysicalDevicesFn, get_proc, null_instance, "vkEnumeratePhysicalDevices");
        self.vkDestroyInstance = loadSymbol(DestroyInstanceFn, get_proc, null_instance, "vkDestroyInstance");
        self.vkGetPhysicalDeviceProperties = loadSymbol(GetPhysicalDevicePropertiesFn, get_proc, null_instance, "vkGetPhysicalDeviceProperties");
        self.vkGetPhysicalDeviceQueueFamilyProperties = loadSymbol(GetPhysicalDeviceQueueFamilyPropertiesFn, get_proc, null_instance, "vkGetPhysicalDeviceQueueFamilyProperties");
        self.vkCreateDevice = loadSymbol(CreateDeviceFn, get_proc, null_instance, "vkCreateDevice");
    }

    fn createInstance(self: *VulkanRenderer) !void {
        const create_fn = self.vkCreateInstance orelse return error.MissingVkCreateInstance;

        var app_info = std.mem.zeroes(vk.VkApplicationInfo);
        app_info.sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app_info.pApplicationName = "DeathTerminal";
        app_info.applicationVersion = vk.raw.VK_MAKE_VERSION(0, 1, 0);
        app_info.pEngineName = "DeathTerminal";
        app_info.engineVersion = vk.raw.VK_MAKE_VERSION(0, 1, 0);
        app_info.apiVersion = vk.raw.VK_API_VERSION_1_0;

        var create_info = std.mem.zeroes(vk.VkInstanceCreateInfo);
        create_info.sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        create_info.pApplicationInfo = &app_info;

        var instance: vk.VkInstance = null;
        const result = create_fn(&create_info, null, &instance);
        if (result != vk.VK_SUCCESS or instance == null) return error.CreateInstanceFailed;

        self.instance = instance;
        self.has_instance = true;

        // Reload instance-level entry points with a real instance.
        const get_proc = self.vkGetInstanceProcAddr;
        if (get_proc) |gpa| {
            self.vkDestroyInstance = loadSymbol(DestroyInstanceFn, gpa, instance, "vkDestroyInstance") orelse self.vkDestroyInstance;
            self.vkEnumeratePhysicalDevices = loadSymbol(EnumeratePhysicalDevicesFn, gpa, instance, "vkEnumeratePhysicalDevices") orelse self.vkEnumeratePhysicalDevices;
            self.vkGetPhysicalDeviceProperties = loadSymbol(GetPhysicalDevicePropertiesFn, gpa, instance, "vkGetPhysicalDeviceProperties") orelse self.vkGetPhysicalDeviceProperties;
            self.vkGetPhysicalDeviceQueueFamilyProperties = loadSymbol(GetPhysicalDeviceQueueFamilyPropertiesFn, gpa, instance, "vkGetPhysicalDeviceQueueFamilyProperties") orelse self.vkGetPhysicalDeviceQueueFamilyProperties;
            self.vkCreateDevice = loadSymbol(CreateDeviceFn, gpa, instance, "vkCreateDevice") orelse self.vkCreateDevice;
        }

        std.debug.print("    → Vulkan instance created\n", .{});
    }

    fn destroyInstance(self: *VulkanRenderer) void {
        if (self.instance != null) {
            if (self.vkDestroyInstance) |destroy_fn| {
                destroy_fn(self.instance, null);
            }
            self.instance = null;
            self.has_instance = false;
        }
    }

    fn selectPhysicalDevice(self: *VulkanRenderer) !void {
        if (self.instance == null) return error.NoInstance;
        const instance = self.instance;
        const enumerate = self.vkEnumeratePhysicalDevices orelse return error.MissingEnumerate;
        const get_props = self.vkGetPhysicalDeviceProperties orelse return error.MissingDeviceProps;
        const get_queues = self.vkGetPhysicalDeviceQueueFamilyProperties orelse return error.MissingQueueFamily;

        var count: u32 = 0;
        if (enumerate(instance, &count, null) != vk.VK_SUCCESS) return error.EnumerateFailed;
        if (count == 0) return error.NoPhysicalDevices;

        const devices = try self.allocator.alloc(vk.VkPhysicalDevice, count);
        defer self.allocator.free(devices);
        if (enumerate(instance, &count, devices.ptr) != vk.VK_SUCCESS) return error.EnumerateFailed;

        var best: vk.VkPhysicalDevice = null;
        var best_score: i32 = -1;
        var best_family: u32 = 0;

        for (devices[0..count]) |dev| {
            if (dev == null) continue;
            var props = std.mem.zeroes(vk.VkPhysicalDeviceProperties);
            get_props(dev, &props);

            var family_count: u32 = 0;
            get_queues(dev, &family_count, null);
            if (family_count == 0) continue;

            const families = try self.allocator.alloc(vk.VkQueueFamilyProperties, family_count);
            defer self.allocator.free(families);
            get_queues(dev, &family_count, families.ptr);

            var graphics_family: ?u32 = null;
            var i: u32 = 0;
            while (i < family_count) : (i += 1) {
                if (families[i].queueFlags & vk.VK_QUEUE_GRAPHICS_BIT != 0) {
                    graphics_family = i;
                    break;
                }
            }
            const family = graphics_family orelse continue;

            var score: i32 = 1;
            if (props.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) score += 1000;
            if (props.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) score += 100;
            if (score > best_score) {
                best_score = score;
                best = dev;
                best_family = family;
            }
        }

        if (best == null) return error.NoGraphicsQueue;
        const chosen = best;
        self.physical_device = chosen;
        self.graphics_queue_family = best_family;

        var props = std.mem.zeroes(vk.VkPhysicalDeviceProperties);
        get_props(chosen, &props);
        const name = std.mem.sliceTo(&props.deviceName, 0);
        std.debug.print("    → Physical device: {s}\n", .{name});
    }

    fn createDevice(self: *VulkanRenderer) !void {
        if (self.physical_device == null) return error.NoPhysicalDevice;
        const physical = self.physical_device;
        const create_fn = self.vkCreateDevice orelse return error.MissingCreateDevice;

        const priority: f32 = 1.0;
        var queue_info = std.mem.zeroes(vk.VkDeviceQueueCreateInfo);
        queue_info.sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_info.queueFamilyIndex = self.graphics_queue_family;
        queue_info.queueCount = 1;
        queue_info.pQueuePriorities = &priority;

        var features = std.mem.zeroes(vk.VkPhysicalDeviceFeatures);
        var create_info = std.mem.zeroes(vk.VkDeviceCreateInfo);
        create_info.sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        create_info.queueCreateInfoCount = 1;
        create_info.pQueueCreateInfos = &queue_info;
        create_info.pEnabledFeatures = &features;

        var device: vk.VkDevice = null;
        const result = create_fn(physical, &create_info, null, &device);
        if (result != vk.VK_SUCCESS or device == null) return error.CreateDeviceFailed;

        self.device = device;
        self.has_device = true;

        if (self.vkGetInstanceProcAddr) |gpa| {
            self.vkGetDeviceQueue = loadSymbol(GetDeviceQueueFn, gpa, self.instance, "vkGetDeviceQueue") orelse
                self.lib.?.lookup(GetDeviceQueueFn, "vkGetDeviceQueue");
            self.vkDestroyDevice = loadSymbol(DestroyDeviceFn, gpa, self.instance, "vkDestroyDevice") orelse
                self.lib.?.lookup(DestroyDeviceFn, "vkDestroyDevice");
        }

        if (self.vkGetDeviceQueue) |gq| {
            var queue: vk.VkQueue = null;
            gq(device, self.graphics_queue_family, 0, &queue);
            self.graphics_queue = queue;
        }

        std.debug.print("    → Logical device created\n", .{});
    }

    fn destroyDevice(self: *VulkanRenderer) void {
        if (self.device != null) {
            if (self.vkDestroyDevice) |destroy_fn| {
                destroy_fn(self.device, null);
            }
            self.device = null;
            self.graphics_queue = null;
            self.has_device = false;
        }
    }

    /// Render a frame
    /// In the future, this will render terminal text to a framebuffer
    pub fn render(self: *VulkanRenderer) !void {
        if (!self.initialized) return error.NotInitialized;
    }

    /// Handle window resize
    pub fn resize(self: *VulkanRenderer, width: u32, height: u32) !void {
        if (!self.initialized) return error.NotInitialized;
        _ = width;
        _ = height;
    }

    /// Render terminal text buffer
    pub fn renderText(
        self: *VulkanRenderer,
        text_buffer: []const u8,
        rows: u32,
        cols: u32,
    ) !void {
        if (!self.initialized) return error.NotInitialized;
        _ = text_buffer;
        _ = rows;
        _ = cols;
    }
};

test "VulkanRenderer init" {
    const testing = std.testing;
    var renderer = try VulkanRenderer.init(testing.allocator);
    defer renderer.deinit();
    try testing.expect(renderer.initialized);
}

test "VulkanRenderer operations" {
    const testing = std.testing;
    var renderer = try VulkanRenderer.init(testing.allocator);
    defer renderer.deinit();

    try renderer.render();
    try renderer.resize(1920, 1080);
}

test "VulkanRenderer loads instance when loader is present" {
    const testing = std.testing;
    var renderer = try VulkanRenderer.init(testing.allocator);
    defer renderer.deinit();
    try testing.expect(renderer.initialized);
    // Loader is present in CI via libvulkan1; instance creation should succeed
    // even when no GPU is attached.
    try testing.expect(renderer.has_instance);
}
