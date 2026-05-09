# Changelog

All notable changes to DeathTerminal will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial project structure and build system
- build.zig.zon for dependency management
- Modular architecture with core subsystems:
  - **Terminal emulator core** - Fully functional PTY + ANSI/VT100 parser (Phase 1 complete)
  - **Vulkan renderer module** - Complete structural foundation for GPU rendering (Phase 2 in progress)
    - Vulkan instance and device management
    - Swapchain for presentation
    - Graphics pipeline infrastructure
    - Glyph atlas system for text rendering
    - Text rendering pipeline with vertex generation
  - AI autocomplete via gRPC stub
  - SSH tunneling module stub
  - Lua scripting engine stub
- Terminal Core (Phase 1):
  - PTY (pseudo-terminal) creation and management
  - Process spawning with shell integration
  - Complete ANSI/VT100 escape sequence parser
  - Terminal buffer management with cell-based rendering
  - Input/output handling
  - Cursor movement and control
  - Cross-platform PTY compatibility (Unix/Linux/macOS support)
  - Color support (16-color ANSI palette)
  - Text attributes (bold, italic, underline)
  - Screen manipulation (scroll, clear, erase)
- Comprehensive README with build instructions
- Example Lua configuration file
- Contributing guidelines with Conventional Commits
- MIT License
- Project checklist (ISSUES.md) tracking implementation progress

### Changed
- Updated build.zig to link against system Vulkan library
- Enhanced ISSUES.md with detailed Phase 2 progress tracking

### Deprecated
- N/A

### Removed
- N/A

### Fixed
- N/A

### Security
- N/A

## [0.1.0] - TBD

### Added
- Initial alpha release
- Basic terminal emulation
- Vulkan-accelerated rendering
- Cross-platform support (Linux, macOS, Windows)

---

**Legend:**
- `Added` for new features
- `Changed` for changes in existing functionality
- `Deprecated` for soon-to-be removed features
- `Removed` for now removed features
- `Fixed` for any bug fixes
- `Security` in case of vulnerabilities
