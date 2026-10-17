const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan_c.zig");
const loader_mod = @import("loader.zig");

const CreateXlibSurfaceFn = if (builtin.os.tag == .linux) *const fn (vk.VkInstance, *const vk.raw.VkXlibSurfaceCreateInfoKHR, ?*const anyopaque, *vk.VkSurfaceKHR) callconv(.C) vk.VkResult else *const fn () callconv(.C) void;
const CreateWaylandSurfaceFn = if (builtin.os.tag == .linux) *const fn (vk.VkInstance, *const vk.raw.VkWaylandSurfaceCreateInfoKHR, ?*const anyopaque, *vk.VkSurfaceKHR) callconv(.C) vk.VkResult else *const fn () callconv(.C) void;
/// VkWin32SurfaceCreateInfoKHR with untyped handles (the C HWND/HINSTANCE
/// types carry alignment that real handle values don't have).
const Win32SurfaceInfo = extern struct {
    sType: vk.raw.VkStructureType = vk.raw.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    hinstance: ?*anyopaque,
    hwnd: ?*anyopaque,
};
const CreateWin32SurfaceFn = *const fn (vk.VkInstance, *const Win32SurfaceInfo, ?*const anyopaque, *vk.VkSurfaceKHR) callconv(.C) vk.VkResult;
/// VkMetalSurfaceCreateInfoEXT (VK_EXT_metal_surface, MoltenVK).
const MetalSurfaceInfo = extern struct {
    sType: vk.raw.VkStructureType = 1000217000, // VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    pLayer: ?*const anyopaque,
};
const CreateMetalSurfaceFn = *const fn (vk.VkInstance, *const MetalSurfaceInfo, ?*const anyopaque, *vk.VkSurfaceKHR) callconv(.C) vk.VkResult;
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
const CreateSemaphoreFn = *const fn (vk.VkDevice, *const vk.raw.VkSemaphoreCreateInfo, ?*const anyopaque, *vk.VkSemaphore) callconv(.C) vk.VkResult;
const DestroySemaphoreFn = *const fn (vk.VkDevice, vk.VkSemaphore, ?*const anyopaque) callconv(.C) void;

/// Frames the CPU may record ahead of the GPU.
pub const MAX_FRAMES_IN_FLIGHT = 2;

/// Swapchain present mode preference (`present_mode` config key).
pub const PresentMode = enum {
    /// Vsync, never tears (always supported).
    fifo,
    /// Vsync but late frames tear (adaptive).
    fifo_relaxed,
    /// Latest frame wins at vblank: low latency, no tearing.
    mailbox,
    /// No vsync; may tear.
    immediate,

    pub fn parse(s: []const u8) ?PresentMode {
        if (std.ascii.eqlIgnoreCase(s, "vsync")) return .fifo;
        return std.meta.stringToEnum(PresentMode, s);
    }

    fn vk_value(self: PresentMode) vk.VkPresentModeKHR {
        return switch (self) {
            .fifo => vk.raw.VK_PRESENT_MODE_FIFO_KHR,
            .fifo_relaxed => vk.raw.VK_PRESENT_MODE_FIFO_RELAXED_KHR,
            .mailbox => vk.raw.VK_PRESENT_MODE_MAILBOX_KHR,
            .immediate => vk.raw.VK_PRESENT_MODE_IMMEDIATE_KHR,
        };
    }
};

/// The frame being recorded: swapchain image + per-frame slot resources.
pub const FrameCtx = struct {
    image: u32,
    slot: u32,
    cmd: vk.VkCommandBuffer,
};

pub const Handles = struct {
    allocator: std.mem.Allocator,
    loader: loader_mod.Loader,
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family: u32,
};

/// Owns the surface + swapchain and paces frames: each of the
/// MAX_FRAMES_IN_FLIGHT slots has its own command buffer, image-available
/// semaphore and fence, so the CPU records frame N+1 while the GPU draws N
/// and never waits for the queue to go idle. Also presents the software
/// RGBA framebuffer by copying it into a swapchain image.
pub const GpuPresent = struct {
    enabled: bool = false,
    surface: vk.VkSurfaceKHR = null,
    swapchain: vk.VkSwapchainKHR = null,
    images: []vk.VkImage = &.{},
    format: vk.VkFormat = vk.VK_FORMAT_B8G8R8A8_SRGB,
    extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },
    command_pool: vk.VkCommandPool = null,
    command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.VkCommandBuffer = .{null} ** MAX_FRAMES_IN_FLIGHT,
    image_available: [MAX_FRAMES_IN_FLIGHT]vk.VkSemaphore = .{null} ** MAX_FRAMES_IN_FLIGHT,
    in_flight: [MAX_FRAMES_IN_FLIGHT]vk.VkFence = .{null} ** MAX_FRAMES_IN_FLIGHT,
    /// Per swapchain image: signalled when its rendering is done.
    render_finished: []vk.VkSemaphore = &.{},
    /// Per swapchain image: fence of the slot that last rendered it.
    images_in_flight: []vk.VkFence = &.{},
    slot: u32 = 0,
    /// Software-framebuffer staging, one per slot.
    staging: [MAX_FRAMES_IN_FLIGHT]vk.VkBuffer = .{null} ** MAX_FRAMES_IN_FLIGHT,
    staging_mem: [MAX_FRAMES_IN_FLIGHT]vk.VkDeviceMemory = .{null} ** MAX_FRAMES_IN_FLIGHT,
    staging_size: usize = 0,
    allocator: std.mem.Allocator = undefined,
    can_blit: bool = false,
    can_draw: bool = false,
    present_pref: PresentMode = .fifo,
    present_mode: PresentMode = .fifo,
    /// Set when present/acquire reported the swapchain out of date or
    /// suboptimal; the owner should call `recreate`.
    needs_recreate: bool = false,
    frames_presented: u64 = 0,

    vkCreateXlibSurfaceKHR: ?CreateXlibSurfaceFn = null,
    vkCreateWaylandSurfaceKHR: ?CreateWaylandSurfaceFn = null,
    vkCreateWin32SurfaceKHR: ?CreateWin32SurfaceFn = null,
    vkCreateMetalSurfaceEXT: ?CreateMetalSurfaceFn = null,
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
    vkCreateSemaphore: ?CreateSemaphoreFn = null,
    vkDestroySemaphore: ?DestroySemaphoreFn = null,

    pub fn deinit(self: *GpuPresent, h: Handles) void {
        self.waitIdle(h);
        self.destroySwapchain(h);
        if (self.surface != null) {
            if (self.vkDestroySurfaceKHR) |destroy| destroy(h.instance, self.surface, null);
            self.surface = null;
        }
        self.enabled = false;
    }

    pub fn attachX11(self: *GpuPresent, h: Handles, display: ?*anyopaque, window: usize, width: u32, height: u32) !void {
        if (builtin.os.tag == .linux) {
            if (display == null or window == 0) return error.NoNativeWindow;
            try self.beginAttach(h);
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
            try self.finishAttach(h, width, height);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    pub fn attachWayland(self: *GpuPresent, h: Handles, display: ?*anyopaque, surface: ?*anyopaque, width: u32, height: u32) !void {
        if (builtin.os.tag == .linux) {
            if (display == null or surface == null) return error.NoNativeWindow;
            try self.beginAttach(h);
            errdefer self.deinit(h);

            var info = std.mem.zeroes(vk.raw.VkWaylandSurfaceCreateInfoKHR);
            info.sType = vk.raw.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR;
            info.display = @ptrCast(display);
            info.surface = @ptrCast(surface);

            const create_surface = self.vkCreateWaylandSurfaceKHR orelse return error.MissingCreateSurface;
            var vk_surface: vk.VkSurfaceKHR = null;
            if (create_surface(h.instance, &info, null, &vk_surface) != vk.VK_SUCCESS or vk_surface == null) {
                return error.CreateSurfaceFailed;
            }
            self.surface = vk_surface;
            try self.finishAttach(h, width, height);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    pub fn attachWin32(self: *GpuPresent, h: Handles, hinstance: ?*anyopaque, hwnd: ?*anyopaque, width: u32, height: u32) !void {
        if (builtin.os.tag == .windows) {
            if (hinstance == null or hwnd == null) return error.NoNativeWindow;
            try self.beginAttach(h);
            errdefer self.deinit(h);

            const info = Win32SurfaceInfo{ .hinstance = hinstance, .hwnd = hwnd };

            const create_surface = self.vkCreateWin32SurfaceKHR orelse return error.MissingCreateSurface;
            var vk_surface: vk.VkSurfaceKHR = null;
            if (create_surface(h.instance, &info, null, &vk_surface) != vk.VK_SUCCESS or vk_surface == null) {
                return error.CreateSurfaceFailed;
            }
            self.surface = vk_surface;
            try self.finishAttach(h, width, height);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    /// macOS: a CAMetalLayer through MoltenVK's VK_EXT_metal_surface.
    pub fn attachMetal(self: *GpuPresent, h: Handles, layer: ?*anyopaque, width: u32, height: u32) !void {
        if (layer == null) return error.NoNativeWindow;
        try self.beginAttach(h);
        errdefer self.deinit(h);
        const create_surface = self.vkCreateMetalSurfaceEXT orelse return error.MissingCreateSurface;
        const info = MetalSurfaceInfo{ .pLayer = layer };
        var vk_surface: vk.VkSurfaceKHR = null;
        if (create_surface(h.instance, &info, null, &vk_surface) != vk.VK_SUCCESS or vk_surface == null) {
            return error.CreateSurfaceFailed;
        }
        self.surface = vk_surface;
        try self.finishAttach(h, width, height);
    }

    fn beginAttach(self: *GpuPresent, h: Handles) !void {
        if (h.device == null or h.instance == null) return error.NoDevice;
        self.allocator = h.allocator;
        try self.loadProcs(h);
    }

    fn finishAttach(self: *GpuPresent, h: Handles, width: u32, height: u32) !void {
        var supported: vk.raw.VkBool32 = vk.VK_FALSE;
        const support = self.vkGetPhysicalDeviceSurfaceSupportKHR orelse return error.MissingSurfaceSupport;
        if (support(h.physical_device, h.queue_family, self.surface, &supported) != vk.VK_SUCCESS or supported == vk.VK_FALSE) {
            return error.QueueCannotPresent;
        }

        try self.createSwapchain(h, width, height);
        try self.createCommands(h);
        self.enabled = true;
        std.debug.print("    → Vulkan swapchain present enabled ({d}x{d}, {d} images, {s}, {d} frames in flight) draw={} blit={}\n", .{
            self.extent.width,
            self.extent.height,
            self.images.len,
            @tagName(self.present_mode),
            MAX_FRAMES_IN_FLIGHT,
            self.can_draw,
            self.can_blit,
        });
    }

    pub fn recreate(self: *GpuPresent, h: Handles, width: u32, height: u32) !void {
        if (!self.enabled) return error.NotEnabled;
        self.waitIdle(h);
        self.destroySwapchain(h);
        try self.createSwapchain(h, width, height);
        try self.createCommands(h);
        self.needs_recreate = false;
    }

    /// Wait until no frame is in flight (before destroying or rewriting
    /// resources the GPU may still read). Never called per frame.
    pub fn waitIdle(self: *GpuPresent, h: Handles) void {
        if (h.device == null) return;
        const wait = self.vkWaitForFences orelse return;
        var fences: [MAX_FRAMES_IN_FLIGHT]vk.VkFence = undefined;
        var n: u32 = 0;
        for (self.in_flight) |f| if (f != null) {
            fences[n] = f;
            n += 1;
        };
        if (n > 0) _ = wait(h.device, n, &fences, vk.VK_TRUE, std.math.maxInt(u64));
    }

    /// Wait for this slot's previous frame, acquire an image and begin the
    /// slot's command buffer. error.OutOfDate means: recreate and retry.
    pub fn beginFrame(self: *GpuPresent, h: Handles) !FrameCtx {
        if (!self.enabled) return error.NotEnabled;
        const acquire = self.vkAcquireNextImageKHR orelse return error.MissingAcquire;
        const wait_fences = self.vkWaitForFences orelse return error.MissingWaitFence;
        const reset_fences = self.vkResetFences orelse return error.MissingResetFence;
        const slot = self.slot;
        const fence = self.in_flight[slot];
        // Blocks only when the GPU is MAX_FRAMES_IN_FLIGHT frames behind.
        _ = wait_fences(h.device, 1, @ptrCast(&fence), vk.VK_TRUE, std.math.maxInt(u64));

        var index: u32 = 0;
        const acq = acquire(h.device, self.swapchain, std.math.maxInt(u64), self.image_available[slot], null, &index);
        if (acq == vk.raw.VK_ERROR_OUT_OF_DATE_KHR) {
            self.needs_recreate = true;
            return error.OutOfDate;
        }
        if (acq == vk.raw.VK_SUBOPTIMAL_KHR) self.needs_recreate = true;
        if (acq != vk.VK_SUCCESS and acq != vk.raw.VK_SUBOPTIMAL_KHR) return error.AcquireFailed;
        if (index >= self.images.len) return error.BadImageIndex;
        // An image acquired out of order may still be in use by another slot.
        if (self.images_in_flight[index]) |other| {
            if (other != fence) _ = wait_fences(h.device, 1, @ptrCast(&other), vk.VK_TRUE, std.math.maxInt(u64));
        }
        self.images_in_flight[index] = fence;
        _ = reset_fences(h.device, 1, @ptrCast(&fence));

        const cmd = self.command_buffers[slot] orelse return error.NoCommandBuffer;
        if (self.vkResetCommandBuffer) |reset| _ = reset(cmd, 0);
        var begin_info = std.mem.zeroes(vk.raw.VkCommandBufferBeginInfo);
        begin_info.sType = vk.raw.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = vk.raw.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        const begin = self.vkBeginCommandBuffer orelse return error.MissingBegin;
        if (begin(cmd, &begin_info) != vk.VK_SUCCESS) return error.BeginFailed;
        return .{ .image = index, .slot = slot, .cmd = cmd };
    }

    /// End, submit (signalling the slot fence) and queue the present. Does
    /// not wait for the GPU.
    pub fn endFrame(self: *GpuPresent, h: Handles, f: FrameCtx, wait_stage: u32) !void {
        const end = self.vkEndCommandBuffer orelse return error.MissingEnd;
        if (end(f.cmd) != vk.VK_SUCCESS) return error.EndFailed;

        var stage: vk.raw.VkPipelineStageFlags = wait_stage;
        var submit = std.mem.zeroes(vk.raw.VkSubmitInfo);
        submit.sType = vk.raw.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = @ptrCast(&self.image_available[f.slot]);
        submit.pWaitDstStageMask = @ptrCast(&stage);
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = @ptrCast(&f.cmd);
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores = @ptrCast(&self.render_finished[f.image]);
        const qsubmit = self.vkQueueSubmit orelse return error.MissingSubmit;
        if (qsubmit(h.queue, 1, @ptrCast(&submit), self.in_flight[f.slot]) != vk.VK_SUCCESS) return error.SubmitFailed;
        self.slot = (self.slot + 1) % MAX_FRAMES_IN_FLIGHT;

        var present_info = std.mem.zeroes(vk.raw.VkPresentInfoKHR);
        present_info.sType = vk.raw.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present_info.waitSemaphoreCount = 1;
        present_info.pWaitSemaphores = @ptrCast(&self.render_finished[f.image]);
        present_info.swapchainCount = 1;
        present_info.pSwapchains = @ptrCast(&self.swapchain);
        present_info.pImageIndices = &f.image;
        const qpresent = self.vkQueuePresentKHR orelse return error.MissingPresent;
        const pres = qpresent(h.queue, &present_info);
        self.frames_presented += 1;
        if (pres == vk.raw.VK_ERROR_OUT_OF_DATE_KHR or pres == vk.raw.VK_SUBOPTIMAL_KHR) {
            self.needs_recreate = true;
            return;
        }
        if (pres != vk.VK_SUCCESS) return error.PresentFailed;
    }

    pub fn present(self: *GpuPresent, h: Handles, pixels: []const u32, width: u32, height: u32) bool {
        if (!self.enabled or !self.can_blit) return false;
        self.presentFrame(h, pixels, width, height) catch return false;
        return true;
    }

    fn loadProcs(self: *GpuPresent, h: Handles) !void {
        const l = h.loader;
        const inst = h.instance;
        const dev = h.device;
        const gdp = l.load(inst, loader_mod.GetDeviceProcAddrFn, "vkGetDeviceProcAddr");

        if (builtin.os.tag == .linux) {
            self.vkCreateXlibSurfaceKHR = l.load(inst, CreateXlibSurfaceFn, "vkCreateXlibSurfaceKHR");
            self.vkCreateWaylandSurfaceKHR = l.load(inst, CreateWaylandSurfaceFn, "vkCreateWaylandSurfaceKHR");
        }
        if (builtin.os.tag == .windows) {
            self.vkCreateWin32SurfaceKHR = l.load(inst, CreateWin32SurfaceFn, "vkCreateWin32SurfaceKHR");
        }
        if (builtin.os.tag == .macos) {
            self.vkCreateMetalSurfaceEXT = l.load(inst, CreateMetalSurfaceFn, "vkCreateMetalSurfaceEXT");
        }
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
            self.vkCreateSemaphore = loader_mod.Loader.loadDevice(get_dev, dev, CreateSemaphoreFn, "vkCreateSemaphore");
            self.vkDestroySemaphore = loader_mod.Loader.loadDevice(get_dev, dev, DestroySemaphoreFn, "vkDestroySemaphore");
        }

        const has_surface = self.vkCreateXlibSurfaceKHR != null or
            self.vkCreateWaylandSurfaceKHR != null or
            self.vkCreateWin32SurfaceKHR != null or
            self.vkCreateMetalSurfaceEXT != null;
        if (!has_surface or self.vkCreateSwapchainKHR == null or self.vkQueuePresentKHR == null) {
            std.debug.print("    → present procs xlib={} wayland={} win32={} swap={} present={}\n", .{
                self.vkCreateXlibSurfaceKHR != null,
                self.vkCreateWaylandSurfaceKHR != null,
                self.vkCreateWin32SurfaceKHR != null,
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
        var usage: u32 = 0;
        if (caps.supportedUsageFlags & vk.raw.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT != 0) {
            usage |= vk.raw.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        }
        if (caps.supportedUsageFlags & vk.raw.VK_IMAGE_USAGE_TRANSFER_DST_BIT != 0) {
            usage |= vk.raw.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        }
        if (usage == 0) return error.NoSwapchainUsage;
        self.can_draw = (usage & vk.raw.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) != 0;
        self.can_blit = (usage & vk.raw.VK_IMAGE_USAGE_TRANSFER_DST_BIT) != 0;

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

        self.present_mode = self.choosePresentMode(h);
        var image_count = caps.minImageCount + 1;
        // Mailbox needs a spare image to replace.
        if (self.present_mode == .mailbox) image_count = @max(image_count, 3);
        if (caps.maxImageCount > 0 and image_count > caps.maxImageCount) image_count = caps.maxImageCount;

        var sci = std.mem.zeroes(vk.VkSwapchainCreateInfoKHR);
        sci.sType = vk.raw.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        sci.surface = self.surface;
        sci.minImageCount = image_count;
        sci.imageFormat = chosen.format;
        sci.imageColorSpace = chosen.colorSpace;
        sci.imageExtent = extent;
        sci.imageArrayLayers = 1;
        sci.imageUsage = usage;
        sci.imageSharingMode = vk.raw.VK_SHARING_MODE_EXCLUSIVE;
        sci.preTransform = caps.currentTransform;
        sci.compositeAlpha = vk.raw.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        sci.presentMode = self.present_mode.vk_value();
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

    fn choosePresentMode(self: *GpuPresent, h: Handles) PresentMode {
        const want = self.present_pref;
        if (want == .fifo) return .fifo;
        const modes_fn = self.vkGetPhysicalDeviceSurfacePresentModesKHR orelse return .fifo;
        var count: u32 = 0;
        if (modes_fn(h.physical_device, self.surface, &count, null) != vk.VK_SUCCESS or count == 0) return .fifo;
        var buf: [16]vk.VkPresentModeKHR = undefined;
        count = @min(count, buf.len);
        if (modes_fn(h.physical_device, self.surface, &count, &buf) != vk.VK_SUCCESS and count == 0) return .fifo;
        const has = struct {
            fn f(list: []const vk.VkPresentModeKHR, m: PresentMode) bool {
                for (list) |x| if (x == m.vk_value()) return true;
                return false;
            }
        }.f;
        const list = buf[0..count];
        if (has(list, want)) return want;
        // vsync off: mailbox is the tear-free fallback, then immediate.
        if (want == .immediate and has(list, .mailbox)) return .mailbox;
        if (want == .mailbox and has(list, .immediate)) return .immediate;
        return .fifo;
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
        alloc_info.commandBufferCount = MAX_FRAMES_IN_FLIGHT;
        const alloc = self.vkAllocateCommandBuffers orelse return error.MissingAllocCmd;
        if (alloc(h.device, &alloc_info, @ptrCast(&self.command_buffers)) != vk.VK_SUCCESS) return error.AllocCommandBufferFailed;

        const create_fence = self.vkCreateFence orelse return error.MissingFence;
        const create_sem = self.vkCreateSemaphore orelse return error.MissingSemaphore;
        var fence_info = std.mem.zeroes(vk.raw.VkFenceCreateInfo);
        fence_info.sType = vk.raw.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = vk.raw.VK_FENCE_CREATE_SIGNALED_BIT; // first wait returns at once
        var sem_info = std.mem.zeroes(vk.raw.VkSemaphoreCreateInfo);
        sem_info.sType = vk.raw.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (create_fence(h.device, &fence_info, null, &self.in_flight[i]) != vk.VK_SUCCESS) return error.CreateFenceFailed;
            if (create_sem(h.device, &sem_info, null, &self.image_available[i]) != vk.VK_SUCCESS) return error.CreateSemaphoreFailed;
        }
        self.render_finished = try h.allocator.alloc(vk.VkSemaphore, self.images.len);
        @memset(self.render_finished, null);
        for (self.render_finished) |*sem| {
            if (create_sem(h.device, &sem_info, null, sem) != vk.VK_SUCCESS) return error.CreateSemaphoreFailed;
        }
        self.images_in_flight = try h.allocator.alloc(vk.VkFence, self.images.len);
        @memset(self.images_in_flight, null);
        self.slot = 0;

        if (self.can_blit) {
            const bytes = @as(usize, self.extent.width) * @as(usize, self.extent.height) * 4;
            for (0..MAX_FRAMES_IN_FLIGHT) |i| try self.createStaging(h, bytes, i);
        }
    }

    fn createStaging(self: *GpuPresent, h: Handles, bytes: usize, slot: usize) !void {
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

        self.staging[slot] = buffer;
        self.staging_mem[slot] = memory;
        self.staging_size = bytes;
    }

    fn destroySwapchain(self: *GpuPresent, h: Handles) void {
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.in_flight[i] != null) {
                if (self.vkDestroyFence) |d| d(h.device, self.in_flight[i], null);
                self.in_flight[i] = null;
            }
            if (self.image_available[i] != null) {
                if (self.vkDestroySemaphore) |d| d(h.device, self.image_available[i], null);
                self.image_available[i] = null;
            }
            if (self.staging[i] != null) {
                if (self.vkDestroyBuffer) |d| d(h.device, self.staging[i], null);
                self.staging[i] = null;
            }
            if (self.staging_mem[i] != null) {
                if (self.vkFreeMemory) |d| d(h.device, self.staging_mem[i], null);
                self.staging_mem[i] = null;
            }
        }
        for (self.render_finished) |sem| {
            if (sem != null) if (self.vkDestroySemaphore) |d| d(h.device, sem, null);
        }
        if (self.render_finished.len != 0) self.allocator.free(self.render_finished);
        self.render_finished = &.{};
        if (self.images_in_flight.len != 0) self.allocator.free(self.images_in_flight);
        self.images_in_flight = &.{};
        if (self.command_pool != null) {
            if (self.vkDestroyCommandPool) |d| d(h.device, self.command_pool, null);
            self.command_pool = null;
            self.command_buffers = .{null} ** MAX_FRAMES_IN_FLIGHT;
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

        // beginFrame waited for this slot's fence, so its staging is free.
        const f = try self.beginFrame(h);
        try self.uploadStaging(h, f.slot, pixels, width, height, copy_w, copy_h);
        const cmd = f.cmd;
        const image = self.images[f.image];
        const barrier_fn = self.vkCmdPipelineBarrier orelse return error.MissingBarrier;
        var to_dst = imageBarrier(image, vk.raw.VK_IMAGE_LAYOUT_UNDEFINED, vk.raw.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, vk.raw.VK_ACCESS_TRANSFER_WRITE_BIT);
        barrier_fn(cmd, vk.raw.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.raw.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, @ptrCast(&to_dst));

        var region = std.mem.zeroes(vk.raw.VkBufferImageCopy);
        region.imageSubresource.aspectMask = vk.raw.VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = .{ .width = copy_w, .height = copy_h, .depth = 1 };
        const copy_fn = self.vkCmdCopyBufferToImage orelse return error.MissingCopy;
        copy_fn(cmd, self.staging[f.slot], image, vk.raw.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @ptrCast(&region));

        var to_present = imageBarrier(image, vk.raw.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.raw.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, vk.raw.VK_ACCESS_TRANSFER_WRITE_BIT, 0);
        barrier_fn(cmd, vk.raw.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.raw.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 1, @ptrCast(&to_present));
        try self.endFrame(h, f, vk.raw.VK_PIPELINE_STAGE_TRANSFER_BIT);
    }

    fn uploadStaging(self: *GpuPresent, h: Handles, slot: u32, pixels: []const u32, src_w: u32, src_h: u32, copy_w: u32, copy_h: u32) !void {
        _ = src_h;
        const map = self.vkMapMemory orelse return error.MissingMap;
        var mapped: ?*anyopaque = null;
        if (map(h.device, self.staging_mem[slot], 0, self.staging_size, 0, &mapped) != vk.VK_SUCCESS) return error.MapFailed;
        defer if (self.vkUnmapMemory) |unmap| unmap(h.device, self.staging_mem[slot]);

        const dest = @as([*]u32, @ptrCast(@alignCast(mapped.?)));
        const dst_w = self.extent.width;
        var y: u32 = 0;
        while (y < copy_h) : (y += 1) {
            const src_row = pixels[y * src_w ..][0..copy_w];
            const dst_row = dest[y * dst_w ..][0..copy_w];
            if (self.format == vk.VK_FORMAT_R8G8B8A8_SRGB or self.format == vk.raw.VK_FORMAT_R8G8B8A8_UNORM) {
                for (dst_row, src_row) |*d, px| d.* = swizzle(self.format, px);
            } else @memcpy(dst_row, src_row);
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

test "present mode names" {
    try std.testing.expectEqual(PresentMode.mailbox, PresentMode.parse("mailbox").?);
    try std.testing.expectEqual(PresentMode.fifo, PresentMode.parse("vsync").?);
    try std.testing.expect(PresentMode.parse("bogus") == null);
}

test "GpuPresent starts disabled" {
    const p = GpuPresent{};
    try std.testing.expect(!p.enabled);
}
