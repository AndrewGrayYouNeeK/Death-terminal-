const std = @import("std");

fn addPlatform(b: *std.Build, step: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    step.linkLibC();
    step.linkSystemLibrary("vulkan");
    if (target.result.os.tag == .linux) {
        step.linkSystemLibrary("X11");
        step.linkSystemLibrary("wayland-client");
        step.linkSystemLibrary("xkbcommon");
        // Fonts: FreeType rasterizer, HarfBuzz shaping, fontconfig lookup.
        step.linkSystemLibrary("freetype2");
        step.linkSystemLibrary("harfbuzz");
        step.linkSystemLibrary("fontconfig");
        step.addIncludePath(b.path("src/platform/wayland"));
        step.addCSourceFile(.{
            .file = b.path("src/platform/wayland/xdg-shell-protocol.c"),
            .flags = &.{ "-std=c99", "-DWL_EXPORT=" },
        });
        step.addCSourceFile(.{
            .file = b.path("src/platform/wayland/primary-selection-protocol.c"),
            .flags = &.{ "-std=c99", "-DWL_EXPORT=" },
        });
        step.addCSourceFile(.{
            .file = b.path("src/platform/wayland/xdg_shim.c"),
            .flags = &.{ "-std=c99", "-DWL_EXPORT=" },
        });
    } else if (target.result.os.tag == .windows) {
        step.linkSystemLibrary("user32");
        step.linkSystemLibrary("gdi32");
    }
}

/// Bundled default font (JetBrains Mono, SIL OFL 1.1), embedded with
/// `@embedFile("jbm_regular")` etc.
fn addFonts(b: *std.Build, step: *std.Build.Step.Compile) void {
    const files = [_][2][]const u8{
        .{ "jbm_regular", "assets/fonts/JetBrainsMono/JetBrainsMono-Regular.ttf" },
        .{ "jbm_bold", "assets/fonts/JetBrainsMono/JetBrainsMono-Bold.ttf" },
        .{ "jbm_italic", "assets/fonts/JetBrainsMono/JetBrainsMono-Italic.ttf" },
        .{ "jbm_bold_italic", "assets/fonts/JetBrainsMono/JetBrainsMono-BoldItalic.ttf" },
    };
    for (files) |f| step.root_module.addAnonymousImport(f[0], .{ .root_source_file = b.path(f[1]) });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "deathterminal",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addPlatform(b, exe, target);
    addFonts(b, exe);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addPlatform(b, unit_tests, target);
    addFonts(b, unit_tests);

    // `zig build bench`: throughput benchmark, always optimised.
    const bench_exe = b.addExecutable(.{
        .name = "deathterminal-bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseFast else optimize,
    });
    addPlatform(b, bench_exe, target);
    addFonts(b, bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the throughput benchmark (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    const test_step = b.step("test", "Run unit tests");
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}
