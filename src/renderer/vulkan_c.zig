// Vulkan C API bindings for Zig
// This provides minimal Vulkan bindings needed for text rendering

const builtin = @import("builtin");

const c = if (builtin.os.tag == .linux) @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cDefine("VK_USE_PLATFORM_XLIB_KHR", "1");
    @cDefine("VK_USE_PLATFORM_WAYLAND_KHR", "1");
    @cInclude("X11/Xlib.h");
    @cInclude("wayland-client.h");
    @cInclude("vulkan/vulkan.h");
}) else if (builtin.os.tag == .windows) @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cDefine("VK_USE_PLATFORM_WIN32_KHR", "1");
    @cInclude("windows.h");
    @cInclude("vulkan/vulkan.h");
}) else @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cInclude("vulkan/vulkan.h");
});

pub const raw = c;

/// Vulkan 1.0 packed version (variant 0).
pub fn makeApiVersion(major: u32, minor: u32, patch: u32) u32 {
    return (major << 22) | (minor << 12) | patch;
}

pub const API_VERSION_1_0 = makeApiVersion(1, 0, 0);

// Re-export Vulkan types
pub const VkInstance = c.VkInstance;
pub const VkPhysicalDevice = c.VkPhysicalDevice;
pub const VkDevice = c.VkDevice;
pub const VkQueue = c.VkQueue;
pub const VkSurfaceKHR = c.VkSurfaceKHR;
pub const VkSwapchainKHR = c.VkSwapchainKHR;
pub const VkImage = c.VkImage;
pub const VkImageView = c.VkImageView;
pub const VkRenderPass = c.VkRenderPass;
pub const VkFramebuffer = c.VkFramebuffer;
pub const VkCommandPool = c.VkCommandPool;
pub const VkCommandBuffer = c.VkCommandBuffer;
pub const VkSemaphore = c.VkSemaphore;
pub const VkFence = c.VkFence;
pub const VkPipeline = c.VkPipeline;
pub const VkPipelineLayout = c.VkPipelineLayout;
pub const VkShaderModule = c.VkShaderModule;
pub const VkBuffer = c.VkBuffer;
pub const VkDeviceMemory = c.VkDeviceMemory;
pub const VkDescriptorSetLayout = c.VkDescriptorSetLayout;
pub const VkDescriptorPool = c.VkDescriptorPool;
pub const VkDescriptorSet = c.VkDescriptorSet;
pub const VkSampler = c.VkSampler;

// Constants
pub const VK_SUCCESS = c.VK_SUCCESS;
pub const VK_NULL_HANDLE = c.VK_NULL_HANDLE;
pub const VK_TRUE = c.VK_TRUE;
pub const VK_FALSE = c.VK_FALSE;

// Enums
pub const VkResult = c.VkResult;
pub const VkFormat = c.VkFormat;
pub const VkColorSpaceKHR = c.VkColorSpaceKHR;
pub const VkPresentModeKHR = c.VkPresentModeKHR;
pub const VkPhysicalDeviceType = c.VkPhysicalDeviceType;

// Structs
pub const VkApplicationInfo = c.VkApplicationInfo;
pub const VkInstanceCreateInfo = c.VkInstanceCreateInfo;
pub const VkDeviceCreateInfo = c.VkDeviceCreateInfo;
pub const VkDeviceQueueCreateInfo = c.VkDeviceQueueCreateInfo;
pub const VkPhysicalDeviceFeatures = c.VkPhysicalDeviceFeatures;
pub const VkPhysicalDeviceProperties = c.VkPhysicalDeviceProperties;
pub const VkQueueFamilyProperties = c.VkQueueFamilyProperties;
pub const VkSwapchainCreateInfoKHR = c.VkSwapchainCreateInfoKHR;
pub const VkExtent2D = c.VkExtent2D;
pub const VkSurfaceCapabilitiesKHR = c.VkSurfaceCapabilitiesKHR;
pub const VkSurfaceFormatKHR = c.VkSurfaceFormatKHR;

// Structure types
pub const VK_STRUCTURE_TYPE_APPLICATION_INFO = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;

// Queue flags
pub const VK_QUEUE_GRAPHICS_BIT = c.VK_QUEUE_GRAPHICS_BIT;

// Format values
pub const VK_FORMAT_B8G8R8A8_SRGB = c.VK_FORMAT_B8G8R8A8_SRGB;
pub const VK_FORMAT_R8G8B8A8_SRGB = c.VK_FORMAT_R8G8B8A8_SRGB;

// Color space
pub const VK_COLOR_SPACE_SRGB_NONLINEAR_KHR = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;

// Present modes
pub const VK_PRESENT_MODE_FIFO_KHR = c.VK_PRESENT_MODE_FIFO_KHR;
pub const VK_PRESENT_MODE_MAILBOX_KHR = c.VK_PRESENT_MODE_MAILBOX_KHR;

// Physical device types
pub const VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU = c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
pub const VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU = c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU;

pub const PFN_vkVoidFunction = c.PFN_vkVoidFunction;
pub const PFN_vkGetInstanceProcAddr = c.PFN_vkGetInstanceProcAddr;
pub const PFN_vkGetDeviceProcAddr = c.PFN_vkGetDeviceProcAddr;
pub const PFN_vkCreateInstance = c.PFN_vkCreateInstance;
pub const PFN_vkDestroyInstance = c.PFN_vkDestroyInstance;
pub const PFN_vkEnumeratePhysicalDevices = c.PFN_vkEnumeratePhysicalDevices;
pub const PFN_vkGetPhysicalDeviceProperties = c.PFN_vkGetPhysicalDeviceProperties;
pub const PFN_vkGetPhysicalDeviceQueueFamilyProperties = c.PFN_vkGetPhysicalDeviceQueueFamilyProperties;
pub const PFN_vkCreateDevice = c.PFN_vkCreateDevice;
pub const PFN_vkDestroyDevice = c.PFN_vkDestroyDevice;
pub const PFN_vkGetDeviceQueue = c.PFN_vkGetDeviceQueue;
