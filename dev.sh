#!/usr/bin/env bash
# Quick development script for DeathTerminal

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if Zig is installed
check_zig() {
    if ! command -v zig &> /dev/null; then
        error "Zig is not installed. Please install Zig from https://ziglang.org/download/"
    fi
    info "Zig version: $(zig version)"
}

# Format all Zig source files
format() {
    info "Formatting Zig source files..."
    zig fmt src/**/*.zig build.zig
    info "Formatting complete!"
}

# Build the project
build() {
    info "Building DeathTerminal..."
    local optimize="${1:-Debug}"

    case "$optimize" in
        Debug)
            zig build
            ;;
        ReleaseSafe)
            zig build -Doptimize=ReleaseSafe
            ;;
        ReleaseFast)
            zig build -Doptimize=ReleaseFast
            ;;
        ReleaseSmall)
            zig build -Doptimize=ReleaseSmall
            ;;
        *)
            error "Unknown optimization level: $optimize"
            ;;
    esac

    info "Build complete!"
}

# Run tests
test() {
    info "Running tests..."
    zig build test --summary all
    info "Tests complete!"
}

# Clean build artifacts
clean() {
    info "Cleaning build artifacts..."
    rm -rf zig-cache zig-out .zig-cache
    info "Clean complete!"
}

# Run the application
run() {
    info "Running DeathTerminal..."
    zig build run -- "$@"
}

# Install to system
install() {
    local prefix="${1:-$HOME/.local}"
    info "Installing to $prefix..."
    zig build install --prefix "$prefix"
    info "Installation complete!"
    info "Add $prefix/bin to your PATH if not already present"
}

# Development watch mode (requires entr)
watch() {
    if ! command -v entr &> /dev/null; then
        warn "entr is not installed. Install with: apt install entr / brew install entr"
        warn "Falling back to manual build"
        build
        return
    fi

    info "Watching for changes... (press Ctrl+C to stop)"
    find src -name '*.zig' | entr -c zig build test
}

# Show help
help() {
    cat << EOF
DeathTerminal Development Script

Usage: ./dev.sh <command> [options]

Commands:
    format              Format all Zig source files
    build [mode]        Build the project (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)
    test                Run all tests
    run [args]          Build and run the application with optional arguments
    clean               Remove build artifacts
    install [prefix]    Install to system (default: ~/.local)
    watch               Watch for changes and rebuild (requires entr)
    help                Show this help message

Examples:
    ./dev.sh build              # Debug build
    ./dev.sh build ReleaseFast  # Optimized build
    ./dev.sh run --help         # Run with --help argument
    ./dev.sh install /usr/local # Install to /usr/local

EOF
}

# Main script logic
main() {
    check_zig

    case "${1:-help}" in
        format)
            format
            ;;
        build)
            build "${2:-Debug}"
            ;;
        test)
            test
            ;;
        run)
            shift
            build Debug
            run "$@"
            ;;
        clean)
            clean
            ;;
        install)
            install "$2"
            ;;
        watch)
            watch
            ;;
        help|--help|-h)
            help
            ;;
        *)
            error "Unknown command: $1 (run './dev.sh help' for usage)"
            ;;
    esac
}

main "$@"
