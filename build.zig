const std = @import("std");

fn addPlatform(b: *std.Build, step: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    step.linkLibC();
    step.linkSystemLibrary("vulkan");
    if (target.result.os.tag == .linux) {
        step.linkSystemLibrary("X11");
        step.linkSystemLibrary("wayland-client");
        step.linkSystemLibrary("xkbcommon");
        step.addIncludePath(b.path("src/platform/wayland"));
        step.addCSourceFile(.{
            .file = b.path("src/platform/wayland/xdg-shell-protocol.c"),
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

    const test_step = b.step("test", "Run unit tests");
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}
