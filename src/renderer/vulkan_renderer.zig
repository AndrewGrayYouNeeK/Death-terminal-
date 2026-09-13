const std = @import("std");
const vk = @import("vulkan_c.zig");
const loader_mod = @import("loader.zig");
const gpu_present = @import("gpu_present.zig");

const Loader = loader_mod.Loader;

/// VulkanRenderer handles GPU-accelerated rendering via the Vulkan loader.
/// Instance/device creation is real; swapchain present is attached when a window exists.
pub const VulkanRenderer = struct {
    allocator: std.mem.Allocator,
    loader: ?Loader,
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    graphics_queue_family: u32,
    initialized: bool,
    has_instance: bool,
    has_device: bool,
    gpu: gpu_present.GpuPresent,

    vkCreateInstance: ?loader_mod.CreateInstanceFn,
    vkDestroyInstance: ?loader_mod.DestroyInstanceFn,
    vkEnumeratePhysicalDevices: ?loader_mod.EnumeratePhysicalDevicesFn,
    vkGetPhysicalDeviceProperties: ?loader_mod.GetPhysicalDevicePropertiesFn,
    vkGetPhysicalDeviceQueueFamilyProperties: ?loader_mod.GetPhysicalDeviceQueueFamilyPropertiesFn,
    vkCreateDevice: ?loader_mod.CreateDeviceFn,
    vkDestroyDevice: ?loader_mod.DestroyDeviceFn,
    vkGetDeviceQueue: ?loader_mod.GetDeviceQueueFn,
    vkGetDeviceProcAddr: ?loader_mod.GetDeviceProcAddrFn,
    vkEnumerateInstanceExtensionProperties: ?loader_mod.EnumerateInstanceExtensionPropertiesFn,
    vkEnumerateDeviceExtensionProperties: ?loader_mod.EnumerateDeviceExtensionPropertiesFn,

    pub fn init(allocator: std.mem.Allocator) !VulkanRenderer {
        std.debug.print("  → Initializing Vulkan renderer...\n", .{});

        var renderer = VulkanRenderer{
            .allocator = allocator,
            .loader = null,
            .instance = null,
            .physical_device = null,
            .device = null,
            .graphics_queue = null,
            .graphics_queue_family = 0,
            .initialized = false,
            .has_instance = false,
            .has_device = false,
            .gpu = .{},
            .vkCreateInstance = null,
            .vkDestroyInstance = null,
            .vkEnumeratePhysicalDevices = null,
            .vkGetPhysicalDeviceProperties = null,
            .vkGetPhysicalDeviceQueueFamilyProperties = null,
            .vkCreateDevice = null,
            .vkDestroyDevice = null,
            .vkGetDeviceQueue = null,
            .vkGetDeviceProcAddr = null,
            .vkEnumerateInstanceExtensionProperties = null,
            .vkEnumerateDeviceExtensionProperties = null,
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

        self.detachPresent();
        self.destroyDevice();
        self.destroyInstance();
        if (self.loader) |*loader| {
            loader.close();
            self.loader = null;
        }
        self.initialized = false;
    }

    fn loadLibrary(self: *VulkanRenderer) !void {
        var opened = try Loader.open();
        errdefer opened.close();

        const null_instance: vk.VkInstance = null;
        self.vkCreateInstance = opened.load(null_instance, loader_mod.CreateInstanceFn, "vkCreateInstance") orelse {
            return error.MissingVkCreateInstance;
        };
        self.vkDestroyInstance = opened.load(null_instance, loader_mod.DestroyInstanceFn, "vkDestroyInstance");
        self.vkEnumeratePhysicalDevices = opened.load(null_instance, loader_mod.EnumeratePhysicalDevicesFn, "vkEnumeratePhysicalDevices");
        self.vkGetPhysicalDeviceProperties = opened.load(null_instance, loader_mod.GetPhysicalDevicePropertiesFn, "vkGetPhysicalDeviceProperties");
        self.vkGetPhysicalDeviceQueueFamilyProperties = opened.load(null_instance, loader_mod.GetPhysicalDeviceQueueFamilyPropertiesFn, "vkGetPhysicalDeviceQueueFamilyProperties");
        self.vkCreateDevice = opened.load(null_instance, loader_mod.CreateDeviceFn, "vkCreateDevice");
        self.vkGetDeviceProcAddr = opened.load(null_instance, loader_mod.GetDeviceProcAddrFn, "vkGetDeviceProcAddr");
        self.vkEnumerateInstanceExtensionProperties = opened.load(null_instance, loader_mod.EnumerateInstanceExtensionPropertiesFn, "vkEnumerateInstanceExtensionProperties");
        self.vkEnumerateDeviceExtensionProperties = opened.load(null_instance, loader_mod.EnumerateDeviceExtensionPropertiesFn, "vkEnumerateDeviceExtensionProperties");

        self.loader = opened;
    }

    fn createInstance(self: *VulkanRenderer) !void {
        const create_fn = self.vkCreateInstance orelse return error.MissingVkCreateInstance;
        const loader = self.loader orelse return error.VulkanLoaderMissing;

        var app_info = std.mem.zeroes(vk.VkApplicationInfo);
        app_info.sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app_info.pApplicationName = "DeathTerminal";
        app_info.applicationVersion = vk.makeApiVersion(0, 1, 0);
        app_info.pEngineName = "DeathTerminal";
        app_info.engineVersion = vk.makeApiVersion(0, 1, 0);
        app_info.apiVersion = vk.API_VERSION_1_0;

        var create_info = std.mem.zeroes(vk.VkInstanceCreateInfo);
        create_info.sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        create_info.pApplicationInfo = &app_info;

        var ext_names: [2][*:0]const u8 = undefined;
        var ext_count: u32 = 0;
        if (self.hasInstanceExtension("VK_KHR_surface")) {
            ext_names[ext_count] = "VK_KHR_surface";
            ext_count += 1;
        }
        if (self.hasInstanceExtension("VK_KHR_xlib_surface")) {
            ext_names[ext_count] = "VK_KHR_xlib_surface";
            ext_count += 1;
        }
        if (ext_count > 0) {
            create_info.enabledExtensionCount = ext_count;
            create_info.ppEnabledExtensionNames = @ptrCast(&ext_names);
            std.debug.print("    → Instance WSI extensions: {d}\n", .{ext_count});
        }

        var instance: vk.VkInstance = null;
        const result = create_fn(&create_info, null, &instance);
        if (result != vk.VK_SUCCESS or instance == null) {
            std.debug.print("    → vkCreateInstance returned {}\n", .{result});
            return error.CreateInstanceFailed;
        }

        self.instance = instance;
        self.has_instance = true;

        self.vkDestroyInstance = loader.load(instance, loader_mod.DestroyInstanceFn, "vkDestroyInstance") orelse self.vkDestroyInstance;
        self.vkEnumeratePhysicalDevices = loader.load(instance, loader_mod.EnumeratePhysicalDevicesFn, "vkEnumeratePhysicalDevices") orelse self.vkEnumeratePhysicalDevices;
        self.vkGetPhysicalDeviceProperties = loader.load(instance, loader_mod.GetPhysicalDevicePropertiesFn, "vkGetPhysicalDeviceProperties") orelse self.vkGetPhysicalDeviceProperties;
        self.vkGetPhysicalDeviceQueueFamilyProperties = loader.load(instance, loader_mod.GetPhysicalDeviceQueueFamilyPropertiesFn, "vkGetPhysicalDeviceQueueFamilyProperties") orelse self.vkGetPhysicalDeviceQueueFamilyProperties;
        self.vkCreateDevice = loader.load(instance, loader_mod.CreateDeviceFn, "vkCreateDevice") orelse self.vkCreateDevice;
        self.vkGetDeviceProcAddr = loader.load(instance, loader_mod.GetDeviceProcAddrFn, "vkGetDeviceProcAddr") orelse self.vkGetDeviceProcAddr;
        self.vkEnumerateDeviceExtensionProperties = loader.load(instance, loader_mod.EnumerateDeviceExtensionPropertiesFn, "vkEnumerateDeviceExtensionProperties") orelse self.vkEnumerateDeviceExtensionProperties;

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

        const swapchain_ext: [*:0]const u8 = "VK_KHR_swapchain";
        if (self.hasDeviceExtension("VK_KHR_swapchain")) {
            create_info.enabledExtensionCount = 1;
            create_info.ppEnabledExtensionNames = @ptrCast(&swapchain_ext);
            std.debug.print("    → Device extension VK_KHR_swapchain enabled\n", .{});
        }

        var device: vk.VkDevice = null;
        const result = create_fn(physical, &create_info, null, &device);
        if (result != vk.VK_SUCCESS or device == null) return error.CreateDeviceFailed;

        self.device = device;
        self.has_device = true;

        if (self.vkGetDeviceProcAddr) |get_device_proc| {
            self.vkGetDeviceQueue = Loader.loadDevice(get_device_proc, device, loader_mod.GetDeviceQueueFn, "vkGetDeviceQueue");
            self.vkDestroyDevice = Loader.loadDevice(get_device_proc, device, loader_mod.DestroyDeviceFn, "vkDestroyDevice");
        }

        if (self.vkGetDeviceQueue == null or self.vkDestroyDevice == null) {
            if (self.loader) |loader| {
                if (self.vkGetDeviceQueue == null) {
                    self.vkGetDeviceQueue = loader.load(self.instance, loader_mod.GetDeviceQueueFn, "vkGetDeviceQueue");
                }
                if (self.vkDestroyDevice == null) {
                    self.vkDestroyDevice = loader.load(self.instance, loader_mod.DestroyDeviceFn, "vkDestroyDevice");
                }
            }
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

    /// Render a frame. Presentation is stubbed until a window/swapchain exists.
    pub fn render(self: *VulkanRenderer) !void {
        if (!self.initialized) return error.NotInitialized;
    }

    pub fn attachX11(self: *VulkanRenderer, display: ?*anyopaque, window: usize, width: u32, height: u32) bool {
        if (!self.has_device or self.loader == null) return false;
        const h = self.presentHandles() orelse return false;
        self.gpu.attachX11(h, display, window, width, height) catch |err| {
            std.debug.print("    → Vulkan present not available ({s}); using XPutImage\n", .{@errorName(err)});
            return false;
        };
        return self.gpu.enabled;
    }

    pub fn detachPresent(self: *VulkanRenderer) void {
        if (self.gpu.enabled or self.gpu.surface != null) {
            if (self.presentHandles()) |h| {
                self.gpu.deinit(h);
            }
        }
    }

    pub fn presentPixels(self: *VulkanRenderer, pixels: []const u32, width: u32, height: u32) bool {
        const h = self.presentHandles() orelse return false;
        return self.gpu.present(h, pixels, width, height);
    }

    fn presentHandles(self: *VulkanRenderer) ?gpu_present.Handles {
        const loader = self.loader orelse return null;
        if (self.instance == null or self.device == null or self.graphics_queue == null) return null;
        return .{
            .allocator = self.allocator,
            .loader = loader,
            .instance = self.instance,
            .physical_device = self.physical_device,
            .device = self.device,
            .queue = self.graphics_queue,
            .queue_family = self.graphics_queue_family,
        };
    }

    fn hasInstanceExtension(self: *VulkanRenderer, name: []const u8) bool {
        const enumerate = self.vkEnumerateInstanceExtensionProperties orelse return false;
        var count: u32 = 0;
        if (enumerate(null, &count, null) != vk.VK_SUCCESS or count == 0) return false;
        const props = self.allocator.alloc(vk.raw.VkExtensionProperties, count) catch return false;
        defer self.allocator.free(props);
        if (enumerate(null, &count, props.ptr) != vk.VK_SUCCESS) return false;
        for (props[0..count]) |p| {
            if (std.mem.eql(u8, std.mem.sliceTo(&p.extensionName, 0), name)) return true;
        }
        return false;
    }

    fn hasDeviceExtension(self: *VulkanRenderer, name: []const u8) bool {
        const enumerate = self.vkEnumerateDeviceExtensionProperties orelse return false;
        if (self.physical_device == null) return false;
        var count: u32 = 0;
        if (enumerate(self.physical_device, null, &count, null) != vk.VK_SUCCESS or count == 0) return false;
        const props = self.allocator.alloc(vk.raw.VkExtensionProperties, count) catch return false;
        defer self.allocator.free(props);
        if (enumerate(self.physical_device, null, &count, props.ptr) != vk.VK_SUCCESS) return false;
        for (props[0..count]) |p| {
            if (std.mem.eql(u8, std.mem.sliceTo(&p.extensionName, 0), name)) return true;
        }
        return false;
    }

    /// Handle window resize.
    pub fn resize(self: *VulkanRenderer, width: u32, height: u32) !void {
        if (!self.initialized) return error.NotInitialized;
        _ = width;
        _ = height;
    }

    /// Render terminal text buffer. GPU upload is stubbed until the text pipeline exists.
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
    try renderer.renderText("", 24, 80);
}

test "VulkanRenderer loads instance when loader is present" {
    const testing = std.testing;
    var renderer = try VulkanRenderer.init(testing.allocator);
    defer renderer.deinit();
    try testing.expect(renderer.initialized);
    try testing.expect(renderer.loader != null);
    try testing.expect(renderer.has_instance);
}

test "makeApiVersion packing" {
    try std.testing.expectEqual(@as(u32, 1 << 22), vk.makeApiVersion(1, 0, 0));
    try std.testing.expectEqual(vk.API_VERSION_1_0, vk.makeApiVersion(1, 0, 0));
}
