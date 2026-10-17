const std = @import("std");

fn addPlatform(b: *std.Build, step: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    step.linkLibC();
    // Vulkan is loaded at run time (vulkan-1.dll / libvulkan.so.1 /
    // libvulkan.1.dylib, see renderer/loader.zig); only the headers are
    // needed to build, and they're vendored so cross builds work.
    step.addIncludePath(b.path("vendor/vulkan-headers/include"));
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
        step.linkSystemLibrary("shell32");
        step.linkSystemLibrary("ws2_32");
        addFontLibs(b, step, target);
    } else if (target.result.os.tag == .macos) {
        // AppKit / QuartzCore / Metal are opened at run time (dlopen), so
        // cross builds need no macOS SDK; only libSystem is linked.
        addFontLibs(b, step, target);
    }
}

/// FreeType 2.13.3 + HarfBuzz 10.1.0 built from source (Windows, macOS).
/// Lazy dependencies: fetched on the first build for these targets.
fn addFontLibs(b: *std.Build, step: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    _ = target;
    const ft = b.lazyDependency("freetype", .{}) orelse return;
    const hb = b.lazyDependency("harfbuzz", .{}) orelse return;
    const ft_srcs = [_][]const u8{
        "src/autofit/autofit.c", "src/base/ftbase.c",     "src/base/ftbbox.c",     "src/base/ftbdf.c",
        "src/base/ftbitmap.c",   "src/base/ftcid.c",      "src/base/ftfstype.c",   "src/base/ftgasp.c",
        "src/base/ftglyph.c",    "src/base/ftgxval.c",    "src/base/ftinit.c",     "src/base/ftmm.c",
        "src/base/ftotval.c",    "src/base/ftpatent.c",   "src/base/ftpfr.c",      "src/base/ftstroke.c",
        "src/base/ftsynth.c",    "src/base/fttype1.c",    "src/base/ftwinfnt.c",   "src/base/ftsystem.c",
        "src/base/ftdebug.c",    "src/bdf/bdf.c",         "src/cache/ftcache.c",   "src/cff/cff.c",
        "src/cid/type1cid.c",    "src/gzip/ftgzip.c",     "src/lzw/ftlzw.c",       "src/pcf/pcf.c",
        "src/pfr/pfr.c",         "src/psaux/psaux.c",     "src/pshinter/pshinter.c", "src/psnames/psnames.c",
        "src/raster/raster.c",   "src/sdf/sdf.c",         "src/sfnt/sfnt.c",       "src/smooth/smooth.c",
        "src/svg/svg.c",         "src/truetype/truetype.c", "src/type1/type1.c",   "src/type42/type42.c",
        "src/winfonts/winfnt.c",
    };
    step.addIncludePath(ft.path("include"));
    step.addCSourceFiles(.{
        .root = ft.path(""),
        .files = &ft_srcs,
        .flags = &.{ "-std=c99", "-DFT2_BUILD_LIBRARY", "-fno-sanitize=undefined" },
    });
    step.addIncludePath(hb.path("src"));
    step.addCSourceFile(.{
        .file = hb.path("src/harfbuzz.cc"),
        .flags = &.{ "-std=c++11", "-DHAVE_FREETYPE=1", "-fno-exceptions", "-fno-rtti", "-fno-sanitize=undefined", "-DHB_NO_MT" },
    });
    step.linkLibCpp();
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

/// Vendored libssh2 1.11.1 (vendor/libssh2-1.11.1) with the OpenSSL
/// backend: compiled here, linked against the system libcrypto.
fn addLibssh2(b: *std.Build, step: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .linux) return;
    const srcs = [_][]const u8{
        "agent.c",  "bcrypt_pbkdf.c", "channel.c",  "comp.c",                "chacha.c",    "cipher-chachapoly.c", "crypt.c",
        "crypto.c", "global.c",       "hostkey.c",  "keepalive.c",           "kex.c",       "knownhost.c",         "mac.c",
        "misc.c",   "packet.c",       "pem.c",      "poly1305.c",            "publickey.c", "scp.c",               "session.c",
        "sftp.c",   "transport.c",    "userauth.c", "userauth_kbd_packet.c", "version.c",   "openssl.c",
    };
    step.addIncludePath(b.path("vendor/libssh2-1.11.1/include"));
    step.addCSourceFiles(.{
        .root = b.path("vendor/libssh2-1.11.1/src"),
        .files = &srcs,
        .flags = &.{ "-std=gnu99", "-DHAVE_CONFIG_H", "-DLIBSSH2_OPENSSL", "-fno-sanitize=undefined" },
    });
    // Keepalive-reply bookkeeping that needs libssh2's private headers.
    step.addIncludePath(b.path("vendor/libssh2-1.11.1/src"));
    step.addCSourceFile(.{
        .file = b.path("src/ssh/libssh2_extra.c"),
        .flags = &.{ "-std=gnu99", "-DHAVE_CONFIG_H", "-DLIBSSH2_OPENSSL", "-fno-sanitize=undefined" },
    });
    step.linkSystemLibrary("crypto");
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

/// The release version (keep build.zig.zon in sync). `-Dversion=` can
/// override it, e.g. for snapshot builds.
const default_version = "0.1.0";

fn addVersion(b: *std.Build, step: *std.Build.Step.Compile, version: []const u8) void {
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    step.root_module.addOptions("build_options", opts);
}

/// Everything the app executable needs, for a given target/optimisation.
fn addApp(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, version: []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "deathterminal",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addPlatform(b, exe, target);
    addFonts(b, exe);
    addLua(b, exe, target);
    addLibssh2(b, exe, target);
    addDefaultConfig(b, exe);
    addShellIntegration(b, exe);
    addVersion(b, exe, version);
    if (target.result.os.tag == .windows) {
        // Icon + version info (packaging/windows/deathterminal.rc).
        exe.addWin32ResourceFile(.{ .file = b.path("packaging/windows/deathterminal.rc") });
        // GUI binary without a console window would hide headless mode;
        // keep the console subsystem (Windows Terminal friendly).
    }
    return exe;
}

/// `zig build release`: ReleaseFast build staged as
/// zig-out/release/deathterminal-<version>-<arch>-<os>/ plus a .tar.gz
/// (.zip for Windows) and SHA256SUMS. `-Dpackages` also builds the Linux
/// AppImage/.deb/.rpm (packaging/linux/build-packages.sh).
fn addRelease(b: *std.Build, target: std.Build.ResolvedTarget, version: []const u8) void {
    const t = target.result;
    const os_name = switch (t.os.tag) {
        .macos => "macos",
        .windows => "windows",
        else => @tagName(t.os.tag),
    };
    const name = b.fmt("deathterminal-{s}-{s}-{s}", .{ version, @tagName(t.cpu.arch), os_name });
    const stage = b.fmt("release/{s}", .{name});
    const step = b.step("release", "Versioned release archive in zig-out/release (ReleaseFast)");

    const exe = addApp(b, target, .ReleaseFast, version);
    exe.root_module.strip = true;
    const bin_dir = if (t.os.tag == .windows) stage else b.fmt("{s}/bin", .{stage});
    const inst = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = bin_dir } },
        .pdb_dir = .disabled,
    });

    var files = std.ArrayList(*std.Build.Step).init(b.allocator);
    files.append(&inst.step) catch @panic("OOM");
    const doc_dir = if (t.os.tag == .windows) stage else b.fmt("{s}/share/doc/deathterminal", .{stage});
    for ([_][]const u8{ "README.md", "LICENSE", "CHANGELOG.md", "config.example.lua" }) |f| {
        files.append(&b.addInstallFileWithDir(b.path(f), .{ .custom = doc_dir }, f).step) catch @panic("OOM");
    }
    files.append(&b.addInstallDirectory(.{
        .source_dir = b.path("docs"),
        .install_dir = .{ .custom = doc_dir },
        .install_subdir = "docs",
    }).step) catch @panic("OOM");
    files.append(&b.addInstallDirectory(.{
        .source_dir = b.path("plugins"),
        .install_dir = .{ .custom = doc_dir },
        .install_subdir = "examples/plugins",
    }).step) catch @panic("OOM");
    if (t.os.tag != .windows) {
        files.append(&b.addInstallFileWithDir(b.path("packaging/linux/deathterminal.1"), .{ .custom = b.fmt("{s}/share/man/man1", .{stage}) }, "deathterminal.1").step) catch @panic("OOM");
    }
    if (t.os.tag == .linux) {
        files.append(&b.addInstallFileWithDir(b.path("packaging/linux/deathterminal.desktop"), .{ .custom = b.fmt("{s}/share/applications", .{stage}) }, "deathterminal.desktop").step) catch @panic("OOM");
        files.append(&b.addInstallFileWithDir(b.path("packaging/icons/deathterminal.svg"), .{ .custom = b.fmt("{s}/share/icons/hicolor/scalable/apps", .{stage}) }, "deathterminal.svg").step) catch @panic("OOM");
        for ([_][]const u8{ "16", "32", "48", "64", "128", "256", "512" }) |px| {
            files.append(&b.addInstallFileWithDir(
                b.path(b.fmt("packaging/icons/png/deathterminal-{s}.png", .{px})),
                .{ .custom = b.fmt("{s}/share/icons/hicolor/{s}x{s}/apps", .{ stage, px, px }) },
                "deathterminal.png",
            ).step) catch @panic("OOM");
        }
    }

    const archive = b.addSystemCommand(&.{ "python3", "packaging/archive.py" });
    archive.addArg(b.getInstallPath(.prefix, "release"));
    archive.addArg(name);
    archive.addArg(if (t.os.tag == .windows) "zip" else "gztar");
    archive.has_side_effects = true;
    for (files.items) |s| archive.step.dependOn(s);
    step.dependOn(&archive.step);

    const packages = b.option(bool, "packages", "With `release` on Linux: also build AppImage, .deb and .rpm") orelse false;
    if (packages and t.os.tag == .linux) {
        const pkg = b.addSystemCommand(&.{ "bash", "packaging/linux/build-packages.sh" });
        pkg.addArg(version);
        pkg.addArg(b.getInstallPath(.prefix, stage));
        pkg.addArg(b.getInstallPath(.prefix, "release"));
        pkg.has_side_effects = true;
        pkg.step.dependOn(&archive.step);
        step.dependOn(&pkg.step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version string (default " ++ default_version ++ ")") orelse default_version;

    const exe = addApp(b, target, optimize, version);
    b.installArtifact(exe);
    addRelease(b, target, version);

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
    addLibssh2(b, unit_tests, target);
    addDefaultConfig(b, unit_tests);
    addShellIntegration(b, unit_tests);
    addVersion(b, unit_tests, version);

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
    addVersion(b, bench_exe, version);
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the throughput benchmark (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    const test_step = b.step("test", "Run unit tests");
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // `zig build test-ssh`: integration tests against a throwaway local
    // sshd (needs openssh-server and passwordless sudo; see tests/ssh).
    const ssh_tests = b.addSystemCommand(&.{ "python3", "tests/ssh/run.py" });
    ssh_tests.addArtifactArg(exe);
    ssh_tests.has_side_effects = true;
    const ssh_step = b.step("test-ssh", "SSH integration tests (local sshd, needs sudo)");
    ssh_step.dependOn(&ssh_tests.step);
}
