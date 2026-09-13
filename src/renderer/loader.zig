const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan_c.zig");

pub const GetInstanceProcAddrFn = *const fn (vk.VkInstance, [*:0]const u8) callconv(.C) vk.PFN_vkVoidFunction;
pub const GetDeviceProcAddrFn = *const fn (vk.VkDevice, [*:0]const u8) callconv(.C) vk.PFN_vkVoidFunction;
pub const CreateInstanceFn = *const fn ([*c]const vk.VkInstanceCreateInfo, ?*const anyopaque, *vk.VkInstance) callconv(.C) vk.VkResult;
pub const DestroyInstanceFn = *const fn (vk.VkInstance, ?*const anyopaque) callconv(.C) void;
pub const EnumeratePhysicalDevicesFn = *const fn (vk.VkInstance, *u32, ?[*]vk.VkPhysicalDevice) callconv(.C) vk.VkResult;
pub const GetPhysicalDevicePropertiesFn = *const fn (vk.VkPhysicalDevice, *vk.VkPhysicalDeviceProperties) callconv(.C) void;
pub const GetPhysicalDeviceQueueFamilyPropertiesFn = *const fn (vk.VkPhysicalDevice, *u32, ?[*]vk.VkQueueFamilyProperties) callconv(.C) void;
pub const CreateDeviceFn = *const fn (vk.VkPhysicalDevice, [*c]const vk.VkDeviceCreateInfo, ?*const anyopaque, *vk.VkDevice) callconv(.C) vk.VkResult;
pub const DestroyDeviceFn = *const fn (vk.VkDevice, ?*const anyopaque) callconv(.C) void;
pub const GetDeviceQueueFn = *const fn (vk.VkDevice, u32, u32, *vk.VkQueue) callconv(.C) void;

fn libNames() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &[_][]const u8{"vulkan-1.dll"},
        .macos, .ios => &[_][]const u8{ "libvulkan.1.dylib", "libvulkan.dylib" },
        else => &[_][]const u8{ "libvulkan.so.1", "libvulkan.so" },
    };
}

pub fn castProc(comptime T: type, raw_fn: vk.PFN_vkVoidFunction) ?T {
    const fn_ptr = raw_fn orelse return null;
    return @ptrCast(fn_ptr);
}

/// Dynamically loaded Vulkan loader (`vkGetInstanceProcAddr` entry point).
pub const Loader = struct {
    lib: std.DynLib,
    vkGetInstanceProcAddr: GetInstanceProcAddrFn,

    pub fn open() !Loader {
        var lib = try openLib();
        const get_proc = lib.lookup(GetInstanceProcAddrFn, "vkGetInstanceProcAddr") orelse {
            lib.close();
            return error.MissingVkGetInstanceProcAddr;
        };
        return Loader{
            .lib = lib,
            .vkGetInstanceProcAddr = get_proc,
        };
    }

    pub fn close(self: *Loader) void {
        self.lib.close();
    }

    pub fn load(self: Loader, instance: vk.VkInstance, comptime T: type, name: [*:0]const u8) ?T {
        return castProc(T, self.vkGetInstanceProcAddr(instance, name));
    }

    pub fn loadDevice(get_device_proc: GetDeviceProcAddrFn, device: vk.VkDevice, comptime T: type, name: [*:0]const u8) ?T {
        return castProc(T, get_device_proc(device, name));
    }
};

fn openLib() !std.DynLib {
    for (libNames()) |name| {
        return std.DynLib.open(name) catch continue;
    }
    return error.VulkanLoaderMissing;
}

test "Vulkan loader opens and resolves vkGetInstanceProcAddr" {
    var loader = try Loader.open();
    defer loader.close();

    const create_fn = loader.load(null, CreateInstanceFn, "vkCreateInstance");
    try std.testing.expect(create_fn != null);
}
