# Contributing to YouNeeK Death Terminal

First off, thank you for considering contributing to YouNeeK Death Terminal! It's people like you that make YouNeeK Death Terminal such a great tool.

## Code of Conduct

This project and everyone participating in it is governed by respect and professionalism. Please be kind and constructive in all interactions.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check the existing issues to avoid duplicates. When creating a bug report, include as many details as possible:

- **Use a clear and descriptive title**
- **Describe the exact steps to reproduce the problem**
- **Provide specific examples** (commands, configurations, etc.)
- **Describe the behavior you observed** and what you expected
- **Include screenshots** if applicable
- **Provide system information**: OS, Zig version, Vulkan driver version

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion:

- **Use a clear and descriptive title**
- **Provide a detailed description** of the suggested enhancement
- **Explain why this enhancement would be useful**
- **Provide examples** of how the feature would be used
- **Consider the scope**: Should it be a core feature or a Lua plugin?

### Pull Requests

1. **Fork the repository** and create your branch from `main`
2. **Follow the coding standards** (see below)
3. **Add tests** for new functionality
4. **Update documentation** if needed
5. **Ensure tests pass**: `zig build test`
6. **Format your code**: `zig fmt src/**/*.zig`
7. **Write a clear commit message** (see below)

## Development Setup

### Prerequisites

See the main README for installation requirements:
- Zig 0.13.0+
- Vulkan SDK
- Lua 5.4

### Building

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/Death-terminal-.git
cd Death-terminal-

# Build the project
zig build

# Run tests
zig build test

# Run the terminal
zig build run
```

## Coding Standards

### Zig Style Guide

We follow the standard Zig formatting and conventions:

```bash
# Format all Zig files
zig fmt src/**/*.zig build.zig
```

**Key principles:**
- Use `snake_case` for functions and variables
- Use `PascalCase` for types and structs
- Keep functions small and focused (< 50 lines when possible)
- Write self-documenting code with clear variable names
- Add comments for complex logic, not obvious code
- Use `const` over `var` whenever possible

### Code Organization

```
src/
├── main.zig              # Entry point, CLI parsing, initialization
├── renderer/             # Vulkan rendering subsystem
├── terminal/             # Terminal emulation, PTY handling
├── ai/                   # AI suggestions: OpenAI-compatible HTTP/JSON client, redaction, worker
├── ssh/                  # Built-in SSH client (libssh2), ~/.ssh/config, forwards
├── plugins/              # Plugin host: sandbox.lua, permissions, hooks, registry/CLI, jobs
├── app/                  # Event loop, GUI (gui.zig), tabs/panes (session.zig), UI overlays, plugin bridge
└── scripting/            # Lua engine and API bindings
```

Example plugins live in the top-level `plugins/` directory; a test loads all of them
(`src/plugins/host_test.zig`), so keep them working when the API changes.

**Guidelines:**
- Each module should be self-contained
- Minimize dependencies between modules
- Use clear interfaces (public functions)
- Keep platform-specific code isolated
- Write tests alongside implementation

### Error Handling

```zig
// Use Zig's error union pattern
pub fn doSomething() !void {
    // Use try for propagating errors
    try riskyOperation();

    // Use catch for handling errors
    const result = riskyOperation() catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    };
}

// Define custom error sets
const MyError = error{
    InvalidInput,
    ConnectionFailed,
};
```

### Testing

```zig
test "feature works correctly" {
    const testing = std.testing;

    // Setup
    var thing = try Thing.init(testing.allocator);
    defer thing.deinit();

    // Test
    try thing.doSomething();

    // Assertions
    try testing.expectEqual(expected, actual);
    try testing.expect(condition);
}
```

**Test guidelines:**
- Write tests for all public APIs
- Test edge cases and error conditions
- Use descriptive test names
- Keep tests focused and independent
- Clean up resources with `defer`

## Commit Message Guidelines

We follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, etc.)
- `refactor`: Code refactoring
- `perf`: Performance improvements
- `test`: Adding or updating tests
- `chore`: Build process, tooling, dependencies

**Examples:**

```
feat(renderer): add glyph atlas caching

Implement a GPU-resident glyph atlas that caches rendered characters
for improved text rendering performance.

Closes #42
```

```
fix(terminal): correct ANSI color parsing

Fixed issue where 256-color ANSI sequences were not being parsed
correctly, causing incorrect colors in some TUI applications.

Fixes #73
```

```
docs(readme): add macOS build instructions

Added detailed instructions for building on macOS including
MoltenVK setup and common troubleshooting steps.
```

## Module-Specific Guidelines

### Vulkan Renderer (`src/renderer/`)

- Keep rendering code isolated from business logic
- Optimize for performance (minimize GPU state changes)
- Handle window resize gracefully
- Support high-DPI displays
- Profile with RenderDoc when making changes

### Terminal Core (`src/terminal/`)

- Follow VT100/ANSI escape sequence standards
- Test with real terminal applications (vim, htop, etc.)
- Handle edge cases in escape sequence parsing
- Ensure cross-platform PTY compatibility

### AI Autocomplete (`src/ai/`)

- Requests are OpenAI-compatible HTTP/JSON (no gRPC) and run on the worker thread; never block the UI thread
- Handle network failures gracefully (status badge, no dialogs)
- Everything sent goes through `redact.zig`; add a test there for every new secret pattern
- Test against `src/ai/mock_server.zig`, not a real endpoint
- Make AI features opt-in and configurable
- Respect user privacy

### SSH (`src/ssh/`)

- libssh2 1.11.1 is vendored (`vendor/libssh2-1.11.1`); `src/ssh/libssh2_extra.c` holds the
  few helpers that need its private headers. Don't patch the vendored sources
- Never log credentials or keys; read secrets with `Tty.readLine(.., echo=false, ..)` into
  fixed buffers and `secureZero` them
- Validate host keys; known_hosts is only ever appended to
- Pure logic (ssh_config, targets, forwards, SOCKS) gets unit tests; anything that talks to a
  server goes in `tests/ssh/run.py`, run with `zig build test-ssh` (needs openssh-server,
  passwordless sudo and python3; it starts throwaway sshd instances on 127.0.0.1:2222-2234)

### Lua Scripting (`src/scripting/`)

- Expose clean, minimal APIs
- Document all Lua-visible functions
- Handle Lua errors gracefully
- Sandbox potentially dangerous operations
- Provide good error messages for users

## Documentation

### Code Documentation

```zig
/// Brief description of the function
///
/// Detailed explanation of what the function does,
/// its parameters, return values, and any side effects.
///
/// Examples:
/// ```
/// const result = try myFunction(allocator, 42);
/// ```
pub fn myFunction(allocator: std.mem.Allocator, value: i32) !ReturnType {
    // Implementation
}
```

### README and Wiki

- Keep README concise and up-to-date
- Use Wiki for in-depth documentation
- Include examples and screenshots
- Document common issues and solutions

## Performance Considerations

YouNeeK Death Terminal is designed to be brutally fast:

- **Profile before optimizing** - Use `perf`, `Instruments`, or `VTune`
- **Minimize allocations** - Reuse buffers, use arenas where appropriate
- **Batch GPU operations** - Update textures and buffers in batches
- **Optimize hot paths** - Terminal output processing, text rendering
- **Consider cache locality** - Structure data for sequential access

## Security Considerations

YouNeeK Death Terminal handles sensitive data:

- **Never log credentials** - SSH keys, passwords, tokens
- **Validate all input** - Escape sequences, SSH data, user input
- **Sanitize AI context** - Don't send sensitive data to AI services
- **Use secure defaults** - Verify SSH host keys, use strong crypto
- **Keep dependencies updated** - Regularly update Vulkan, SSH, Lua libraries

## Release Process

Maintainers handle releases, but contributors should:

1. Test on all supported platforms before major changes
2. Update CHANGELOG.md with notable changes
3. Bump version in `src/main.zig` if doing release
4. Tag releases following [Semantic Versioning](https://semver.org/)

## Questions?

Feel free to:
- Open a GitHub Discussion for questions
- Join our community chat (if available)
- Ask in your pull request
- Email the maintainers

## License

By contributing to YouNeeK Death Terminal, you agree that your contributions will be licensed under the MIT License.

---

**Thank you for contributing to YouNeeK Death Terminal! 💀**
