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

/// Vendored Lua 5.4 (vendor/lua-5.4.7), compiled into the binary so there is
/// no system Lua dependency. lua.c/luac.c (the standalone tools) are not
/// vendored.
fn addLua(b: *std.Build, step: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const srcs = [_][]const u8{
        "lapi.c",     "lcode.c",    "lctype.c",   "ldebug.c",  "ldo.c",      "ldump.c",   "lfunc.c",
        "lgc.c",      "llex.c",     "lmem.c",     "lobject.c", "lopcodes.c", "lparser.c", "lstate.c",
        "lstring.c",  "ltable.c",   "ltm.c",      "lundump.c", "lvm.c",      "lzio.c",    "lauxlib.c",
        "lbaselib.c", "lcorolib.c", "ldblib.c",   "liolib.c",  "lmathlib.c", "loadlib.c", "loslib.c",
        "lstrlib.c",  "ltablib.c",  "lutf8lib.c", "linit.c",
    };
    const posix = target.result.os.tag == .linux or target.result.os.tag == .macos;
    const flags: []const []const u8 = if (posix)
        &.{ "-std=gnu99", "-DLUA_USE_POSIX", "-fno-sanitize=undefined" }
    else
        &.{ "-std=gnu99", "-fno-sanitize=undefined" };
    step.addIncludePath(b.path("vendor/lua-5.4.7/src"));
    step.addCSourceFiles(.{ .root = b.path("vendor/lua-5.4.7/src"), .files = &srcs, .flags = flags });
}

/// The documented default config, printed by --print-default-config.
fn addDefaultConfig(b: *std.Build, step: *std.Build.Step.Compile) void {
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path("config.example.lua"), "config.example.lua");
    const mod = wf.add("default_config.zig", "pub const text = @embedFile(\"config.example.lua\");\n");
    step.root_module.addAnonymousImport("default_config", .{ .root_source_file = mod });
}

/// Shell integration snippets (shell-integration/*), printed by
/// --print-shell-integration and injected into bash/zsh/fish.
fn addShellIntegration(b: *std.Build, step: *std.Build.Step.Compile) void {
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path("shell-integration/bash.sh"), "bash.sh");
    _ = wf.addCopyFile(b.path("shell-integration/zsh.zsh"), "zsh.zsh");
    _ = wf.addCopyFile(b.path("shell-integration/fish.fish"), "fish.fish");
    const mod = wf.add("shell_scripts.zig",
        \\pub const bash = @embedFile("bash.sh");
        \\pub const zsh = @embedFile("zsh.zsh");
        \\pub const fish = @embedFile("fish.fish");
        \\
    );
    step.root_module.addAnonymousImport("shell_scripts", .{ .root_source_file = mod });
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
    addLua(b, exe, target);
    addDefaultConfig(b, exe);
    addShellIntegration(b, exe);

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
    addLua(b, unit_tests, target);
    addDefaultConfig(b, unit_tests);
    addShellIntegration(b, unit_tests);

    // `zig build bench`: throughput benchmark, always optimised.
    const bench_exe = b.addExecutable(.{
        .name = "deathterminal-bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseFast else optimize,
    });
    addPlatform(b, bench_exe, target);
    addFonts(b, bench_exe);
    addLua(b, bench_exe, target);
    addDefaultConfig(b, bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the throughput benchmark (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    const test_step = b.step("test", "Run unit tests");
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}
