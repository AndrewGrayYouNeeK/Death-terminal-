const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan_c.zig");

const CreateInstanceFn = *const fn (
    pCreateInfo: *const vk.VkInstanceCreateInfo,
    pAllocator: ?*const anyopaque,
    pInstance: *vk.VkInstance,
) callconv(.C) vk.VkResult;

const DestroyInstanceFn = *const fn (
    instance: vk.VkInstance,
    pAllocator: ?*const anyopaque,
) callconv(.C) void;

const EnumeratePhysicalDevicesFn = *const fn (
    instance: vk.VkInstance,
    pPhysicalDeviceCount: *u32,
    pPhysicalDevices: ?[*]vk.VkPhysicalDevice,
) callconv(.C) vk.VkResult;

const GetPhysicalDevicePropertiesFn = *const fn (
    physicalDevice: vk.VkPhysicalDevice,
    pProperties: *vk.VkPhysicalDeviceProperties,
) callconv(.C) void;

const GetPhysicalDeviceQueueFamilyPropertiesFn = *const fn (
    physicalDevice: vk.VkPhysicalDevice,
    pQueueFamilyPropertyCount: *u32,
    pQueueFamilyProperties: ?[*]vk.VkQueueFamilyProperties,
) callconv(.C) void;

const CreateDeviceFn = *const fn (
    physicalDevice: vk.VkPhysicalDevice,
    pCreateInfo: *const vk.VkDeviceCreateInfo,
    pAllocator: ?*const anyopaque,
    pDevice: *vk.VkDevice,
) callconv(.C) vk.VkResult;

const DestroyDeviceFn = *const fn (
    device: vk.VkDevice,
    pAllocator: ?*const anyopaque,
) callconv(.C) void;

const GetDeviceQueueFn = *const fn (
    device: vk.VkDevice,
    queueFamilyIndex: u32,
    queueIndex: u32,
    pQueue: *vk.VkQueue,
) callconv(.C) void;

pub const Loader = struct {
    lib: ?std.DynLib,
    vkCreateInstance: ?CreateInstanceFn,
    vkDestroyInstance: ?DestroyInstanceFn,
    vkEnumeratePhysicalDevices: ?EnumeratePhysicalDevicesFn,
    vkGetPhysicalDeviceProperties: ?GetPhysicalDevicePropertiesFn,
    vkGetPhysicalDeviceQueueFamilyProperties: ?GetPhysicalDeviceQueueFamilyPropertiesFn,
    vkCreateDevice: ?CreateDeviceFn,
    vkDestroyDevice: ?DestroyDeviceFn,
    vkGetDeviceQueue: ?GetDeviceQueueFn,
    loaded: bool,

    pub fn init() Loader {
        var loader = Loader{
            .lib = null,
            .vkCreateInstance = null,
            .vkDestroyInstance = null,
            .vkEnumeratePhysicalDevices = null,
            .vkGetPhysicalDeviceProperties = null,
            .vkGetPhysicalDeviceQueueFamilyProperties = null,
            .vkCreateDevice = null,
            .vkDestroyDevice = null,
            .vkGetDeviceQueue = null,
            .loaded = false,
        };

        const names = [_][:0]const u8{
            "libvulkan.so.1",
            "libvulkan.so",
            "vulkan-1.dll",
            "libvulkan.1.dylib",
        };

        var opened_lib: ?std.DynLib = null;
        for (names) |name| {
            opened_lib = std.DynLib.open(name) catch continue;
            break;
        }
        var opened = opened_lib orelse {
            std.debug.print("    → Vulkan loader: no libvulkan on this machine\n", .{});
            return loader;
        };
        loader.lib = opened;

        loader.vkCreateInstance = opened.lookup(CreateInstanceFn, "vkCreateInstance");
        loader.vkDestroyInstance = opened.lookup(DestroyInstanceFn, "vkDestroyInstance");
        loader.vkEnumeratePhysicalDevices = opened.lookup(EnumeratePhysicalDevicesFn, "vkEnumeratePhysicalDevices");
        loader.vkGetPhysicalDeviceProperties = opened.lookup(GetPhysicalDevicePropertiesFn, "vkGetPhysicalDeviceProperties");
        loader.vkGetPhysicalDeviceQueueFamilyProperties = opened.lookup(GetPhysicalDeviceQueueFamilyPropertiesFn, "vkGetPhysicalDeviceQueueFamilyProperties");
        loader.vkCreateDevice = opened.lookup(CreateDeviceFn, "vkCreateDevice");
        loader.vkDestroyDevice = opened.lookup(DestroyDeviceFn, "vkDestroyDevice");
        loader.vkGetDeviceQueue = opened.lookup(GetDeviceQueueFn, "vkGetDeviceQueue");

        loader.loaded = loader.vkCreateInstance != null and loader.vkDestroyInstance != null;
        if (loader.loaded) {
            std.debug.print("    → Vulkan functions loaded from dynamic library\n", .{});
        } else {
            std.debug.print("    → Vulkan library found but required symbols missing\n", .{});
        }
        return loader;
    }

    pub fn deinit(self: *Loader) void {
        if (self.lib) |*lib| lib.close();
        self.lib = null;
        self.loaded = false;
    }
};
