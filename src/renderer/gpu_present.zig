const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan_c.zig");
const loader_mod = @import("loader.zig");

const CreateXlibSurfaceFn = *const fn (vk.VkInstance, *const vk.raw.VkXlibSurfaceCreateInfoKHR, ?*const anyopaque, *vk.VkSurfaceKHR) callconv(.C) vk.VkResult;
const DestroySurfaceFn = *const fn (vk.VkInstance, vk.VkSurfaceKHR, ?*const anyopaque) callconv(.C) void;
const GetSurfaceSupportFn = *const fn (vk.VkPhysicalDevice, u32, vk.VkSurfaceKHR, *vk.raw.VkBool32) callconv(.C) vk.VkResult;
const GetSurfaceCapsFn = *const fn (vk.VkPhysicalDevice, vk.VkSurfaceKHR, *vk.VkSurfaceCapabilitiesKHR) callconv(.C) vk.VkResult;
const GetSurfaceFormatsFn = *const fn (vk.VkPhysicalDevice, vk.VkSurfaceKHR, *u32, ?[*]vk.VkSurfaceFormatKHR) callconv(.C) vk.VkResult;
const GetSurfacePresentModesFn = *const fn (vk.VkPhysicalDevice, vk.VkSurfaceKHR, *u32, ?[*]vk.VkPresentModeKHR) callconv(.C) vk.VkResult;
const CreateSwapchainFn = *const fn (vk.VkDevice, *const vk.VkSwapchainCreateInfoKHR, ?*const anyopaque, *vk.VkSwapchainKHR) callconv(.C) vk.VkResult;
const DestroySwapchainFn = *const fn (vk.VkDevice, vk.VkSwapchainKHR, ?*const anyopaque) callconv(.C) void;
const GetSwapchainImagesFn = *const fn (vk.VkDevice, vk.VkSwapchainKHR, *u32, ?[*]vk.VkImage) callconv(.C) vk.VkResult;
const AcquireNextImageFn = *const fn (vk.VkDevice, vk.VkSwapchainKHR, u64, vk.VkSemaphore, vk.VkFence, *u32) callconv(.C) vk.VkResult;
const QueuePresentFn = *const fn (vk.VkQueue, *const vk.raw.VkPresentInfoKHR) callconv(.C) vk.VkResult;
const CreateCommandPoolFn = *const fn (vk.VkDevice, *const vk.raw.VkCommandPoolCreateInfo, ?*const anyopaque, *vk.VkCommandPool) callconv(.C) vk.VkResult;
const DestroyCommandPoolFn = *const fn (vk.VkDevice, vk.VkCommandPool, ?*const anyopaque) callconv(.C) void;
const AllocateCommandBuffersFn = *const fn (vk.VkDevice, *const vk.raw.VkCommandBufferAllocateInfo, [*]vk.VkCommandBuffer) callconv(.C) vk.VkResult;
const BeginCommandBufferFn = *const fn (vk.VkCommandBuffer, *const vk.raw.VkCommandBufferBeginInfo) callconv(.C) vk.VkResult;
const EndCommandBufferFn = *const fn (vk.VkCommandBuffer) callconv(.C) vk.VkResult;
const ResetCommandBufferFn = *const fn (vk.VkCommandBuffer, vk.raw.VkCommandBufferResetFlags) callconv(.C) vk.VkResult;
const QueueSubmitFn = *const fn (vk.VkQueue, u32, [*]const vk.raw.VkSubmitInfo, vk.VkFence) callconv(.C) vk.VkResult;
const QueueWaitIdleFn = *const fn (vk.VkQueue) callconv(.C) vk.VkResult;
const CreateBufferFn = *const fn (vk.VkDevice, *const vk.raw.VkBufferCreateInfo, ?*const anyopaque, *vk.VkBuffer) callconv(.C) vk.VkResult;
const DestroyBufferFn = *const fn (vk.VkDevice, vk.VkBuffer, ?*const anyopaque) callconv(.C) void;
const GetBufferMemoryRequirementsFn = *const fn (vk.VkDevice, vk.VkBuffer, *vk.raw.VkMemoryRequirements) callconv(.C) void;
const GetPhysicalDeviceMemoryPropertiesFn = *const fn (vk.VkPhysicalDevice, *vk.raw.VkPhysicalDeviceMemoryProperties) callconv(.C) void;
const AllocateMemoryFn = *const fn (vk.VkDevice, *const vk.raw.VkMemoryAllocateInfo, ?*const anyopaque, *vk.VkDeviceMemory) callconv(.C) vk.VkResult;
const FreeMemoryFn = *const fn (vk.VkDevice, vk.VkDeviceMemory, ?*const anyopaque) callconv(.C) void;
const BindBufferMemoryFn = *const fn (vk.VkDevice, vk.VkBuffer, vk.VkDeviceMemory, vk.raw.VkDeviceSize) callconv(.C) vk.VkResult;
const MapMemoryFn = *const fn (vk.VkDevice, vk.VkDeviceMemory, vk.raw.VkDeviceSize, vk.raw.VkDeviceSize, vk.raw.VkMemoryMapFlags, *?*anyopaque) callconv(.C) vk.VkResult;
const UnmapMemoryFn = *const fn (vk.VkDevice, vk.VkDeviceMemory) callconv(.C) void;
const CmdPipelineBarrierFn = *const fn (vk.VkCommandBuffer, vk.raw.VkPipelineStageFlags, vk.raw.VkPipelineStageFlags, vk.raw.VkDependencyFlags, u32, ?[*]const vk.raw.VkMemoryBarrier, u32, ?[*]const vk.raw.VkBufferMemoryBarrier, u32, ?[*]const vk.raw.VkImageMemoryBarrier) callconv(.C) void;
const CmdCopyBufferToImageFn = *const fn (vk.VkCommandBuffer, vk.VkBuffer, vk.VkImage, vk.raw.VkImageLayout, u32, [*]const vk.raw.VkBufferImageCopy) callconv(.C) void;
const CreateFenceFn = *const fn (vk.VkDevice, *const vk.raw.VkFenceCreateInfo, ?*const anyopaque, *vk.VkFence) callconv(.C) vk.VkResult;
const DestroyFenceFn = *const fn (vk.VkDevice, vk.VkFence, ?*const anyopaque) callconv(.C) void;
const WaitForFencesFn = *const fn (vk.VkDevice, u32, [*]const vk.VkFence, vk.raw.VkBool32, u64) callconv(.C) vk.VkResult;
const ResetFencesFn = *const fn (vk.VkDevice, u32, [*]const vk.VkFence) callconv(.C) vk.VkResult;

pub const Handles = struct {
    allocator: std.mem.Allocator,
    loader: loader_mod.Loader,
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family: u32,
};

/// Copies the software RGBA framebuffer into a Vulkan swapchain image and presents it.
pub const GpuPresent = struct {
    enabled: bool = false,
    surface: vk.VkSurfaceKHR = null,
    swapchain: vk.VkSwapchainKHR = null,
    images: []vk.VkImage = &.{},
    format: vk.VkFormat = vk.VK_FORMAT_B8G8R8A8_SRGB,
    extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },
    command_pool: vk.VkCommandPool = null,
    command_buffer: vk.VkCommandBuffer = null,
    staging: vk.VkBuffer = null,
    staging_mem: vk.VkDeviceMemory = null,
    staging_size: usize = 0,
    acquire_fence: vk.VkFence = null,
    allocator: std.mem.Allocator = undefined,

    vkCreateXlibSurfaceKHR: ?CreateXlibSurfaceFn = null,
    vkDestroySurfaceKHR: ?DestroySurfaceFn = null,
    vkGetPhysicalDeviceSurfaceSupportKHR: ?GetSurfaceSupportFn = null,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: ?GetSurfaceCapsFn = null,
    vkGetPhysicalDeviceSurfaceFormatsKHR: ?GetSurfaceFormatsFn = null,
    vkGetPhysicalDeviceSurfacePresentModesKHR: ?GetSurfacePresentModesFn = null,
    vkCreateSwapchainKHR: ?CreateSwapchainFn = null,
    vkDestroySwapchainKHR: ?DestroySwapchainFn = null,
    vkGetSwapchainImagesKHR: ?GetSwapchainImagesFn = null,
    vkAcquireNextImageKHR: ?AcquireNextImageFn = null,
    vkQueuePresentKHR: ?QueuePresentFn = null,
    vkCreateCommandPool: ?CreateCommandPoolFn = null,
    vkDestroyCommandPool: ?DestroyCommandPoolFn = null,
    vkAllocateCommandBuffers: ?AllocateCommandBuffersFn = null,
    vkBeginCommandBuffer: ?BeginCommandBufferFn = null,
    vkEndCommandBuffer: ?EndCommandBufferFn = null,
    vkResetCommandBuffer: ?ResetCommandBufferFn = null,
    vkQueueSubmit: ?QueueSubmitFn = null,
    vkQueueWaitIdle: ?QueueWaitIdleFn = null,
    vkCreateBuffer: ?CreateBufferFn = null,
    vkDestroyBuffer: ?DestroyBufferFn = null,
    vkGetBufferMemoryRequirements: ?GetBufferMemoryRequirementsFn = null,
    vkGetPhysicalDeviceMemoryProperties: ?GetPhysicalDeviceMemoryPropertiesFn = null,
    vkAllocateMemory: ?AllocateMemoryFn = null,
    vkFreeMemory: ?FreeMemoryFn = null,
    vkBindBufferMemory: ?BindBufferMemoryFn = null,
    vkMapMemory: ?MapMemoryFn = null,
    vkUnmapMemory: ?UnmapMemoryFn = null,
    vkCmdPipelineBarrier: ?CmdPipelineBarrierFn = null,
    vkCmdCopyBufferToImage: ?CmdCopyBufferToImageFn = null,
    vkCreateFence: ?CreateFenceFn = null,
    vkDestroyFence: ?DestroyFenceFn = null,
    vkWaitForFences: ?WaitForFencesFn = null,
    vkResetFences: ?ResetFencesFn = null,

    pub fn deinit(self: *GpuPresent, h: Handles) void {
        if (h.queue != null) {
            if (self.vkQueueWaitIdle) |wait| _ = wait(h.queue);
        }
        self.destroySwapchain(h);
        if (self.surface != null) {
            if (self.vkDestroySurfaceKHR) |destroy| destroy(h.instance, self.surface, null);
            self.surface = null;
        }
        self.enabled = false;
    }

    pub fn attachX11(self: *GpuPresent, h: Handles, display: ?*anyopaque, window: usize, width: u32, height: u32) !void {
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
        if (display == null or window == 0) return error.NoNativeWindow;
        if (h.device == null or h.instance == null) return error.NoDevice;

        self.allocator = h.allocator;
        self.loadProcs(h) catch return error.MissingPresentProcs;
        errdefer self.deinit(h);

        var info = std.mem.zeroes(vk.raw.VkXlibSurfaceCreateInfoKHR);
        info.sType = vk.raw.VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR;
        info.dpy = @ptrCast(display);
        info.window = @intCast(window);

        const create_surface = self.vkCreateXlibSurfaceKHR orelse return error.MissingCreateSurface;
        var surface: vk.VkSurfaceKHR = null;
        if (create_surface(h.instance, &info, null, &surface) != vk.VK_SUCCESS or surface == null) {
            return error.CreateSurfaceFailed;
        }
        self.surface = surface;

        var supported: vk.raw.VkBool32 = vk.VK_FALSE;
        const support = self.vkGetPhysicalDeviceSurfaceSupportKHR orelse return error.MissingSurfaceSupport;
        if (support(h.physical_device, h.queue_family, surface, &supported) != vk.VK_SUCCESS or supported == vk.VK_FALSE) {
            return error.QueueCannotPresent;
        }

        try self.createSwapchain(h, width, height);
        try self.createCommands(h);
        self.enabled = true;
        std.debug.print("    → Vulkan swapchain present enabled ({d}x{d})\n", .{ self.extent.width, self.extent.height });
    }

    pub fn present(self: *GpuPresent, h: Handles, pixels: []const u32, width: u32, height: u32) bool {
        if (!self.enabled) return false;
        self.presentFrame(h, pixels, width, height) catch return false;
        return true;
    }

    fn loadProcs(self: *GpuPresent, h: Handles) !void {
        const l = h.loader;
        const inst = h.instance;
        const dev = h.device;
        const gdp = l.load(inst, loader_mod.GetDeviceProcAddrFn, "vkGetDeviceProcAddr");

        self.vkCreateXlibSurfaceKHR = l.load(inst, CreateXlibSurfaceFn, "vkCreateXlibSurfaceKHR");
        self.vkDestroySurfaceKHR = l.load(inst, DestroySurfaceFn, "vkDestroySurfaceKHR");
        self.vkGetPhysicalDeviceSurfaceSupportKHR = l.load(inst, GetSurfaceSupportFn, "vkGetPhysicalDeviceSurfaceSupportKHR");
        self.vkGetPhysicalDeviceSurfaceCapabilitiesKHR = l.load(inst, GetSurfaceCapsFn, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
        self.vkGetPhysicalDeviceSurfaceFormatsKHR = l.load(inst, GetSurfaceFormatsFn, "vkGetPhysicalDeviceSurfaceFormatsKHR");
        self.vkGetPhysicalDeviceSurfacePresentModesKHR = l.load(inst, GetSurfacePresentModesFn, "vkGetPhysicalDeviceSurfacePresentModesKHR");
        self.vkGetPhysicalDeviceMemoryProperties = l.load(inst, GetPhysicalDeviceMemoryPropertiesFn, "vkGetPhysicalDeviceMemoryProperties");

        if (gdp) |get_dev| {
            self.vkCreateSwapchainKHR = loader_mod.Loader.loadDevice(get_dev, dev, CreateSwapchainFn, "vkCreateSwapchainKHR");
            self.vkDestroySwapchainKHR = loader_mod.Loader.loadDevice(get_dev, dev, DestroySwapchainFn, "vkDestroySwapchainKHR");
            self.vkGetSwapchainImagesKHR = loader_mod.Loader.loadDevice(get_dev, dev, GetSwapchainImagesFn, "vkGetSwapchainImagesKHR");
            self.vkAcquireNextImageKHR = loader_mod.Loader.loadDevice(get_dev, dev, AcquireNextImageFn, "vkAcquireNextImageKHR");
            self.vkQueuePresentKHR = loader_mod.Loader.loadDevice(get_dev, dev, QueuePresentFn, "vkQueuePresentKHR");
            self.vkCreateCommandPool = loader_mod.Loader.loadDevice(get_dev, dev, CreateCommandPoolFn, "vkCreateCommandPool");
            self.vkDestroyCommandPool = loader_mod.Loader.loadDevice(get_dev, dev, DestroyCommandPoolFn, "vkDestroyCommandPool");
            self.vkAllocateCommandBuffers = loader_mod.Loader.loadDevice(get_dev, dev, AllocateCommandBuffersFn, "vkAllocateCommandBuffers");
            self.vkBeginCommandBuffer = loader_mod.Loader.loadDevice(get_dev, dev, BeginCommandBufferFn, "vkBeginCommandBuffer");
            self.vkEndCommandBuffer = loader_mod.Loader.loadDevice(get_dev, dev, EndCommandBufferFn, "vkEndCommandBuffer");
            self.vkResetCommandBuffer = loader_mod.Loader.loadDevice(get_dev, dev, ResetCommandBufferFn, "vkResetCommandBuffer");
            self.vkQueueSubmit = loader_mod.Loader.loadDevice(get_dev, dev, QueueSubmitFn, "vkQueueSubmit");
            self.vkQueueWaitIdle = loader_mod.Loader.loadDevice(get_dev, dev, QueueWaitIdleFn, "vkQueueWaitIdle");
            self.vkCreateBuffer = loader_mod.Loader.loadDevice(get_dev, dev, CreateBufferFn, "vkCreateBuffer");
            self.vkDestroyBuffer = loader_mod.Loader.loadDevice(get_dev, dev, DestroyBufferFn, "vkDestroyBuffer");
            self.vkGetBufferMemoryRequirements = loader_mod.Loader.loadDevice(get_dev, dev, GetBufferMemoryRequirementsFn, "vkGetBufferMemoryRequirements");
            self.vkAllocateMemory = loader_mod.Loader.loadDevice(get_dev, dev, AllocateMemoryFn, "vkAllocateMemory");
            self.vkFreeMemory = loader_mod.Loader.loadDevice(get_dev, dev, FreeMemoryFn, "vkFreeMemory");
            self.vkBindBufferMemory = loader_mod.Loader.loadDevice(get_dev, dev, BindBufferMemoryFn, "vkBindBufferMemory");
            self.vkMapMemory = loader_mod.Loader.loadDevice(get_dev, dev, MapMemoryFn, "vkMapMemory");
            self.vkUnmapMemory = loader_mod.Loader.loadDevice(get_dev, dev, UnmapMemoryFn, "vkUnmapMemory");
            self.vkCmdPipelineBarrier = loader_mod.Loader.loadDevice(get_dev, dev, CmdPipelineBarrierFn, "vkCmdPipelineBarrier");
            self.vkCmdCopyBufferToImage = loader_mod.Loader.loadDevice(get_dev, dev, CmdCopyBufferToImageFn, "vkCmdCopyBufferToImage");
            self.vkCreateFence = loader_mod.Loader.loadDevice(get_dev, dev, CreateFenceFn, "vkCreateFence");
            self.vkDestroyFence = loader_mod.Loader.loadDevice(get_dev, dev, DestroyFenceFn, "vkDestroyFence");
            self.vkWaitForFences = loader_mod.Loader.loadDevice(get_dev, dev, WaitForFencesFn, "vkWaitForFences");
            self.vkResetFences = loader_mod.Loader.loadDevice(get_dev, dev, ResetFencesFn, "vkResetFences");
        }

        if (self.vkCreateXlibSurfaceKHR == null or self.vkCreateSwapchainKHR == null or self.vkQueuePresentKHR == null) {
            std.debug.print("    → present procs xlib={} swap={} present={}\n", .{
                self.vkCreateXlibSurfaceKHR != null,
                self.vkCreateSwapchainKHR != null,
                self.vkQueuePresentKHR != null,
            });
            return error.MissingPresentProcs;
        }
    }

    fn createSwapchain(self: *GpuPresent, h: Handles, width: u32, height: u32) !void {
        const caps_fn = self.vkGetPhysicalDeviceSurfaceCapabilitiesKHR orelse return error.MissingCaps;
        const formats_fn = self.vkGetPhysicalDeviceSurfaceFormatsKHR orelse return error.MissingFormats;
        var caps = std.mem.zeroes(vk.VkSurfaceCapabilitiesKHR);
        if (caps_fn(h.physical_device, self.surface, &caps) != vk.VK_SUCCESS) return error.SurfaceCapsFailed;
        if (caps.supportedUsageFlags & vk.raw.VK_IMAGE_USAGE_TRANSFER_DST_BIT == 0) return error.NoTransferDst;

        var format_count: u32 = 0;
        if (formats_fn(h.physical_device, self.surface, &format_count, null) != vk.VK_SUCCESS or format_count == 0) return error.NoSurfaceFormats;
        const formats = try h.allocator.alloc(vk.VkSurfaceFormatKHR, format_count);
        defer h.allocator.free(formats);
        if (formats_fn(h.physical_device, self.surface, &format_count, formats.ptr) != vk.VK_SUCCESS) return error.NoSurfaceFormats;

        var chosen = formats[0];
        for (formats[0..format_count]) |fmt| {
            if (fmt.format == vk.VK_FORMAT_B8G8R8A8_SRGB or fmt.format == vk.raw.VK_FORMAT_B8G8R8A8_UNORM) {
                chosen = fmt;
                break;
            }
        }

        var extent = caps.currentExtent;
        if (extent.width == 0xFFFFFFFF) {
            extent.width = std.math.clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width);
            extent.height = std.math.clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height);
        }
        if (extent.width == 0 or extent.height == 0) return error.ZeroExtent;

        var image_count = caps.minImageCount + 1;
        if (caps.maxImageCount > 0 and image_count > caps.maxImageCount) image_count = caps.maxImageCount;

        var sci = std.mem.zeroes(vk.VkSwapchainCreateInfoKHR);
        sci.sType = vk.raw.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        sci.surface = self.surface;
        sci.minImageCount = image_count;
        sci.imageFormat = chosen.format;
        sci.imageColorSpace = chosen.colorSpace;
        sci.imageExtent = extent;
        sci.imageArrayLayers = 1;
        sci.imageUsage = vk.raw.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        sci.imageSharingMode = vk.raw.VK_SHARING_MODE_EXCLUSIVE;
        sci.preTransform = caps.currentTransform;
        sci.compositeAlpha = vk.raw.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        sci.presentMode = vk.VK_PRESENT_MODE_FIFO_KHR;
        sci.clipped = vk.VK_TRUE;

        const create = self.vkCreateSwapchainKHR orelse return error.MissingCreateSwapchain;
        var swap: vk.VkSwapchainKHR = null;
        if (create(h.device, &sci, null, &swap) != vk.VK_SUCCESS or swap == null) return error.CreateSwapchainFailed;
        self.swapchain = swap;
        self.format = chosen.format;
        self.extent = extent;

        const get_images = self.vkGetSwapchainImagesKHR orelse return error.MissingSwapchainImages;
        var img_count: u32 = 0;
        if (get_images(h.device, swap, &img_count, null) != vk.VK_SUCCESS or img_count == 0) return error.SwapchainImagesFailed;
        const images = try h.allocator.alloc(vk.VkImage, img_count);
        if (get_images(h.device, swap, &img_count, images.ptr) != vk.VK_SUCCESS) {
            h.allocator.free(images);
            return error.SwapchainImagesFailed;
        }
        self.images = images;
    }

    fn createCommands(self: *GpuPresent, h: Handles) !void {
        var pool_info = std.mem.zeroes(vk.raw.VkCommandPoolCreateInfo);
        pool_info.sType = vk.raw.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.queueFamilyIndex = h.queue_family;
        pool_info.flags = vk.raw.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;

        const create_pool = self.vkCreateCommandPool orelse return error.MissingCommandPool;
        var pool: vk.VkCommandPool = null;
        if (create_pool(h.device, &pool_info, null, &pool) != vk.VK_SUCCESS or pool == null) return error.CreateCommandPoolFailed;
        self.command_pool = pool;

        var alloc_info = std.mem.zeroes(vk.raw.VkCommandBufferAllocateInfo);
        alloc_info.sType = vk.raw.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.commandPool = pool;
        alloc_info.level = vk.raw.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandBufferCount = 1;

        const alloc = self.vkAllocateCommandBuffers orelse return error.MissingAllocCmd;
        var cmd: vk.VkCommandBuffer = null;
        if (alloc(h.device, &alloc_info, @ptrCast(&cmd)) != vk.VK_SUCCESS or cmd == null) return error.AllocCommandBufferFailed;
        self.command_buffer = cmd;

        const bytes = @as(usize, self.extent.width) * @as(usize, self.extent.height) * 4;
        try self.createStaging(h, bytes);

        var fence_info = std.mem.zeroes(vk.raw.VkFenceCreateInfo);
        fence_info.sType = vk.raw.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        const create_fence = self.vkCreateFence orelse return error.MissingFence;
        var fence: vk.VkFence = null;
        if (create_fence(h.device, &fence_info, null, &fence) != vk.VK_SUCCESS or fence == null) return error.CreateFenceFailed;
        self.acquire_fence = fence;
    }

    fn createStaging(self: *GpuPresent, h: Handles, bytes: usize) !void {
        var buf_info = std.mem.zeroes(vk.raw.VkBufferCreateInfo);
        buf_info.sType = vk.raw.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        buf_info.size = bytes;
        buf_info.usage = vk.raw.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        buf_info.sharingMode = vk.raw.VK_SHARING_MODE_EXCLUSIVE;

        const create_buf = self.vkCreateBuffer orelse return error.MissingCreateBuffer;
        var buffer: vk.VkBuffer = null;
        if (create_buf(h.device, &buf_info, null, &buffer) != vk.VK_SUCCESS or buffer == null) return error.CreateBufferFailed;

        var reqs = std.mem.zeroes(vk.raw.VkMemoryRequirements);
        const get_reqs = self.vkGetBufferMemoryRequirements orelse return error.MissingMemReqs;
        get_reqs(h.device, buffer, &reqs);

        var mem_props = std.mem.zeroes(vk.raw.VkPhysicalDeviceMemoryProperties);
        const get_props = self.vkGetPhysicalDeviceMemoryProperties orelse return error.MissingMemProps;
        get_props(h.physical_device, &mem_props);

        const mem_type = findMemoryType(mem_props, reqs.memoryTypeBits, vk.raw.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.raw.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return error.NoHostMemory;

        var alloc_info = std.mem.zeroes(vk.raw.VkMemoryAllocateInfo);
        alloc_info.sType = vk.raw.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = reqs.size;
        alloc_info.memoryTypeIndex = mem_type;

        const alloc_mem = self.vkAllocateMemory orelse return error.MissingAllocMem;
        var memory: vk.VkDeviceMemory = null;
        if (alloc_mem(h.device, &alloc_info, null, &memory) != vk.VK_SUCCESS or memory == null) return error.AllocateMemoryFailed;

        const bind = self.vkBindBufferMemory orelse return error.MissingBind;
        if (bind(h.device, buffer, memory, 0) != vk.VK_SUCCESS) return error.BindMemoryFailed;

        self.staging = buffer;
        self.staging_mem = memory;
        self.staging_size = bytes;
    }

    fn destroySwapchain(self: *GpuPresent, h: Handles) void {
        if (self.acquire_fence != null) {
            if (self.vkDestroyFence) |d| d(h.device, self.acquire_fence, null);
            self.acquire_fence = null;
        }
        if (self.staging != null) {
            if (self.vkDestroyBuffer) |d| d(h.device, self.staging, null);
            self.staging = null;
        }
        if (self.staging_mem != null) {
            if (self.vkFreeMemory) |d| d(h.device, self.staging_mem, null);
            self.staging_mem = null;
        }
        if (self.command_pool != null) {
            if (self.vkDestroyCommandPool) |d| d(h.device, self.command_pool, null);
            self.command_pool = null;
            self.command_buffer = null;
        }
        if (self.swapchain != null) {
            if (self.vkDestroySwapchainKHR) |d| d(h.device, self.swapchain, null);
            self.swapchain = null;
        }
        if (self.images.len != 0) {
            self.allocator.free(self.images);
            self.images = &.{};
        }
        self.staging_size = 0;
    }

    fn presentFrame(self: *GpuPresent, h: Handles, pixels: []const u32, width: u32, height: u32) !void {
        const copy_w = @min(width, self.extent.width);
        const copy_h = @min(height, self.extent.height);
        if (copy_w == 0 or copy_h == 0) return error.ZeroCopy;

        try self.uploadStaging(h, pixels, width, height, copy_w, copy_h);

        var index: u32 = 0;
        const acquire = self.vkAcquireNextImageKHR orelse return error.MissingAcquire;
        const wait_fences = self.vkWaitForFences orelse return error.MissingWaitFence;
        const reset_fences = self.vkResetFences orelse return error.MissingResetFence;
        _ = reset_fences(h.device, 1, @ptrCast(&self.acquire_fence));
        const acq = acquire(h.device, self.swapchain, std.math.maxInt(u64), null, self.acquire_fence, &index);
        if (acq != vk.VK_SUCCESS and acq != vk.raw.VK_SUBOPTIMAL_KHR) return error.AcquireFailed;
        _ = wait_fences(h.device, 1, @ptrCast(&self.acquire_fence), vk.VK_TRUE, std.math.maxInt(u64));
        if (index >= self.images.len) return error.BadImageIndex;

        const cmd = self.command_buffer orelse return error.NoCommandBuffer;
        if (self.vkResetCommandBuffer) |reset| _ = reset(cmd, 0);

        var begin_info = std.mem.zeroes(vk.raw.VkCommandBufferBeginInfo);
        begin_info.sType = vk.raw.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = vk.raw.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        const begin = self.vkBeginCommandBuffer orelse return error.MissingBegin;
        if (begin(cmd, &begin_info) != vk.VK_SUCCESS) return error.BeginFailed;

        const image = self.images[index];
        const barrier_fn = self.vkCmdPipelineBarrier orelse return error.MissingBarrier;
        var to_dst = imageBarrier(image, vk.raw.VK_IMAGE_LAYOUT_UNDEFINED, vk.raw.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, vk.raw.VK_ACCESS_TRANSFER_WRITE_BIT);
        barrier_fn(cmd, vk.raw.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.raw.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, @ptrCast(&to_dst));

        var region = std.mem.zeroes(vk.raw.VkBufferImageCopy);
        region.imageSubresource.aspectMask = vk.raw.VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = .{ .width = copy_w, .height = copy_h, .depth = 1 };
        const copy_fn = self.vkCmdCopyBufferToImage orelse return error.MissingCopy;
        copy_fn(cmd, self.staging, image, vk.raw.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @ptrCast(&region));

        var to_present = imageBarrier(image, vk.raw.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.raw.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, vk.raw.VK_ACCESS_TRANSFER_WRITE_BIT, vk.raw.VK_ACCESS_MEMORY_READ_BIT);
        barrier_fn(cmd, vk.raw.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.raw.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 1, @ptrCast(&to_present));

        const end = self.vkEndCommandBuffer orelse return error.MissingEnd;
        if (end(cmd) != vk.VK_SUCCESS) return error.EndFailed;

        var submit = std.mem.zeroes(vk.raw.VkSubmitInfo);
        submit.sType = vk.raw.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = @ptrCast(&cmd);
        const qsubmit = self.vkQueueSubmit orelse return error.MissingSubmit;
        if (qsubmit(h.queue, 1, @ptrCast(&submit), null) != vk.VK_SUCCESS) return error.SubmitFailed;
        if (self.vkQueueWaitIdle) |wait| _ = wait(h.queue);

        var present_info = std.mem.zeroes(vk.raw.VkPresentInfoKHR);
        present_info.sType = vk.raw.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present_info.swapchainCount = 1;
        present_info.pSwapchains = @ptrCast(&self.swapchain);
        present_info.pImageIndices = &index;
        const qpresent = self.vkQueuePresentKHR orelse return error.MissingPresent;
        const pres = qpresent(h.queue, &present_info);
        if (pres != vk.VK_SUCCESS and pres != vk.raw.VK_SUBOPTIMAL_KHR) return error.PresentFailed;
    }

    fn uploadStaging(self: *GpuPresent, h: Handles, pixels: []const u32, src_w: u32, src_h: u32, copy_w: u32, copy_h: u32) !void {
        _ = src_h;
        const map = self.vkMapMemory orelse return error.MissingMap;
        var mapped: ?*anyopaque = null;
        if (map(h.device, self.staging_mem, 0, self.staging_size, 0, &mapped) != vk.VK_SUCCESS) return error.MapFailed;
        defer if (self.vkUnmapMemory) |unmap| unmap(h.device, self.staging_mem);

        const dest = @as([*]u32, @ptrCast(@alignCast(mapped.?)));
        const dst_w = self.extent.width;
        var y: u32 = 0;
        while (y < copy_h) : (y += 1) {
            var x: u32 = 0;
            while (x < copy_w) : (x += 1) {
                const src = pixels[y * src_w + x];
                dest[y * dst_w + x] = swizzle(self.format, src);
            }
        }
    }
};

fn swizzle(format: vk.VkFormat, px: u32) u32 {
    // Source is 0xAARRGGBB. B8G8R8A8 wants B,G,R,A in memory (little-endian 0xAARRGGBB already).
    if (format == vk.VK_FORMAT_R8G8B8A8_SRGB or format == vk.raw.VK_FORMAT_R8G8B8A8_UNORM) {
        const a = (px >> 24) & 0xFF;
        const r = (px >> 16) & 0xFF;
        const g = (px >> 8) & 0xFF;
        const b = px & 0xFF;
        return (a << 24) | (b << 16) | (g << 8) | r;
    }
    return px;
}

fn imageBarrier(image: vk.VkImage, old_layout: vk.raw.VkImageLayout, new_layout: vk.raw.VkImageLayout, src_access: vk.raw.VkAccessFlags, dst_access: vk.raw.VkAccessFlags) vk.raw.VkImageMemoryBarrier {
    var barrier = std.mem.zeroes(vk.raw.VkImageMemoryBarrier);
    barrier.sType = vk.raw.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.oldLayout = old_layout;
    barrier.newLayout = new_layout;
    barrier.srcQueueFamilyIndex = vk.raw.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = vk.raw.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.srcAccessMask = src_access;
    barrier.dstAccessMask = dst_access;
    barrier.subresourceRange = .{
        .aspectMask = vk.raw.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
    return barrier;
}

fn findMemoryType(props: vk.raw.VkPhysicalDeviceMemoryProperties, type_filter: u32, flags: u32) ?u32 {
    var i: u32 = 0;
    while (i < props.memoryTypeCount) : (i += 1) {
        if ((type_filter & (@as(u32, 1) << @intCast(i))) != 0 and
            (props.memoryTypes[i].propertyFlags & flags) == flags)
        {
            return i;
        }
    }
    return null;
}

test "GpuPresent starts disabled" {
    const p = GpuPresent{};
    try std.testing.expect(!p.enabled);
}
