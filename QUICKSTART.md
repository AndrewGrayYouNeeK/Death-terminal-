# Quick Start Guide

Get DeathTerminal up and running in minutes!

## Prerequisites Check

Before you begin, verify you have the required tools:

```bash
# Check Zig installation
zig version
# Should show: 0.13.0 or later

# Check Vulkan (Linux)
vulkaninfo --summary
# or
vkcube

# Check Lua
lua -v
# Should show: Lua 5.4.x
```

## Installation

### Option 1: Quick Start (Recommended for Testing)

```bash
# Clone the repository
git clone https://github.com/AndrewGrayYouNeeK/Death-terminal-.git
cd Death-terminal-

# Build and run
zig build run
```

### Option 2: System Installation

```bash
# Clone the repository
git clone https://github.com/AndrewGrayYouNeeK/Death-terminal-.git
cd Death-terminal-

# Build release version
zig build -Doptimize=ReleaseFast

# Install to ~/.local (add ~/.local/bin to PATH)
zig build install --prefix ~/.local

# Run from anywhere
death-terminal
```

### Option 3: Using Development Script

```bash
# Clone the repository
git clone https://github.com/AndrewGrayYouNeeK/Death-terminal-.git
cd Death-terminal-

# Make dev script executable
chmod +x dev.sh

# Build and run
./dev.sh run

# Or install
./dev.sh install
```

## Platform-Specific Setup

### Linux

#### Ubuntu/Debian

```bash
# Install dependencies
sudo apt update
sudo apt install -y \
    vulkan-tools \
    libvulkan-dev \
    vulkan-validationlayers \
    liblua5.4-dev

# Install Zig (if not already installed)
# Visit https://ziglang.org/download/ for latest version
```

#### Fedora

```bash
# Install dependencies
sudo dnf install -y \
    vulkan-tools \
    vulkan-loader-devel \
    vulkan-validation-layers \
    lua-devel

# Install Zig from official site
```

#### Arch Linux

```bash
# Install dependencies
sudo pacman -S \
    vulkan-tools \
    vulkan-headers \
    vulkan-validation-layers \
    lua

# Install Zig
sudo pacman -S zig
```

### macOS

```bash
# Install Homebrew if not already installed
# /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install dependencies
brew install molten-vk lua zig

# Set Vulkan environment (add to ~/.zshrc or ~/.bashrc)
export VULKAN_SDK=/usr/local/opt/molten-vk
export VK_ICD_FILENAMES=$VULKAN_SDK/share/vulkan/icd.d/MoltenVK_icd.json
export VK_LAYER_PATH=$VULKAN_SDK/share/vulkan/explicit_layer.d
```

### Windows

1. **Install Zig**:
   - Download from [ziglang.org/download](https://ziglang.org/download/)
   - Extract and add to PATH

2. **Install Vulkan SDK**:
   - Download from [LunarG](https://vulkan.lunarg.com/)
   - Run installer

3. **Install Lua**:
   - Download from [lua.org](https://www.lua.org/download.html)
   - Or use package manager like Chocolatey: `choco install lua`

4. **Build**:
   ```powershell
   git clone https://github.com/AndrewGrayYouNeeK/Death-terminal-.git
   cd Death-terminal-
   zig build run
   ```

## First Run

After installation, run DeathTerminal:

```bash
death-terminal
```

You should see the DeathTerminal banner and initialization messages:

```
 ██████╗ ███████╗ █████╗ ████████╗██╗  ██╗
 ██╔══██╗██╔════╝██╔══██╗╚══██╔══╝██║  ██║
 ██║  ██║█████╗  ███████║   ██║   ███████║
 ██║  ██║██╔══╝  ██╔══██║   ██║   ██╔══██║
 ██████╔╝███████╗██║  ██║   ██║   ██║  ██║
 ╚═════╝ ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝
     ████████╗███████╗██████╗ ███╗   ███╗██╗███╗   ██╗ █████╗ ██╗
     ╚══██╔══╝██╔════╝██╔══██╗████╗ ████║██║████╗  ██║██╔══██╗██║
        ██║   █████╗  ██████╔╝██╔████╔██║██║██╔██╗ ██║███████║██║
        ██║   ██╔══╝  ██╔══██╗██║╚██╔╝██║██║██║╚██╗██║██╔══██║██║
        ██║   ███████╗██║  ██║██║ ╚═╝ ██║██║██║ ╚████║██║  ██║███████╗
        ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝

        Brutalist Terminal Emulator with AI-Powered Autocomplete
```

## Configuration

### Basic Configuration

Create a configuration file:

```bash
# Linux/macOS
mkdir -p ~/.config/death-terminal
cp config.example.lua ~/.config/death-terminal/config.lua

# Windows
# Copy config.example.lua to %APPDATA%/death-terminal/config.lua
```

### Minimal Configuration Example

```lua
-- ~/.config/death-terminal/config.lua

terminal = {
    rows = 24,
    cols = 80,
}

ai = {
    enabled = true,
    endpoint = "localhost:50051",
}

theme = {
    background = "#000000",
    foreground = "#FFFFFF",
    cursor = "#FF0000",
}
```

## Testing the Build

Run the test suite:

```bash
# Run all tests
zig build test

# Verbose output
zig build test --summary all
```

## Common Issues

### "Vulkan not found"

**Linux:**
```bash
# Check Vulkan installation
vulkaninfo
# If not found, install vulkan-tools
```

**macOS:**
```bash
# Ensure MoltenVK is installed
brew list molten-vk
# Set environment variables (see macOS setup above)
```

**Windows:**
- Ensure Vulkan SDK is installed from LunarG
- Restart terminal after installation

### "Lua library not found"

**Linux:**
```bash
# Ubuntu/Debian
sudo apt install liblua5.4-dev

# Fedora
sudo dnf install lua-devel
```

**macOS:**
```bash
brew install lua
```

### Build Errors

```bash
# Clean build artifacts and retry
rm -rf zig-cache zig-out
zig build
```

## Next Steps

1. **Explore Features**: Try different command-line options
   ```bash
   death-terminal --help
   ```

2. **Customize**: Edit your configuration file
   ```bash
   nano ~/.config/death-terminal/config.lua
   ```

3. **Write Lua Scripts**: Create custom commands and automation
   - See `config.example.lua` for examples

4. **Join the Community**:
   - Star the project on GitHub
   - Report issues or request features
   - Contribute improvements

## Getting Help

- 📖 [Full Documentation](README.md)
- 🐛 [Report Issues](https://github.com/AndrewGrayYouNeeK/Death-terminal-/issues)
- 💬 [Discussions](https://github.com/AndrewGrayYouNeeK/Death-terminal-/discussions)
- 🤝 [Contributing Guide](CONTRIBUTING.md)

---

**Welcome to DeathTerminal! 💀**
