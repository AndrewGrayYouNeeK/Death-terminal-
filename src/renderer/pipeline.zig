const std = @import("std");
const vk = @import("vulkan_c.zig");

/// Pipeline manages the graphics pipeline for text rendering
pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    pipeline: ?vk.VkPipeline,
    pipeline_layout: ?vk.VkPipelineLayout,
    render_pass: ?vk.VkRenderPass,
    descriptor_set_layout: ?vk.VkDescriptorSetLayout,

    pub fn init(
        allocator: std.mem.Allocator,
        device: vk.VkDevice,
        format: vk.VkFormat,
    ) !Pipeline {
        _ = device;
        _ = format;

        var pipe = Pipeline{
            .allocator = allocator,
            .pipeline = null,
            .pipeline_layout = null,
            .render_pass = null,
            .descriptor_set_layout = null,
        };

        // TODO: Implement pipeline creation:
        // 1. Create descriptor set layout (for glyph atlas texture)
        // 2. Create render pass
        // 3. Load vertex and fragment shaders
        // 4. Create pipeline layout
        // 5. Create graphics pipeline with:
        //    - Vertex input for position and texture coords
        //    - Alpha blending for text rendering
        //    - Dynamic viewport and scissor

        std.debug.print("    → Graphics pipeline creation (stubbed)\n", .{});

        return pipe;
    }

    pub fn deinit(self: *Pipeline, device: vk.VkDevice) void {
        _ = device;

        // TODO: Destroy pipeline, layout, render pass, descriptor set layout

        self.* = .{
            .allocator = self.allocator,
            .pipeline = null,
            .pipeline_layout = null,
            .render_pass = null,
            .descriptor_set_layout = null,
        };
    }

    pub fn bind(self: *Pipeline, command_buffer: vk.VkCommandBuffer) void {
        _ = self;
        _ = command_buffer;

        // TODO: Call vkCmdBindPipeline
    }
};

/// Shader module wrapper
pub const ShaderModule = struct {
    module: ?vk.VkShaderModule,

    pub fn init(device: vk.VkDevice, spirv_code: []const u8) !ShaderModule {
        _ = device;
        _ = spirv_code;

        // TODO: Create shader module from SPIR-V bytecode
        std.debug.print("    → Shader module creation (stubbed)\n", .{});

        return ShaderModule{
            .module = null,
        };
    }

    pub fn deinit(self: *ShaderModule, device: vk.VkDevice) void {
        _ = self;
        _ = device;

        // TODO: Destroy shader module
    }
};
