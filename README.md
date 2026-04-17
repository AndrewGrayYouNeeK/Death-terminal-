# DeathTerminal 💀

**Brutalist terminal emulator with AI-powered autocomplete and cross-platform SSH tunneling**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Zig](https://img.shields.io/badge/Zig-0.13.0-orange.svg)](https://ziglang.org/)

## Overview

DeathTerminal is a high-performance, brutalist terminal emulator built with modern technology. It prioritizes raw power and functionality over visual polish, designed for developers, sysadmins, and power users who live in the terminal.

### Key Features

- **🤖 AI-Powered Autocomplete**: Intelligent command completion using context-aware AI via gRPC
- **🔐 Cross-Platform SSH Tunneling**: Seamless SSH connections and port forwarding on Windows, macOS, and Linux
- **⚡ Vulkan-Accelerated Rendering**: GPU-powered text rendering for buttery-smooth performance
- **🔧 Lua Scripting**: Extensive customization and automation via embedded Lua engine
- **🎯 Brutalist Design**: Minimal, high-contrast, no-nonsense interface focused on productivity

## Technology Stack

| Component | Technology | Purpose |
|-----------|-----------|---------|
| **Core Language** | Zig | Systems programming with zero-cost abstractions |
| **Rendering** | Vulkan | GPU-accelerated graphics and text rendering |
| **AI Backend** | gRPC | Low-latency communication with AI autocomplete service |
| **Scripting** | Lua 5.4 | User customization and extensibility |

## Prerequisites

Before building DeathTerminal, ensure you have the following installed:

### Required

- **Zig**: Version 0.13.0 or later
  - Download from [ziglang.org/download](https://ziglang.org/download/)
  - Or use a version manager like [zigup](https://github.com/marler8997/zigup)

- **Vulkan SDK**: Latest version
  - **Linux**: Install via package manager
    ```bash
    # Ubuntu/Debian
    sudo apt install vulkan-tools libvulkan-dev vulkan-validationlayers

    # Fedora
    sudo dnf install vulkan-tools vulkan-loader-devel

    # Arch
    sudo pacman -S vulkan-tools vulkan-headers vulkan-validation-layers
    ```
  - **macOS**: Install via [MoltenVK](https://github.com/KhronosGroup/MoltenVK)
    ```bash
    brew install molten-vk
    ```
  - **Windows**: Download from [LunarG Vulkan SDK](https://vulkan.lunarg.com/)

- **Lua 5.4**:
  - **Linux**:
    ```bash
    # Ubuntu/Debian
    sudo apt install liblua5.4-dev

    # Fedora
    sudo dnf install lua-devel

    # Arch
    sudo pacman -S lua
    ```
  - **macOS**:
    ```bash
    brew install lua
    ```
  - **Windows**: Download from [lua.org](https://www.lua.org/download.html)

## Building

### Clone the Repository

```bash
git clone https://github.com/AndrewGrayYouNeeK/Death-terminal-.git
cd Death-terminal-
```

### Build the Project

```bash
# Debug build
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Release with debug info
zig build -Doptimize=ReleaseSafe
```

### Run

```bash
# Run directly
zig build run

# Run with arguments
zig build run -- --help
```

### Install

```bash
# Install to system (requires appropriate permissions)
zig build install --prefix ~/.local

# Or specify custom prefix
zig build install --prefix /usr/local
```

## Testing

```bash
# Run all tests
zig build test

# Run with verbose output
zig build test --summary all
```

## Usage

### Basic Usage

```bash
# Start DeathTerminal
death-terminal

# Show version
death-terminal --version

# Show help
death-terminal --help
```

### Command Line Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Print help message |
| `-v, --version` | Print version information |
| `--config <file>` | Use custom configuration file |
| `--no-ai` | Disable AI autocomplete |
| `--ssh <host>` | Connect to SSH host on startup |

### Configuration

DeathTerminal looks for configuration files in the following locations (in order):

1. `./death-terminal.lua` (current directory)
2. `~/.config/death-terminal/config.lua` (Linux/macOS)
3. `%APPDATA%/death-terminal/config.lua` (Windows)

Example configuration (`config.lua`):

```lua
-- DeathTerminal Configuration

-- Terminal settings
terminal = {
    rows = 24,
    cols = 80,
    font_size = 14,
    font_family = "FiraCode Nerd Font Mono",
}

-- AI Autocomplete settings
ai = {
    enabled = true,
    endpoint = "localhost:50051",
    max_suggestions = 5,
    context_lines = 10,
}

-- SSH settings
ssh = {
    default_port = 22,
    keepalive_interval = 60,
    compression = true,
}

-- Theme (brutalist design)
theme = {
    background = "#000000",
    foreground = "#FFFFFF",
    cursor = "#FF0000",
    selection = "#333333",
}

-- Keybindings
keybindings = {
    copy = "Ctrl+Shift+C",
    paste = "Ctrl+Shift+V",
    new_tab = "Ctrl+Shift+T",
    close_tab = "Ctrl+Shift+W",
}
```

## Architecture

```
DeathTerminal/
├── src/
│   ├── main.zig              # Entry point and main loop
│   ├── renderer/
│   │   └── vulkan_renderer.zig   # Vulkan rendering engine
│   ├── terminal/
│   │   └── terminal.zig          # PTY and terminal emulation
│   ├── ai/
│   │   └── autocomplete.zig      # AI autocomplete via gRPC
│   ├── ssh/
│   │   └── tunnel.zig            # SSH tunneling and connections
│   └── scripting/
│       └── lua_engine.zig        # Lua scripting engine
├── build.zig                 # Build configuration
└── README.md                 # This file
```

## Development Roadmap

### Phase 1: Foundation ✅
- [x] Project structure and build system
- [x] Module stubs for all core components
- [x] Basic documentation

### Phase 2: Core Terminal (In Progress)
- [ ] PTY creation and process spawning
- [ ] Terminal state machine (ANSI/VT100 escape sequences)
- [ ] Input handling and key mapping
- [ ] Clipboard integration

### Phase 3: Vulkan Rendering
- [ ] Vulkan initialization and setup
- [ ] Text rendering with glyph atlas
- [ ] Color and styling support
- [ ] Performance optimization

### Phase 4: AI Integration
- [ ] gRPC client implementation
- [ ] Protocol buffers for AI communication
- [ ] Context gathering and suggestion display
- [ ] Local vs. remote model support

### Phase 5: SSH Tunneling
- [ ] libssh2 integration
- [ ] Connection management
- [ ] Port forwarding (local and remote)
- [ ] SOCKS proxy support

### Phase 6: Lua Scripting
- [ ] Lua C API integration
- [ ] API exposure for configuration
- [ ] Plugin system
- [ ] Example scripts and documentation

### Phase 7: Cross-Platform Polish
- [ ] Windows-specific features (ConPTY)
- [ ] macOS-specific features
- [ ] Linux optimization
- [ ] Distribution packaging

## Contributing

Contributions are welcome! Please follow these guidelines:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Code Style

- Follow Zig's standard formatting (`zig fmt`)
- Write tests for new functionality
- Document public APIs
- Keep functions focused and modular

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Security

DeathTerminal handles sensitive data including SSH credentials and terminal I/O. Security considerations:

- All SSH connections use standard cryptographic libraries
- Credentials are never logged or stored insecurely
- AI autocomplete context is sanitized before transmission
- Regular security audits and dependency updates

If you discover a security vulnerability, please email security@example.com (DO NOT open a public issue).

## Acknowledgments

- Inspired by modern terminals: [Alacritty](https://github.com/alacritty/alacritty), [Warp](https://www.warp.dev/), [Ghostty](https://ghostty.org/)
- Built with [Zig](https://ziglang.org/) - a modern systems programming language
- Powered by [Vulkan](https://www.vulkan.org/) for GPU acceleration
- Extended with [Lua](https://www.lua.org/) for scripting

## Support

- 📖 Documentation: [Wiki](https://github.com/AndrewGrayYouNeeK/Death-terminal-/wiki)
- 🐛 Bug Reports: [Issues](https://github.com/AndrewGrayYouNeeK/Death-terminal-/issues)
- 💬 Discussions: [GitHub Discussions](https://github.com/AndrewGrayYouNeeK/Death-terminal-/discussions)

---

**Made with 💀 by the DeathTerminal team**
