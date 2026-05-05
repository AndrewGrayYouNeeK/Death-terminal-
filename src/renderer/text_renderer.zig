const std = @import("std");
const vk = @import("vulkan_c.zig");

/// GlyphAtlas manages a texture atlas of rendered glyphs for efficient text rendering
pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    atlas_image: ?vk.VkImage,
    atlas_memory: ?vk.VkDeviceMemory,
    atlas_view: ?vk.VkImageView,
    sampler: ?vk.VkSampler,
    width: u32,
    height: u32,
    glyph_cache: std.AutoHashMap(u32, GlyphInfo),

    pub const GlyphInfo = struct {
        // Position in atlas (normalized coords)
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        // Glyph metrics
        bearing_x: i32,
        bearing_y: i32,
        advance: u32,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        atlas_size: u32,
    ) !GlyphAtlas {
        _ = device;
        _ = physical_device;

        var atlas = GlyphAtlas{
            .allocator = allocator,
            .atlas_image = null,
            .atlas_memory = null,
            .atlas_view = null,
            .sampler = null,
            .width = atlas_size,
            .height = atlas_size,
            .glyph_cache = std.AutoHashMap(u32, GlyphInfo).init(allocator),
        };

        // TODO: Implement glyph atlas creation:
        // 1. Create image (RGBA8, atlas_size x atlas_size)
        // 2. Allocate and bind memory
        // 3. Create image view
        // 4. Create sampler (linear filtering)
        // 5. Load font and render ASCII glyphs to atlas

        std.debug.print("    → Glyph atlas creation (stubbed, {}x{})\n", .{ atlas_size, atlas_size });

        return atlas;
    }

    pub fn deinit(self: *GlyphAtlas, device: vk.VkDevice) void {
        _ = device;

        // TODO: Destroy sampler, image view, image, and free memory

        self.glyph_cache.deinit();
    }

    /// Get glyph info from cache, or render and cache if not present
    pub fn getGlyph(self: *GlyphAtlas, codepoint: u32) ?GlyphInfo {
        return self.glyph_cache.get(codepoint);
    }

    /// Render and cache a glyph
    fn cacheGlyph(self: *GlyphAtlas, device: vk.VkDevice, codepoint: u32) !void {
        _ = self;
        _ = device;
        _ = codepoint;

        // TODO: Implement glyph caching:
        // 1. Load glyph using font library (e.g., FreeType)
        // 2. Render glyph to bitmap
        // 3. Find space in atlas
        // 4. Upload bitmap to atlas texture
        // 5. Store glyph info in cache
    }

    /// Upload glyph bitmap to atlas texture
    fn uploadGlyphBitmap(
        self: *GlyphAtlas,
        device: vk.VkDevice,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        bitmap: []const u8,
    ) !void {
        _ = self;
        _ = device;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        _ = bitmap;

        // TODO: Create staging buffer, copy bitmap data, transfer to image
    }
};

/// TextRenderer manages rendering text using the glyph atlas
pub const TextRenderer = struct {
    allocator: std.mem.Allocator,
    vertex_buffer: ?vk.VkBuffer,
    vertex_memory: ?vk.VkDeviceMemory,
    index_buffer: ?vk.VkBuffer,
    index_memory: ?vk.VkDeviceMemory,
    max_glyphs: u32,

    pub const Vertex = struct {
        x: f32,
        y: f32,
        u: f32,
        v: f32,
        color: u32,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        max_glyphs: u32,
    ) !TextRenderer {
        _ = device;
        _ = physical_device;

        var renderer = TextRenderer{
            .allocator = allocator,
            .vertex_buffer = null,
            .vertex_memory = null,
            .index_buffer = null,
            .index_memory = null,
            .max_glyphs = max_glyphs,
        };

        // TODO: Allocate vertex and index buffers
        // Each glyph needs 4 vertices and 6 indices (two triangles)

        std.debug.print("    → Text renderer creation (stubbed, {} max glyphs)\n", .{max_glyphs});

        return renderer;
    }

    pub fn deinit(self: *TextRenderer, device: vk.VkDevice) void {
        _ = self;
        _ = device;

        // TODO: Destroy buffers and free memory
    }

    /// Generate vertex data for terminal cells
    pub fn generateVertices(
        self: *TextRenderer,
        cells: []const anyopaque,
        rows: u32,
        cols: u32,
        atlas: *const GlyphAtlas,
    ) ![]Vertex {
        _ = self;
        _ = cells;
        _ = rows;
        _ = cols;
        _ = atlas;

        // TODO: Implement vertex generation:
        // 1. Iterate through visible terminal cells
        // 2. For each cell with a character:
        //    - Look up glyph in atlas
        //    - Generate 4 vertices with position and texture coords
        //    - Apply cell colors
        // 3. Return vertex array

        return &[_]Vertex{};
    }

    /// Upload vertex data to GPU
    pub fn uploadVertices(
        self: *TextRenderer,
        device: vk.VkDevice,
        vertices: []const Vertex,
    ) !void {
        _ = self;
        _ = device;
        _ = vertices;

        // TODO: Map vertex buffer memory and copy vertex data
    }

    /// Draw text
    pub fn draw(
        self: *TextRenderer,
        command_buffer: vk.VkCommandBuffer,
        vertex_count: u32,
    ) void {
        _ = self;
        _ = command_buffer;
        _ = vertex_count;

        // TODO: Call vkCmdDrawIndexed
    }
};
