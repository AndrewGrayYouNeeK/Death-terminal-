const std = @import("std");
const vk = @import("vulkan_c.zig");

/// Swapchain manages the presentation surface and image buffers
pub const Swapchain = struct {
    allocator: std.mem.Allocator,
    swapchain: ?vk.VkSwapchainKHR,
    images: std.ArrayList(vk.VkImage),
    image_views: std.ArrayList(vk.VkImageView),
    framebuffers: std.ArrayList(vk.VkFramebuffer),
    format: vk.VkFormat,
    extent: vk.VkExtent2D,

    pub fn init(
        allocator: std.mem.Allocator,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        surface: vk.VkSurfaceKHR,
        width: u32,
        height: u32,
    ) !Swapchain {
        _ = device;
        _ = physical_device;
        _ = surface;

        var swap = Swapchain{
            .allocator = allocator,
            .swapchain = null,
            .images = std.ArrayList(vk.VkImage).init(allocator),
            .image_views = std.ArrayList(vk.VkImageView).init(allocator),
            .framebuffers = std.ArrayList(vk.VkFramebuffer).init(allocator),
            .format = vk.VK_FORMAT_B8G8R8A8_SRGB,
            .extent = .{ .width = width, .height = height },
        };

        // TODO: Implement swapchain creation:
        // 1. Query surface capabilities
        // 2. Choose surface format (prefer SRGB)
        // 3. Choose present mode (prefer MAILBOX, fallback to FIFO)
        // 4. Create swapchain
        // 5. Get swapchain images
        // 6. Create image views

        std.debug.print("    → Swapchain creation (stubbed, {}x{})\n", .{ width, height });

        return swap;
    }

    pub fn deinit(self: *Swapchain, device: vk.VkDevice) void {
        _ = device;

        // TODO: Destroy framebuffers, image views, and swapchain

        self.framebuffers.deinit();
        self.image_views.deinit();
        self.images.deinit();
    }

    pub fn recreate(
        self: *Swapchain,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        surface: vk.VkSurfaceKHR,
        width: u32,
        height: u32,
    ) !void {
        // Wait for device to be idle
        // vkDeviceWaitIdle(device);

        // Clean up old swapchain
        self.deinit(device);

        // Recreate with new dimensions
        const new_swap = try Swapchain.init(
            self.allocator,
            device,
            physical_device,
            surface,
            width,
            height,
        );

        self.* = new_swap;
    }

    pub fn acquireNextImage(self: *Swapchain, device: vk.VkDevice, semaphore: vk.VkSemaphore) !u32 {
        _ = self;
        _ = device;
        _ = semaphore;

        // TODO: Call vkAcquireNextImageKHR
        // Returns image index
        return 0;
    }

    pub fn present(self: *Swapchain, queue: vk.VkQueue, image_index: u32, wait_semaphore: vk.VkSemaphore) !void {
        _ = self;
        _ = queue;
        _ = image_index;
        _ = wait_semaphore;

        // TODO: Call vkQueuePresentKHR
    }
};
