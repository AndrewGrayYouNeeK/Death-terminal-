const std = @import("std");
const vk = @import("vulkan_c.zig");

pub const vert_spv = @embedFile("shaders/text.vert.spv");
pub const frag_spv = @embedFile("shaders/text.frag.spv");

pub const CreateShaderModuleFn = *const fn (vk.VkDevice, *const vk.raw.VkShaderModuleCreateInfo, ?*const anyopaque, *vk.VkShaderModule) callconv(.C) vk.VkResult;
pub const DestroyShaderModuleFn = *const fn (vk.VkDevice, vk.VkShaderModule, ?*const anyopaque) callconv(.C) void;

/// Shader module wrapper around precompiled SPIR-V.
pub const ShaderModule = struct {
    module: vk.VkShaderModule = null,

    pub fn init(device: vk.VkDevice, create_fn: CreateShaderModuleFn, spirv: []const u8, allocator: std.mem.Allocator) !ShaderModule {
        if (spirv.len < 4 or spirv.len % 4 != 0) return error.InvalidSpirv;
        const words = try allocator.alloc(u32, spirv.len / 4);
        defer allocator.free(words);
        @memcpy(std.mem.sliceAsBytes(words), spirv);

        var info = std.mem.zeroes(vk.raw.VkShaderModuleCreateInfo);
        info.sType = vk.raw.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        info.codeSize = spirv.len;
        info.pCode = words.ptr;

        var module: vk.VkShaderModule = null;
        if (create_fn(device, &info, null, &module) != vk.VK_SUCCESS or module == null) {
            return error.CreateShaderModuleFailed;
        }
        return .{ .module = module };
    }

    pub fn deinit(self: *ShaderModule, device: vk.VkDevice, destroy_fn: ?DestroyShaderModuleFn) void {
        if (self.module != null) {
            if (destroy_fn) |d| d(device, self.module, null);
            self.module = null;
        }
    }
};

test "embedded SPIR-V has the magic number" {
    try std.testing.expect(vert_spv.len >= 4);
    try std.testing.expect(frag_spv.len >= 4);
    try std.testing.expectEqual(@as(u8, 0x03), vert_spv[0]);
    try std.testing.expectEqual(@as(u8, 0x02), vert_spv[1]);
    try std.testing.expectEqual(@as(u8, 0x23), vert_spv[2]);
    try std.testing.expectEqual(@as(u8, 0x07), vert_spv[3]);
}
