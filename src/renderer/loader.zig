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
pub const EnumerateInstanceExtensionPropertiesFn = *const fn (?[*:0]const u8, *u32, ?[*]vk.raw.VkExtensionProperties) callconv(.C) vk.VkResult;
pub const EnumerateDeviceExtensionPropertiesFn = *const fn (vk.VkPhysicalDevice, ?[*:0]const u8, *u32, ?[*]vk.raw.VkExtensionProperties) callconv(.C) vk.VkResult;

/// Names tried inside the directory that contains the running executable.
const beside_exe = [_][]const u8{ "libvulkan.1.dylib", "libMoltenVK.dylib" };

fn libNames() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &[_][]const u8{"vulkan-1.dll"},
        // The Vulkan loader (with MoltenVK as its driver), else MoltenVK
        // itself. The executable's own directory is searched first (see
        // `openBesideExecutable`); then the .app Frameworks and the usual
        // install places (Homebrew, the LunarG SDK).
        .macos, .ios => &[_][]const u8{
            "libvulkan.1.dylib",
            "@executable_path/libvulkan.1.dylib",
            "@executable_path/libMoltenVK.dylib",
            "@executable_path/../Frameworks/libvulkan.1.dylib",
            "@executable_path/../Frameworks/libMoltenVK.dylib",
            "/opt/homebrew/lib/libvulkan.1.dylib",
            "/usr/local/lib/libvulkan.1.dylib",
            "libMoltenVK.dylib",
            "/opt/homebrew/lib/libMoltenVK.dylib",
            "/usr/local/lib/libMoltenVK.dylib",
        },
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
    if (builtin.os.tag == .macos) {
        if (openBesideExecutable()) |lib| return lib;
    }
    for (libNames()) |name| {
        return std.DynLib.open(name) catch continue;
    }
    return error.VulkanLoaderMissing;
}

const DarwinPath = if (builtin.os.tag == .macos) struct {
    extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;
} else struct {};

/// `dlopen` does not search the directory that contains the binary, so a
/// `libMoltenVK.dylib` dropped next to it is invisible unless
/// `DYLD_LIBRARY_PATH` is set. Resolve that directory with
/// `_NSGetExecutablePath` (the same place `@executable_path` names) and try
/// the loader and MoltenVK there first.
fn openBesideExecutable() ?std.DynLib {
    if (builtin.os.tag != .macos) return null;
    var exe_buf: [4096]u8 = undefined;
    var size: u32 = exe_buf.len;
    if (DarwinPath._NSGetExecutablePath(&exe_buf, &size) != 0) return null;
    const exe = std.mem.sliceTo(exe_buf[0..], 0);
    const dir = std.fs.path.dirname(exe) orelse return null;
    var path_buf: [4096]u8 = undefined;
    for (beside_exe) |name| {
        const full = pathBeside(dir, name, &path_buf) catch continue;
        if (std.DynLib.open(full)) |lib| return lib else |_| continue;
    }
    return null;
}

fn pathBeside(dir: []const u8, name: []const u8, buf: []u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name });
}

test "MoltenVK next to the executable is a candidate" {
    var buf: [160]u8 = undefined;
    const molten = try pathBeside("/Applications/DeathTerminal.app/Contents/MacOS", "libMoltenVK.dylib", &buf);
    try std.testing.expectEqualStrings("/Applications/DeathTerminal.app/Contents/MacOS/libMoltenVK.dylib", molten);
    const vulkan = try pathBeside("/opt/dt", "libvulkan.1.dylib", &buf);
    try std.testing.expectEqualStrings("/opt/dt/libvulkan.1.dylib", vulkan);
    try std.testing.expectEqualStrings(beside_exe[1], "libMoltenVK.dylib");
}

test "Vulkan loader opens and resolves vkGetInstanceProcAddr" {
    var loader = try Loader.open();
    defer loader.close();

    const create_fn = loader.load(null, CreateInstanceFn, "vkCreateInstance");
    try std.testing.expect(create_fn != null);
}
