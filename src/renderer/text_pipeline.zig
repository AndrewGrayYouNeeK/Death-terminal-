const std = @import("std");
const vk = @import("vulkan_c.zig");
const loader_mod = @import("loader.zig");
const gpu_present = @import("gpu_present.zig");
const software = @import("software.zig");
const text = @import("text_renderer.zig");
const pipeline_mod = @import("pipeline.zig");
const Cell = @import("../terminal/terminal.zig").Cell;

const Handles = gpu_present.Handles;

const CreateImageFn = *const fn (vk.VkDevice, *const vk.raw.VkImageCreateInfo, ?*const anyopaque, *vk.VkImage) callconv(.C) vk.VkResult;
const DestroyImageFn = *const fn (vk.VkDevice, vk.VkImage, ?*const anyopaque) callconv(.C) void;
const GetImageMemoryRequirementsFn = *const fn (vk.VkDevice, vk.VkImage, *vk.raw.VkMemoryRequirements) callconv(.C) void;
const BindImageMemoryFn = *const fn (vk.VkDevice, vk.VkImage, vk.VkDeviceMemory, vk.raw.VkDeviceSize) callconv(.C) vk.VkResult;
const CreateImageViewFn = *const fn (vk.VkDevice, *const vk.raw.VkImageViewCreateInfo, ?*const anyopaque, *vk.VkImageView) callconv(.C) vk.VkResult;
const DestroyImageViewFn = *const fn (vk.VkDevice, vk.VkImageView, ?*const anyopaque) callconv(.C) void;
const CreateSamplerFn = *const fn (vk.VkDevice, *const vk.raw.VkSamplerCreateInfo, ?*const anyopaque, *vk.VkSampler) callconv(.C) vk.VkResult;
const DestroySamplerFn = *const fn (vk.VkDevice, vk.VkSampler, ?*const anyopaque) callconv(.C) void;
const CreateBufferFn = *const fn (vk.VkDevice, *const vk.raw.VkBufferCreateInfo, ?*const anyopaque, *vk.VkBuffer) callconv(.C) vk.VkResult;
const DestroyBufferFn = *const fn (vk.VkDevice, vk.VkBuffer, ?*const anyopaque) callconv(.C) void;
const GetBufferMemoryRequirementsFn = *const fn (vk.VkDevice, vk.VkBuffer, *vk.raw.VkMemoryRequirements) callconv(.C) void;
const BindBufferMemoryFn = *const fn (vk.VkDevice, vk.VkBuffer, vk.VkDeviceMemory, vk.raw.VkDeviceSize) callconv(.C) vk.VkResult;
const AllocateMemoryFn = *const fn (vk.VkDevice, *const vk.raw.VkMemoryAllocateInfo, ?*const anyopaque, *vk.VkDeviceMemory) callconv(.C) vk.VkResult;
const FreeMemoryFn = *const fn (vk.VkDevice, vk.VkDeviceMemory, ?*const anyopaque) callconv(.C) void;
const MapMemoryFn = *const fn (vk.VkDevice, vk.VkDeviceMemory, vk.raw.VkDeviceSize, vk.raw.VkDeviceSize, vk.raw.VkMemoryMapFlags, *?*anyopaque) callconv(.C) vk.VkResult;
const UnmapMemoryFn = *const fn (vk.VkDevice, vk.VkDeviceMemory) callconv(.C) void;
const GetPhysicalDeviceMemoryPropertiesFn = *const fn (vk.VkPhysicalDevice, *vk.raw.VkPhysicalDeviceMemoryProperties) callconv(.C) void;
const CreateDescriptorSetLayoutFn = *const fn (vk.VkDevice, *const vk.raw.VkDescriptorSetLayoutCreateInfo, ?*const anyopaque, *vk.VkDescriptorSetLayout) callconv(.C) vk.VkResult;
const DestroyDescriptorSetLayoutFn = *const fn (vk.VkDevice, vk.VkDescriptorSetLayout, ?*const anyopaque) callconv(.C) void;
const CreateDescriptorPoolFn = *const fn (vk.VkDevice, *const vk.raw.VkDescriptorPoolCreateInfo, ?*const anyopaque, *vk.VkDescriptorPool) callconv(.C) vk.VkResult;
const DestroyDescriptorPoolFn = *const fn (vk.VkDevice, vk.VkDescriptorPool, ?*const anyopaque) callconv(.C) void;
const AllocateDescriptorSetsFn = *const fn (vk.VkDevice, *const vk.raw.VkDescriptorSetAllocateInfo, *vk.VkDescriptorSet) callconv(.C) vk.VkResult;
const UpdateDescriptorSetsFn = *const fn (vk.VkDevice, u32, [*]const vk.raw.VkWriteDescriptorSet, u32, ?[*]const vk.raw.VkCopyDescriptorSet) callconv(.C) void;
const CreatePipelineLayoutFn = *const fn (vk.VkDevice, *const vk.raw.VkPipelineLayoutCreateInfo, ?*const anyopaque, *vk.VkPipelineLayout) callconv(.C) vk.VkResult;
const DestroyPipelineLayoutFn = *const fn (vk.VkDevice, vk.VkPipelineLayout, ?*const anyopaque) callconv(.C) void;
const CreateGraphicsPipelinesFn = *const fn (vk.VkDevice, vk.raw.VkPipelineCache, u32, [*]const vk.raw.VkGraphicsPipelineCreateInfo, ?*const anyopaque, *vk.VkPipeline) callconv(.C) vk.VkResult;
const DestroyPipelineFn = *const fn (vk.VkDevice, vk.VkPipeline, ?*const anyopaque) callconv(.C) void;
const CreateRenderPassFn = *const fn (vk.VkDevice, *const vk.raw.VkRenderPassCreateInfo, ?*const anyopaque, *vk.VkRenderPass) callconv(.C) vk.VkResult;
const DestroyRenderPassFn = *const fn (vk.VkDevice, vk.VkRenderPass, ?*const anyopaque) callconv(.C) void;
const CreateFramebufferFn = *const fn (vk.VkDevice, *const vk.raw.VkFramebufferCreateInfo, ?*const anyopaque, *vk.VkFramebuffer) callconv(.C) vk.VkResult;
const DestroyFramebufferFn = *const fn (vk.VkDevice, vk.VkFramebuffer, ?*const anyopaque) callconv(.C) void;
const BeginCommandBufferFn = *const fn (vk.VkCommandBuffer, *const vk.raw.VkCommandBufferBeginInfo) callconv(.C) vk.VkResult;
const EndCommandBufferFn = *const fn (vk.VkCommandBuffer) callconv(.C) vk.VkResult;
const ResetCommandBufferFn = *const fn (vk.VkCommandBuffer, vk.raw.VkCommandBufferResetFlags) callconv(.C) vk.VkResult;
const QueueSubmitFn = *const fn (vk.VkQueue, u32, [*]const vk.raw.VkSubmitInfo, vk.VkFence) callconv(.C) vk.VkResult;
const QueueWaitIdleFn = *const fn (vk.VkQueue) callconv(.C) vk.VkResult;
const CmdPipelineBarrierFn = *const fn (vk.VkCommandBuffer, vk.raw.VkPipelineStageFlags, vk.raw.VkPipelineStageFlags, vk.raw.VkDependencyFlags, u32, ?[*]const vk.raw.VkMemoryBarrier, u32, ?[*]const vk.raw.VkBufferMemoryBarrier, u32, ?[*]const vk.raw.VkImageMemoryBarrier) callconv(.C) void;
const CmdCopyBufferToImageFn = *const fn (vk.VkCommandBuffer, vk.VkBuffer, vk.VkImage, vk.raw.VkImageLayout, u32, [*]const vk.raw.VkBufferImageCopy) callconv(.C) void;
const CmdBeginRenderPassFn = *const fn (vk.VkCommandBuffer, *const vk.raw.VkRenderPassBeginInfo, vk.raw.VkSubpassContents) callconv(.C) void;
const CmdEndRenderPassFn = *const fn (vk.VkCommandBuffer) callconv(.C) void;
const CmdBindPipelineFn = *const fn (vk.VkCommandBuffer, vk.raw.VkPipelineBindPoint, vk.VkPipeline) callconv(.C) void;
const CmdBindVertexBuffersFn = *const fn (vk.VkCommandBuffer, u32, u32, [*]const vk.VkBuffer, [*]const vk.raw.VkDeviceSize) callconv(.C) void;
const CmdBindIndexBufferFn = *const fn (vk.VkCommandBuffer, vk.VkBuffer, vk.raw.VkDeviceSize, vk.raw.VkIndexType) callconv(.C) void;
const CmdBindDescriptorSetsFn = *const fn (vk.VkCommandBuffer, vk.raw.VkPipelineBindPoint, vk.VkPipelineLayout, u32, u32, [*]const vk.VkDescriptorSet, u32, ?[*]const u32) callconv(.C) void;
const CmdDrawIndexedFn = *const fn (vk.VkCommandBuffer, u32, u32, u32, i32, u32) callconv(.C) void;
const CmdSetViewportFn = *const fn (vk.VkCommandBuffer, u32, u32, [*]const vk.raw.VkViewport) callconv(.C) void;
const CmdSetScissorFn = *const fn (vk.VkCommandBuffer, u32, u32, [*]const vk.raw.VkRect2D) callconv(.C) void;

/// GPU glyph atlas + graphics pipeline that draws terminal cells into a swapchain image.
pub const TextPipeline = struct {
    enabled: bool = false,
    allocator: std.mem.Allocator = undefined,
    format: vk.VkFormat = vk.VK_FORMAT_B8G8R8A8_SRGB,
    extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },

    atlas_image: vk.VkImage = null,
    atlas_mem: vk.VkDeviceMemory = null,
    atlas_view: vk.VkImageView = null,
    sampler: vk.VkSampler = null,
    dsl: vk.VkDescriptorSetLayout = null,
    desc_pool: vk.VkDescriptorPool = null,
    desc_set: vk.VkDescriptorSet = null,
    pipeline_layout: vk.VkPipelineLayout = null,
    render_pass: vk.VkRenderPass = null,
    pipeline: vk.VkPipeline = null,
    quad_buf: vk.VkBuffer = null,
    quad_mem: vk.VkDeviceMemory = null,
    index_buf: vk.VkBuffer = null,
    index_mem: vk.VkDeviceMemory = null,
    inst_buf: vk.VkBuffer = null,
    inst_mem: vk.VkDeviceMemory = null,
    views: []vk.VkImageView = &.{},
    framebuffers: []vk.VkFramebuffer = &.{},
    scratch: []text.Instance = &.{},

    vkCreateImage: ?CreateImageFn = null,
    vkDestroyImage: ?DestroyImageFn = null,
    vkGetImageMemoryRequirements: ?GetImageMemoryRequirementsFn = null,
    vkBindImageMemory: ?BindImageMemoryFn = null,
    vkCreateImageView: ?CreateImageViewFn = null,
    vkDestroyImageView: ?DestroyImageViewFn = null,
    vkCreateSampler: ?CreateSamplerFn = null,
    vkDestroySampler: ?DestroySamplerFn = null,
    vkCreateBuffer: ?CreateBufferFn = null,
    vkDestroyBuffer: ?DestroyBufferFn = null,
    vkGetBufferMemoryRequirements: ?GetBufferMemoryRequirementsFn = null,
    vkBindBufferMemory: ?BindBufferMemoryFn = null,
    vkAllocateMemory: ?AllocateMemoryFn = null,
    vkFreeMemory: ?FreeMemoryFn = null,
    vkMapMemory: ?MapMemoryFn = null,
    vkUnmapMemory: ?UnmapMemoryFn = null,
    vkGetPhysicalDeviceMemoryProperties: ?GetPhysicalDeviceMemoryPropertiesFn = null,
    vkCreateDescriptorSetLayout: ?CreateDescriptorSetLayoutFn = null,
    vkDestroyDescriptorSetLayout: ?DestroyDescriptorSetLayoutFn = null,
    vkCreateDescriptorPool: ?CreateDescriptorPoolFn = null,
    vkDestroyDescriptorPool: ?DestroyDescriptorPoolFn = null,
    vkAllocateDescriptorSets: ?AllocateDescriptorSetsFn = null,
    vkUpdateDescriptorSets: ?UpdateDescriptorSetsFn = null,
    vkCreatePipelineLayout: ?CreatePipelineLayoutFn = null,
    vkDestroyPipelineLayout: ?DestroyPipelineLayoutFn = null,
    vkCreateGraphicsPipelines: ?CreateGraphicsPipelinesFn = null,
    vkDestroyPipeline: ?DestroyPipelineFn = null,
    vkCreateRenderPass: ?CreateRenderPassFn = null,
    vkDestroyRenderPass: ?DestroyRenderPassFn = null,
    vkCreateFramebuffer: ?CreateFramebufferFn = null,
    vkDestroyFramebuffer: ?DestroyFramebufferFn = null,
    vkCreateShaderModule: ?pipeline_mod.CreateShaderModuleFn = null,
    vkDestroyShaderModule: ?pipeline_mod.DestroyShaderModuleFn = null,
    vkBeginCommandBuffer: ?BeginCommandBufferFn = null,
    vkEndCommandBuffer: ?EndCommandBufferFn = null,
    vkResetCommandBuffer: ?ResetCommandBufferFn = null,
    vkQueueSubmit: ?QueueSubmitFn = null,
    vkQueueWaitIdle: ?QueueWaitIdleFn = null,
    vkCmdPipelineBarrier: ?CmdPipelineBarrierFn = null,
    vkCmdCopyBufferToImage: ?CmdCopyBufferToImageFn = null,
    vkCmdBeginRenderPass: ?CmdBeginRenderPassFn = null,
    vkCmdEndRenderPass: ?CmdEndRenderPassFn = null,
    vkCmdBindPipeline: ?CmdBindPipelineFn = null,
    vkCmdBindVertexBuffers: ?CmdBindVertexBuffersFn = null,
    vkCmdBindIndexBuffer: ?CmdBindIndexBufferFn = null,
    vkCmdBindDescriptorSets: ?CmdBindDescriptorSetsFn = null,
    vkCmdDrawIndexed: ?CmdDrawIndexedFn = null,
    vkCmdSetViewport: ?CmdSetViewportFn = null,
    vkCmdSetScissor: ?CmdSetScissorFn = null,

    pub fn deinit(self: *TextPipeline, h: Handles) void {
        if (h.queue != null) {
            if (self.vkQueueWaitIdle) |wait| _ = wait(h.queue);
        }
        self.unbindSwapchain(h);
        self.destroyPipeline(h);
        self.destroyAtlas(h);
        if (self.scratch.len != 0) {
            self.allocator.free(self.scratch);
            self.scratch = &.{};
        }
        self.enabled = false;
    }

    pub fn init(self: *TextPipeline, h: Handles, format: vk.VkFormat, cmd: vk.VkCommandBuffer) !void {
        self.allocator = h.allocator;
        self.format = format;
        self.loadProcs(h) catch return error.MissingTextProcs;
        errdefer self.deinit(h);

        self.scratch = try h.allocator.alloc(text.Instance, text.MAX_INSTANCES);
        try self.createAtlas(h, cmd);
        try self.createDescriptors(h);
        try self.createBuffers(h);
        try self.createRenderPass(h, format);
        try self.createPipeline(h);
        self.enabled = true;
        std.debug.print("    → GPU text pipeline enabled (SPIR-V glyphs)\n", .{});
    }

    pub fn unbindSwapchain(self: *TextPipeline, h: Handles) void {
        if (self.framebuffers.len != 0) {
            if (self.vkDestroyFramebuffer) |d| {
                for (self.framebuffers) |fb| {
                    if (fb != null) d(h.device, fb, null);
                }
            }
            self.allocator.free(self.framebuffers);
            self.framebuffers = &.{};
        }
        if (self.views.len != 0) {
            if (self.vkDestroyImageView) |d| {
                for (self.views) |view| {
                    if (view != null) d(h.device, view, null);
                }
            }
            self.allocator.free(self.views);
            self.views = &.{};
        }
    }

    pub fn bindSwapchain(self: *TextPipeline, h: Handles, images: []const vk.VkImage, format: vk.VkFormat, extent: vk.VkExtent2D) !void {
        if (!self.enabled) return error.NotEnabled;
        self.unbindSwapchain(h);
        if (format != self.format) {
            self.destroyPipeline(h);
            self.format = format;
            try self.createRenderPass(h, format);
            try self.createPipeline(h);
        }
        self.extent = extent;

        const views = try h.allocator.alloc(vk.VkImageView, images.len);
        errdefer {
            if (self.vkDestroyImageView) |d| {
                for (views) |view| {
                    if (view != null) d(h.device, view, null);
                }
            }
            h.allocator.free(views);
        }
        @memset(views, null);

        const create_view = self.vkCreateImageView orelse return error.MissingImageView;
        for (images, 0..) |image, i| {
            var info = std.mem.zeroes(vk.raw.VkImageViewCreateInfo);
            info.sType = vk.raw.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            info.image = image;
            info.viewType = vk.raw.VK_IMAGE_VIEW_TYPE_2D;
            info.format = format;
            info.subresourceRange = .{
                .aspectMask = vk.raw.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            };
            if (create_view(h.device, &info, null, &views[i]) != vk.VK_SUCCESS or views[i] == null) {
                return error.CreateImageViewFailed;
            }
        }

        const fbs = try h.allocator.alloc(vk.VkFramebuffer, images.len);
        errdefer {
            if (self.vkDestroyFramebuffer) |d| {
                for (fbs) |fb| {
                    if (fb != null) d(h.device, fb, null);
                }
            }
            h.allocator.free(fbs);
        }
        @memset(fbs, null);

        const create_fb = self.vkCreateFramebuffer orelse return error.MissingFramebuffer;
        for (views, 0..) |view, i| {
            var info = std.mem.zeroes(vk.raw.VkFramebufferCreateInfo);
            info.sType = vk.raw.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            info.renderPass = self.render_pass;
            info.attachmentCount = 1;
            info.pAttachments = @ptrCast(&view);
            info.width = extent.width;
            info.height = extent.height;
            info.layers = 1;
            if (create_fb(h.device, &info, null, &fbs[i]) != vk.VK_SUCCESS or fbs[i] == null) {
                return error.CreateFramebufferFailed;
            }
        }

        self.views = views;
        self.framebuffers = fbs;
    }

    pub fn packAndUpload(
        self: *TextPipeline,
        h: Handles,
        cells: []const Cell,
        rows: u16,
        cols: u16,
        cursor_row: u16,
        cursor_col: u16,
        cursor_visible: bool,
    ) !u32 {
        if (!self.enabled or self.extent.width == 0) return error.NotBound;
        const count = text.packInstances(
            self.scratch,
            cells,
            rows,
            cols,
            cursor_row,
            cursor_col,
            cursor_visible,
            @floatFromInt(self.extent.width),
            @floatFromInt(self.extent.height),
        );
        if (count == 0) return 0;

        const map = self.vkMapMemory orelse return error.MissingMap;
        var mapped: ?*anyopaque = null;
        const bytes = @as(usize, count) * @sizeOf(text.Instance);
        if (map(h.device, self.inst_mem, 0, bytes, 0, &mapped) != vk.VK_SUCCESS) return error.MapFailed;
        defer if (self.vkUnmapMemory) |unmap| unmap(h.device, self.inst_mem);
        const dest: [*]text.Instance = @ptrCast(@alignCast(mapped.?));
        @memcpy(dest[0..count], self.scratch[0..count]);
        return count;
    }

    pub fn record(self: *TextPipeline, cmd: vk.VkCommandBuffer, image_index: u32, instance_count: u32) !void {
        if (image_index >= self.framebuffers.len) return error.BadImageIndex;
        const begin_rp = self.vkCmdBeginRenderPass orelse return error.MissingBeginRP;
        const end_rp = self.vkCmdEndRenderPass orelse return error.MissingEndRP;

        var clear = std.mem.zeroes(vk.raw.VkClearValue);
        clear.color.float32 = .{ 0, 0, 0, 1 };

        var rp = std.mem.zeroes(vk.raw.VkRenderPassBeginInfo);
        rp.sType = vk.raw.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rp.renderPass = self.render_pass;
        rp.framebuffer = self.framebuffers[image_index];
        rp.renderArea.extent = self.extent;
        rp.clearValueCount = 1;
        rp.pClearValues = @ptrCast(&clear);
        begin_rp(cmd, &rp, vk.raw.VK_SUBPASS_CONTENTS_INLINE);

        var viewport = std.mem.zeroes(vk.raw.VkViewport);
        viewport.width = @floatFromInt(self.extent.width);
        viewport.height = @floatFromInt(self.extent.height);
        viewport.minDepth = 0;
        viewport.maxDepth = 1;
        if (self.vkCmdSetViewport) |set| set(cmd, 0, 1, @ptrCast(&viewport));

        var scissor = std.mem.zeroes(vk.raw.VkRect2D);
        scissor.extent = self.extent;
        if (self.vkCmdSetScissor) |set| set(cmd, 0, 1, @ptrCast(&scissor));

        if (self.vkCmdBindPipeline) |bind| bind(cmd, vk.raw.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        if (self.vkCmdBindDescriptorSets) |bind| {
            bind(cmd, vk.raw.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, @ptrCast(&self.desc_set), 0, null);
        }
        const zero: vk.raw.VkDeviceSize = 0;
        if (self.vkCmdBindVertexBuffers) |bind| {
            const bufs = [_]vk.VkBuffer{ self.quad_buf, self.inst_buf };
            const offs = [_]vk.raw.VkDeviceSize{ zero, zero };
            bind(cmd, 0, 2, &bufs, &offs);
        }
        if (self.vkCmdBindIndexBuffer) |bind| bind(cmd, self.index_buf, 0, vk.raw.VK_INDEX_TYPE_UINT16);
        if (instance_count > 0) {
            if (self.vkCmdDrawIndexed) |draw| draw(cmd, 6, instance_count, 0, 0, 0);
        }
        end_rp(cmd);
    }

    fn loadProcs(self: *TextPipeline, h: Handles) !void {
        const l = h.loader;
        const inst = h.instance;
        const dev = h.device;
        const gdp = l.load(inst, loader_mod.GetDeviceProcAddrFn, "vkGetDeviceProcAddr") orelse return error.MissingGetDeviceProcAddr;
        self.vkGetPhysicalDeviceMemoryProperties = l.load(inst, GetPhysicalDeviceMemoryPropertiesFn, "vkGetPhysicalDeviceMemoryProperties");

        self.vkCreateImage = loader_mod.Loader.loadDevice(gdp, dev, CreateImageFn, "vkCreateImage");
        self.vkDestroyImage = loader_mod.Loader.loadDevice(gdp, dev, DestroyImageFn, "vkDestroyImage");
        self.vkGetImageMemoryRequirements = loader_mod.Loader.loadDevice(gdp, dev, GetImageMemoryRequirementsFn, "vkGetImageMemoryRequirements");
        self.vkBindImageMemory = loader_mod.Loader.loadDevice(gdp, dev, BindImageMemoryFn, "vkBindImageMemory");
        self.vkCreateImageView = loader_mod.Loader.loadDevice(gdp, dev, CreateImageViewFn, "vkCreateImageView");
        self.vkDestroyImageView = loader_mod.Loader.loadDevice(gdp, dev, DestroyImageViewFn, "vkDestroyImageView");
        self.vkCreateSampler = loader_mod.Loader.loadDevice(gdp, dev, CreateSamplerFn, "vkCreateSampler");
        self.vkDestroySampler = loader_mod.Loader.loadDevice(gdp, dev, DestroySamplerFn, "vkDestroySampler");
        self.vkCreateBuffer = loader_mod.Loader.loadDevice(gdp, dev, CreateBufferFn, "vkCreateBuffer");
        self.vkDestroyBuffer = loader_mod.Loader.loadDevice(gdp, dev, DestroyBufferFn, "vkDestroyBuffer");
        self.vkGetBufferMemoryRequirements = loader_mod.Loader.loadDevice(gdp, dev, GetBufferMemoryRequirementsFn, "vkGetBufferMemoryRequirements");
        self.vkBindBufferMemory = loader_mod.Loader.loadDevice(gdp, dev, BindBufferMemoryFn, "vkBindBufferMemory");
        self.vkAllocateMemory = loader_mod.Loader.loadDevice(gdp, dev, AllocateMemoryFn, "vkAllocateMemory");
        self.vkFreeMemory = loader_mod.Loader.loadDevice(gdp, dev, FreeMemoryFn, "vkFreeMemory");
        self.vkMapMemory = loader_mod.Loader.loadDevice(gdp, dev, MapMemoryFn, "vkMapMemory");
        self.vkUnmapMemory = loader_mod.Loader.loadDevice(gdp, dev, UnmapMemoryFn, "vkUnmapMemory");
        self.vkCreateDescriptorSetLayout = loader_mod.Loader.loadDevice(gdp, dev, CreateDescriptorSetLayoutFn, "vkCreateDescriptorSetLayout");
        self.vkDestroyDescriptorSetLayout = loader_mod.Loader.loadDevice(gdp, dev, DestroyDescriptorSetLayoutFn, "vkDestroyDescriptorSetLayout");
        self.vkCreateDescriptorPool = loader_mod.Loader.loadDevice(gdp, dev, CreateDescriptorPoolFn, "vkCreateDescriptorPool");
        self.vkDestroyDescriptorPool = loader_mod.Loader.loadDevice(gdp, dev, DestroyDescriptorPoolFn, "vkDestroyDescriptorPool");
        self.vkAllocateDescriptorSets = loader_mod.Loader.loadDevice(gdp, dev, AllocateDescriptorSetsFn, "vkAllocateDescriptorSets");
        self.vkUpdateDescriptorSets = loader_mod.Loader.loadDevice(gdp, dev, UpdateDescriptorSetsFn, "vkUpdateDescriptorSets");
        self.vkCreatePipelineLayout = loader_mod.Loader.loadDevice(gdp, dev, CreatePipelineLayoutFn, "vkCreatePipelineLayout");
        self.vkDestroyPipelineLayout = loader_mod.Loader.loadDevice(gdp, dev, DestroyPipelineLayoutFn, "vkDestroyPipelineLayout");
        self.vkCreateGraphicsPipelines = loader_mod.Loader.loadDevice(gdp, dev, CreateGraphicsPipelinesFn, "vkCreateGraphicsPipelines");
        self.vkDestroyPipeline = loader_mod.Loader.loadDevice(gdp, dev, DestroyPipelineFn, "vkDestroyPipeline");
        self.vkCreateRenderPass = loader_mod.Loader.loadDevice(gdp, dev, CreateRenderPassFn, "vkCreateRenderPass");
        self.vkDestroyRenderPass = loader_mod.Loader.loadDevice(gdp, dev, DestroyRenderPassFn, "vkDestroyRenderPass");
        self.vkCreateFramebuffer = loader_mod.Loader.loadDevice(gdp, dev, CreateFramebufferFn, "vkCreateFramebuffer");
        self.vkDestroyFramebuffer = loader_mod.Loader.loadDevice(gdp, dev, DestroyFramebufferFn, "vkDestroyFramebuffer");
        self.vkCreateShaderModule = loader_mod.Loader.loadDevice(gdp, dev, pipeline_mod.CreateShaderModuleFn, "vkCreateShaderModule");
        self.vkDestroyShaderModule = loader_mod.Loader.loadDevice(gdp, dev, pipeline_mod.DestroyShaderModuleFn, "vkDestroyShaderModule");
        self.vkBeginCommandBuffer = loader_mod.Loader.loadDevice(gdp, dev, BeginCommandBufferFn, "vkBeginCommandBuffer");
        self.vkEndCommandBuffer = loader_mod.Loader.loadDevice(gdp, dev, EndCommandBufferFn, "vkEndCommandBuffer");
        self.vkResetCommandBuffer = loader_mod.Loader.loadDevice(gdp, dev, ResetCommandBufferFn, "vkResetCommandBuffer");
        self.vkQueueSubmit = loader_mod.Loader.loadDevice(gdp, dev, QueueSubmitFn, "vkQueueSubmit");
        self.vkQueueWaitIdle = loader_mod.Loader.loadDevice(gdp, dev, QueueWaitIdleFn, "vkQueueWaitIdle");
        self.vkCmdPipelineBarrier = loader_mod.Loader.loadDevice(gdp, dev, CmdPipelineBarrierFn, "vkCmdPipelineBarrier");
        self.vkCmdCopyBufferToImage = loader_mod.Loader.loadDevice(gdp, dev, CmdCopyBufferToImageFn, "vkCmdCopyBufferToImage");
        self.vkCmdBeginRenderPass = loader_mod.Loader.loadDevice(gdp, dev, CmdBeginRenderPassFn, "vkCmdBeginRenderPass");
        self.vkCmdEndRenderPass = loader_mod.Loader.loadDevice(gdp, dev, CmdEndRenderPassFn, "vkCmdEndRenderPass");
        self.vkCmdBindPipeline = loader_mod.Loader.loadDevice(gdp, dev, CmdBindPipelineFn, "vkCmdBindPipeline");
        self.vkCmdBindVertexBuffers = loader_mod.Loader.loadDevice(gdp, dev, CmdBindVertexBuffersFn, "vkCmdBindVertexBuffers");
        self.vkCmdBindIndexBuffer = loader_mod.Loader.loadDevice(gdp, dev, CmdBindIndexBufferFn, "vkCmdBindIndexBuffer");
        self.vkCmdBindDescriptorSets = loader_mod.Loader.loadDevice(gdp, dev, CmdBindDescriptorSetsFn, "vkCmdBindDescriptorSets");
        self.vkCmdDrawIndexed = loader_mod.Loader.loadDevice(gdp, dev, CmdDrawIndexedFn, "vkCmdDrawIndexed");
        self.vkCmdSetViewport = loader_mod.Loader.loadDevice(gdp, dev, CmdSetViewportFn, "vkCmdSetViewport");
        self.vkCmdSetScissor = loader_mod.Loader.loadDevice(gdp, dev, CmdSetScissorFn, "vkCmdSetScissor");

        if (self.vkCreateGraphicsPipelines == null or self.vkCreateRenderPass == null or self.vkCreateShaderModule == null) {
            return error.MissingTextProcs;
        }
    }

    fn createAtlas(self: *TextPipeline, h: Handles, cmd: vk.VkCommandBuffer) !void {
        const size = software.atlasPixelSize();
        const pixels = try h.allocator.alloc(u8, size.w * size.h);
        defer h.allocator.free(pixels);
        software.writeAtlasR8(pixels);

        var img_info = std.mem.zeroes(vk.raw.VkImageCreateInfo);
        img_info.sType = vk.raw.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = vk.raw.VK_IMAGE_TYPE_2D;
        img_info.format = vk.raw.VK_FORMAT_R8_UNORM;
        img_info.extent = .{ .width = size.w, .height = size.h, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.samples = vk.raw.VK_SAMPLE_COUNT_1_BIT;
        img_info.tiling = vk.raw.VK_IMAGE_TILING_OPTIMAL;
        img_info.usage = vk.raw.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.raw.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.sharingMode = vk.raw.VK_SHARING_MODE_EXCLUSIVE;
        img_info.initialLayout = vk.raw.VK_IMAGE_LAYOUT_UNDEFINED;

        const create_img = self.vkCreateImage orelse return error.MissingCreateImage;
        var image: vk.VkImage = null;
        if (create_img(h.device, &img_info, null, &image) != vk.VK_SUCCESS or image == null) return error.CreateAtlasImageFailed;
        self.atlas_image = image;

        var reqs = std.mem.zeroes(vk.raw.VkMemoryRequirements);
        (self.vkGetImageMemoryRequirements orelse return error.MissingImgReqs)(h.device, image, &reqs);
        const mem_type = try self.findMemory(h, reqs.memoryTypeBits, vk.raw.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, vk.raw.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
        self.atlas_mem = try self.allocMemory(h, reqs.size, mem_type);
        const bind_img = self.vkBindImageMemory orelse return error.MissingBindImage;
        if (bind_img(h.device, image, self.atlas_mem, 0) != vk.VK_SUCCESS) return error.BindAtlasFailed;

        var view_info = std.mem.zeroes(vk.raw.VkImageViewCreateInfo);
        view_info.sType = vk.raw.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = image;
        view_info.viewType = vk.raw.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = vk.raw.VK_FORMAT_R8_UNORM;
        view_info.subresourceRange = .{
            .aspectMask = vk.raw.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        const create_view = self.vkCreateImageView orelse return error.MissingImageView;
        var view: vk.VkImageView = null;
        if (create_view(h.device, &view_info, null, &view) != vk.VK_SUCCESS or view == null) return error.CreateAtlasViewFailed;
        self.atlas_view = view;

        var samp_info = std.mem.zeroes(vk.raw.VkSamplerCreateInfo);
        samp_info.sType = vk.raw.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        samp_info.magFilter = vk.raw.VK_FILTER_NEAREST;
        samp_info.minFilter = vk.raw.VK_FILTER_NEAREST;
        samp_info.mipmapMode = vk.raw.VK_SAMPLER_MIPMAP_MODE_NEAREST;
        samp_info.addressModeU = vk.raw.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        samp_info.addressModeV = vk.raw.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        samp_info.addressModeW = vk.raw.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        samp_info.maxLod = 0;
        samp_info.borderColor = vk.raw.VK_BORDER_COLOR_INT_OPAQUE_BLACK;
        const create_samp = self.vkCreateSampler orelse return error.MissingSampler;
        var sampler: vk.VkSampler = null;
        if (create_samp(h.device, &samp_info, null, &sampler) != vk.VK_SUCCESS or sampler == null) return error.CreateSamplerFailed;
        self.sampler = sampler;

        const staging_size = pixels.len;
        var staging_buf: vk.VkBuffer = null;
        var staging_mem: vk.VkDeviceMemory = null;
        try self.createHostBuffer(h, staging_size, vk.raw.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &staging_buf, &staging_mem);
        defer {
            if (self.vkDestroyBuffer) |d| d(h.device, staging_buf, null);
            if (self.vkFreeMemory) |d| d(h.device, staging_mem, null);
        }

        const map = self.vkMapMemory orelse return error.MissingMap;
        var mapped: ?*anyopaque = null;
        if (map(h.device, staging_mem, 0, staging_size, 0, &mapped) != vk.VK_SUCCESS) return error.MapFailed;
        @memcpy(@as([*]u8, @ptrCast(mapped.?))[0..pixels.len], pixels);
        if (self.vkUnmapMemory) |unmap| unmap(h.device, staging_mem);

        if (self.vkResetCommandBuffer) |reset| _ = reset(cmd, 0);
        var begin_info = std.mem.zeroes(vk.raw.VkCommandBufferBeginInfo);
        begin_info.sType = vk.raw.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = vk.raw.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        const begin = self.vkBeginCommandBuffer orelse return error.MissingBegin;
        if (begin(cmd, &begin_info) != vk.VK_SUCCESS) return error.BeginFailed;

        const barrier_fn = self.vkCmdPipelineBarrier orelse return error.MissingBarrier;
        var to_dst = imageBarrier(image, vk.raw.VK_IMAGE_LAYOUT_UNDEFINED, vk.raw.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, vk.raw.VK_ACCESS_TRANSFER_WRITE_BIT);
        barrier_fn(cmd, vk.raw.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.raw.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, @ptrCast(&to_dst));

        var region = std.mem.zeroes(vk.raw.VkBufferImageCopy);
        region.imageSubresource.aspectMask = vk.raw.VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = .{ .width = size.w, .height = size.h, .depth = 1 };
        (self.vkCmdCopyBufferToImage orelse return error.MissingCopy)(cmd, staging_buf, image, vk.raw.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @ptrCast(&region));

        var to_shader = imageBarrier(image, vk.raw.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.raw.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.raw.VK_ACCESS_TRANSFER_WRITE_BIT, vk.raw.VK_ACCESS_SHADER_READ_BIT);
        barrier_fn(cmd, vk.raw.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.raw.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, @ptrCast(&to_shader));

        const end = self.vkEndCommandBuffer orelse return error.MissingEnd;
        if (end(cmd) != vk.VK_SUCCESS) return error.EndFailed;
        var submit = std.mem.zeroes(vk.raw.VkSubmitInfo);
        submit.sType = vk.raw.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = @ptrCast(&cmd);
        if ((self.vkQueueSubmit orelse return error.MissingSubmit)(h.queue, 1, @ptrCast(&submit), null) != vk.VK_SUCCESS) return error.SubmitFailed;
        if (self.vkQueueWaitIdle) |wait| _ = wait(h.queue);
    }

    fn createDescriptors(self: *TextPipeline, h: Handles) !void {
        var binding = std.mem.zeroes(vk.raw.VkDescriptorSetLayoutBinding);
        binding.binding = 0;
        binding.descriptorType = vk.raw.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        binding.descriptorCount = 1;
        binding.stageFlags = vk.raw.VK_SHADER_STAGE_FRAGMENT_BIT;

        var layout_info = std.mem.zeroes(vk.raw.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = vk.raw.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = 1;
        layout_info.pBindings = @ptrCast(&binding);
        var dsl: vk.VkDescriptorSetLayout = null;
        if ((self.vkCreateDescriptorSetLayout orelse return error.MissingDsl)(h.device, &layout_info, null, &dsl) != vk.VK_SUCCESS or dsl == null) {
            return error.CreateDslFailed;
        }
        self.dsl = dsl;

        var pool_size = std.mem.zeroes(vk.raw.VkDescriptorPoolSize);
        pool_size.type = vk.raw.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        pool_size.descriptorCount = 1;
        var pool_info = std.mem.zeroes(vk.raw.VkDescriptorPoolCreateInfo);
        pool_info.sType = vk.raw.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = 1;
        pool_info.poolSizeCount = 1;
        pool_info.pPoolSizes = @ptrCast(&pool_size);
        var pool: vk.VkDescriptorPool = null;
        if ((self.vkCreateDescriptorPool orelse return error.MissingDescPool)(h.device, &pool_info, null, &pool) != vk.VK_SUCCESS or pool == null) {
            return error.CreateDescPoolFailed;
        }
        self.desc_pool = pool;

        var alloc = std.mem.zeroes(vk.raw.VkDescriptorSetAllocateInfo);
        alloc.sType = vk.raw.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc.descriptorPool = pool;
        alloc.descriptorSetCount = 1;
        alloc.pSetLayouts = @ptrCast(&dsl);
        var set: vk.VkDescriptorSet = null;
        if ((self.vkAllocateDescriptorSets orelse return error.MissingAllocSets)(h.device, &alloc, &set) != vk.VK_SUCCESS or set == null) {
            return error.AllocDescSetFailed;
        }
        self.desc_set = set;

        var image_info = std.mem.zeroes(vk.raw.VkDescriptorImageInfo);
        image_info.sampler = self.sampler;
        image_info.imageView = self.atlas_view;
        image_info.imageLayout = vk.raw.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        var write = std.mem.zeroes(vk.raw.VkWriteDescriptorSet);
        write.sType = vk.raw.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = set;
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = vk.raw.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.pImageInfo = @ptrCast(&image_info);
        (self.vkUpdateDescriptorSets orelse return error.MissingUpdateDesc)(h.device, 1, @ptrCast(&write), 0, null);

        var pl_info = std.mem.zeroes(vk.raw.VkPipelineLayoutCreateInfo);
        pl_info.sType = vk.raw.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pl_info.setLayoutCount = 1;
        pl_info.pSetLayouts = @ptrCast(&dsl);
        var layout: vk.VkPipelineLayout = null;
        if ((self.vkCreatePipelineLayout orelse return error.MissingPipeLayout)(h.device, &pl_info, null, &layout) != vk.VK_SUCCESS or layout == null) {
            return error.CreatePipelineLayoutFailed;
        }
        self.pipeline_layout = layout;
    }

    fn createBuffers(self: *TextPipeline, h: Handles) !void {
        try self.createHostBuffer(h, @sizeOf(@TypeOf(text.QUAD_VERTS)), vk.raw.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, &self.quad_buf, &self.quad_mem);
        try self.writeBuffer(h, self.quad_mem, std.mem.asBytes(&text.QUAD_VERTS));
        try self.createHostBuffer(h, @sizeOf(@TypeOf(text.QUAD_INDICES)), vk.raw.VK_BUFFER_USAGE_INDEX_BUFFER_BIT, &self.index_buf, &self.index_mem);
        try self.writeBuffer(h, self.index_mem, std.mem.asBytes(&text.QUAD_INDICES));
        try self.createHostBuffer(
            h,
            @as(usize, text.MAX_INSTANCES) * @sizeOf(text.Instance),
            vk.raw.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            &self.inst_buf,
            &self.inst_mem,
        );
    }

    fn createRenderPass(self: *TextPipeline, h: Handles, format: vk.VkFormat) !void {
        var color = std.mem.zeroes(vk.raw.VkAttachmentDescription);
        color.format = format;
        color.samples = vk.raw.VK_SAMPLE_COUNT_1_BIT;
        color.loadOp = vk.raw.VK_ATTACHMENT_LOAD_OP_CLEAR;
        color.storeOp = vk.raw.VK_ATTACHMENT_STORE_OP_STORE;
        color.stencilLoadOp = vk.raw.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        color.stencilStoreOp = vk.raw.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        color.initialLayout = vk.raw.VK_IMAGE_LAYOUT_UNDEFINED;
        color.finalLayout = vk.raw.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        var ref = vk.raw.VkAttachmentReference{
            .attachment = 0,
            .layout = vk.raw.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };
        var sub = std.mem.zeroes(vk.raw.VkSubpassDescription);
        sub.pipelineBindPoint = vk.raw.VK_PIPELINE_BIND_POINT_GRAPHICS;
        sub.colorAttachmentCount = 1;
        sub.pColorAttachments = @ptrCast(&ref);

        var deps = [_]vk.raw.VkSubpassDependency{ std.mem.zeroes(vk.raw.VkSubpassDependency), std.mem.zeroes(vk.raw.VkSubpassDependency) };
        deps[0].srcSubpass = vk.raw.VK_SUBPASS_EXTERNAL;
        deps[0].dstSubpass = 0;
        deps[0].srcStageMask = vk.raw.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        deps[0].dstStageMask = vk.raw.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        deps[0].srcAccessMask = 0;
        deps[0].dstAccessMask = vk.raw.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        deps[1].srcSubpass = 0;
        deps[1].dstSubpass = vk.raw.VK_SUBPASS_EXTERNAL;
        deps[1].srcStageMask = vk.raw.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        deps[1].dstStageMask = vk.raw.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;
        deps[1].srcAccessMask = vk.raw.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        deps[1].dstAccessMask = 0;

        var info = std.mem.zeroes(vk.raw.VkRenderPassCreateInfo);
        info.sType = vk.raw.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        info.attachmentCount = 1;
        info.pAttachments = @ptrCast(&color);
        info.subpassCount = 1;
        info.pSubpasses = @ptrCast(&sub);
        info.dependencyCount = 2;
        info.pDependencies = &deps;
        var rp: vk.VkRenderPass = null;
        if ((self.vkCreateRenderPass orelse return error.MissingRenderPass)(h.device, &info, null, &rp) != vk.VK_SUCCESS or rp == null) {
            return error.CreateRenderPassFailed;
        }
        self.render_pass = rp;
    }

    fn createPipeline(self: *TextPipeline, h: Handles) !void {
        const create_sm = self.vkCreateShaderModule orelse return error.MissingShaderModule;
        var vert = try pipeline_mod.ShaderModule.init(h.device, create_sm, pipeline_mod.vert_spv, h.allocator);
        defer vert.deinit(h.device, self.vkDestroyShaderModule);
        var frag = try pipeline_mod.ShaderModule.init(h.device, create_sm, pipeline_mod.frag_spv, h.allocator);
        defer frag.deinit(h.device, self.vkDestroyShaderModule);

        var stages = [_]vk.raw.VkPipelineShaderStageCreateInfo{ std.mem.zeroes(vk.raw.VkPipelineShaderStageCreateInfo), std.mem.zeroes(vk.raw.VkPipelineShaderStageCreateInfo) };
        stages[0].sType = vk.raw.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = vk.raw.VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = vert.module;
        stages[0].pName = "main";
        stages[1].sType = vk.raw.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = vk.raw.VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = frag.module;
        stages[1].pName = "main";

        var bindings = [_]vk.raw.VkVertexInputBindingDescription{
            .{ .binding = 0, .stride = @sizeOf(text.Vertex), .inputRate = vk.raw.VK_VERTEX_INPUT_RATE_VERTEX },
            .{ .binding = 1, .stride = @sizeOf(text.Instance), .inputRate = vk.raw.VK_VERTEX_INPUT_RATE_INSTANCE },
        };
        var attrs = [_]vk.raw.VkVertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = vk.raw.VK_FORMAT_R32G32_SFLOAT, .offset = 0 },
            .{ .location = 1, .binding = 1, .format = vk.raw.VK_FORMAT_R32G32_SFLOAT, .offset = 0 },
            .{ .location = 2, .binding = 1, .format = vk.raw.VK_FORMAT_R32G32_SFLOAT, .offset = 8 },
            .{ .location = 3, .binding = 1, .format = vk.raw.VK_FORMAT_R32G32_SFLOAT, .offset = 16 },
            .{ .location = 4, .binding = 1, .format = vk.raw.VK_FORMAT_R32G32_SFLOAT, .offset = 24 },
            .{ .location = 5, .binding = 1, .format = vk.raw.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = 32 },
            .{ .location = 6, .binding = 1, .format = vk.raw.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = 48 },
        };
        var vi = std.mem.zeroes(vk.raw.VkPipelineVertexInputStateCreateInfo);
        vi.sType = vk.raw.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vi.vertexBindingDescriptionCount = bindings.len;
        vi.pVertexBindingDescriptions = &bindings;
        vi.vertexAttributeDescriptionCount = attrs.len;
        vi.pVertexAttributeDescriptions = &attrs;

        var ia = std.mem.zeroes(vk.raw.VkPipelineInputAssemblyStateCreateInfo);
        ia.sType = vk.raw.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia.topology = vk.raw.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        var vp = std.mem.zeroes(vk.raw.VkPipelineViewportStateCreateInfo);
        vp.sType = vk.raw.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        vp.viewportCount = 1;
        vp.scissorCount = 1;

        var rs = std.mem.zeroes(vk.raw.VkPipelineRasterizationStateCreateInfo);
        rs.sType = vk.raw.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs.polygonMode = vk.raw.VK_POLYGON_MODE_FILL;
        rs.cullMode = vk.raw.VK_CULL_MODE_NONE;
        rs.frontFace = vk.raw.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rs.lineWidth = 1.0;

        var ms = std.mem.zeroes(vk.raw.VkPipelineMultisampleStateCreateInfo);
        ms.sType = vk.raw.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms.rasterizationSamples = vk.raw.VK_SAMPLE_COUNT_1_BIT;

        var blend_att = std.mem.zeroes(vk.raw.VkPipelineColorBlendAttachmentState);
        blend_att.colorWriteMask = vk.raw.VK_COLOR_COMPONENT_R_BIT | vk.raw.VK_COLOR_COMPONENT_G_BIT | vk.raw.VK_COLOR_COMPONENT_B_BIT | vk.raw.VK_COLOR_COMPONENT_A_BIT;

        var cb = std.mem.zeroes(vk.raw.VkPipelineColorBlendStateCreateInfo);
        cb.sType = vk.raw.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        cb.attachmentCount = 1;
        cb.pAttachments = @ptrCast(&blend_att);

        var dyn_states = [_]vk.raw.VkDynamicState{ vk.raw.VK_DYNAMIC_STATE_VIEWPORT, vk.raw.VK_DYNAMIC_STATE_SCISSOR };
        var dyn = std.mem.zeroes(vk.raw.VkPipelineDynamicStateCreateInfo);
        dyn.sType = vk.raw.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dyn.dynamicStateCount = dyn_states.len;
        dyn.pDynamicStates = &dyn_states;

        var gp = std.mem.zeroes(vk.raw.VkGraphicsPipelineCreateInfo);
        gp.sType = vk.raw.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        gp.stageCount = 2;
        gp.pStages = &stages;
        gp.pVertexInputState = &vi;
        gp.pInputAssemblyState = &ia;
        gp.pViewportState = &vp;
        gp.pRasterizationState = &rs;
        gp.pMultisampleState = &ms;
        gp.pColorBlendState = &cb;
        gp.pDynamicState = &dyn;
        gp.layout = self.pipeline_layout;
        gp.renderPass = self.render_pass;
        gp.subpass = 0;

        var pipe: vk.VkPipeline = null;
        const cache: vk.raw.VkPipelineCache = null;
        if ((self.vkCreateGraphicsPipelines orelse return error.MissingCreatePipeline)(h.device, cache, 1, @ptrCast(&gp), null, &pipe) != vk.VK_SUCCESS or pipe == null) {
            return error.CreateGraphicsPipelineFailed;
        }
        self.pipeline = pipe;
    }

    fn destroyPipeline(self: *TextPipeline, h: Handles) void {
        if (self.pipeline != null) {
            if (self.vkDestroyPipeline) |d| d(h.device, self.pipeline, null);
            self.pipeline = null;
        }
        if (self.render_pass != null) {
            if (self.vkDestroyRenderPass) |d| d(h.device, self.render_pass, null);
            self.render_pass = null;
        }
    }

    fn destroyAtlas(self: *TextPipeline, h: Handles) void {
        if (self.inst_buf != null) {
            if (self.vkDestroyBuffer) |d| d(h.device, self.inst_buf, null);
            self.inst_buf = null;
        }
        if (self.inst_mem != null) {
            if (self.vkFreeMemory) |d| d(h.device, self.inst_mem, null);
            self.inst_mem = null;
        }
        if (self.index_buf != null) {
            if (self.vkDestroyBuffer) |d| d(h.device, self.index_buf, null);
            self.index_buf = null;
        }
        if (self.index_mem != null) {
            if (self.vkFreeMemory) |d| d(h.device, self.index_mem, null);
            self.index_mem = null;
        }
        if (self.quad_buf != null) {
            if (self.vkDestroyBuffer) |d| d(h.device, self.quad_buf, null);
            self.quad_buf = null;
        }
        if (self.quad_mem != null) {
            if (self.vkFreeMemory) |d| d(h.device, self.quad_mem, null);
            self.quad_mem = null;
        }
        if (self.pipeline_layout != null) {
            if (self.vkDestroyPipelineLayout) |d| d(h.device, self.pipeline_layout, null);
            self.pipeline_layout = null;
        }
        if (self.desc_pool != null) {
            if (self.vkDestroyDescriptorPool) |d| d(h.device, self.desc_pool, null);
            self.desc_pool = null;
            self.desc_set = null;
        }
        if (self.dsl != null) {
            if (self.vkDestroyDescriptorSetLayout) |d| d(h.device, self.dsl, null);
            self.dsl = null;
        }
        if (self.sampler != null) {
            if (self.vkDestroySampler) |d| d(h.device, self.sampler, null);
            self.sampler = null;
        }
        if (self.atlas_view != null) {
            if (self.vkDestroyImageView) |d| d(h.device, self.atlas_view, null);
            self.atlas_view = null;
        }
        if (self.atlas_image != null) {
            if (self.vkDestroyImage) |d| d(h.device, self.atlas_image, null);
            self.atlas_image = null;
        }
        if (self.atlas_mem != null) {
            if (self.vkFreeMemory) |d| d(h.device, self.atlas_mem, null);
            self.atlas_mem = null;
        }
    }

    fn createHostBuffer(self: *TextPipeline, h: Handles, bytes: usize, usage: u32, buf_out: *vk.VkBuffer, mem_out: *vk.VkDeviceMemory) !void {
        var info = std.mem.zeroes(vk.raw.VkBufferCreateInfo);
        info.sType = vk.raw.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = bytes;
        info.usage = usage;
        info.sharingMode = vk.raw.VK_SHARING_MODE_EXCLUSIVE;
        var buffer: vk.VkBuffer = null;
        if ((self.vkCreateBuffer orelse return error.MissingCreateBuffer)(h.device, &info, null, &buffer) != vk.VK_SUCCESS or buffer == null) {
            return error.CreateBufferFailed;
        }
        var reqs = std.mem.zeroes(vk.raw.VkMemoryRequirements);
        (self.vkGetBufferMemoryRequirements orelse return error.MissingMemReqs)(h.device, buffer, &reqs);
        const mem_type = try self.findMemory(h, reqs.memoryTypeBits, vk.raw.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.raw.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, 0);
        const memory = try self.allocMemory(h, reqs.size, mem_type);
        if ((self.vkBindBufferMemory orelse return error.MissingBind)(h.device, buffer, memory, 0) != vk.VK_SUCCESS) return error.BindMemoryFailed;
        buf_out.* = buffer;
        mem_out.* = memory;
    }

    fn writeBuffer(self: *TextPipeline, h: Handles, memory: vk.VkDeviceMemory, bytes: []const u8) !void {
        const map = self.vkMapMemory orelse return error.MissingMap;
        var mapped: ?*anyopaque = null;
        if (map(h.device, memory, 0, bytes.len, 0, &mapped) != vk.VK_SUCCESS) return error.MapFailed;
        defer if (self.vkUnmapMemory) |unmap| unmap(h.device, memory);
        @memcpy(@as([*]u8, @ptrCast(mapped.?))[0..bytes.len], bytes);
    }

    fn allocMemory(self: *TextPipeline, h: Handles, size: vk.raw.VkDeviceSize, mem_type: u32) !vk.VkDeviceMemory {
        var info = std.mem.zeroes(vk.raw.VkMemoryAllocateInfo);
        info.sType = vk.raw.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        info.allocationSize = size;
        info.memoryTypeIndex = mem_type;
        var memory: vk.VkDeviceMemory = null;
        if ((self.vkAllocateMemory orelse return error.MissingAllocMem)(h.device, &info, null, &memory) != vk.VK_SUCCESS or memory == null) {
            return error.AllocateMemoryFailed;
        }
        return memory;
    }

    fn findMemory(self: *TextPipeline, h: Handles, type_filter: u32, required: u32, fallback: u32) !u32 {
        var props = std.mem.zeroes(vk.raw.VkPhysicalDeviceMemoryProperties);
        (self.vkGetPhysicalDeviceMemoryProperties orelse return error.MissingMemProps)(h.physical_device, &props);
        if (pickMemory(props, type_filter, required)) |idx| return idx;
        if (fallback != 0) {
            if (pickMemory(props, type_filter, fallback)) |idx| return idx;
        }
        return error.NoMemoryType;
    }
};

fn pickMemory(props: vk.raw.VkPhysicalDeviceMemoryProperties, type_filter: u32, flags: u32) ?u32 {
    var i: u32 = 0;
    while (i < props.memoryTypeCount) : (i += 1) {
        if ((type_filter & (@as(u32, 1) << @intCast(i))) != 0 and (props.memoryTypes[i].propertyFlags & flags) == flags) {
            return i;
        }
    }
    return null;
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

test "TextPipeline starts disabled" {
    const p = TextPipeline{};
    try std.testing.expect(!p.enabled);
}
