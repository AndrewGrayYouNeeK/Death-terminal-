# Changelog

## [Unreleased]

### Added
- Software text rasterizer (`src/renderer/software.zig`)
- X11 window backend (`src/platform/window.zig`)
- `--gui` event loop
- Dynamic Vulkan loader and `vkCreateInstance` when libvulkan is present
- Local command-prefix autocomplete fallback
- Terminal grid tests without a live PTY

### Changed
- Headless redraw prints every column so the grid stays aligned
- Renderer backend is `software` or `vulkan_instance`
- Config owns its endpoint allocation

### Fixed
- GUI mode previously ignored `--gui` and stayed headless
