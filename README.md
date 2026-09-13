DeathTerminal 💀

A brutalist, GPU-accelerated terminal with AI-native command workflows

Fast. Minimal. Unapologetically powerful.

## Quick Start

```
git clone https://github.com/AndrewGrayYouNeeK/Death-terminal-.git
cd Death-terminal-
zig build run -- --headless
zig build run -- --gui
```

Requirements: Zig 0.13+, libvulkan-dev, libX11 for `--gui`.

## Current Status

Done: PTY + ANSI + scrollback, headless loop, software rasterizer, X11 window, Vulkan loader/instance.

In progress: GPU text pipeline / swapchain present.

Next: SPIR-V shaders, gRPC autocomplete, SSH + Lua.

## License

MIT
