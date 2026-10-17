const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("terminal/terminal.zig");
const renderer = @import("renderer/vulkan_renderer.zig");
const shell_inject = @import("app/shell_inject.zig");
const ssh_target = @import("ssh/target.zig");
// libssh2 is only built for Linux (see build.zig addLibssh2).
const ssh_client = if (builtin.os.tag == .linux) @import("ssh/client.zig") else @import("ssh/unsupported.zig");
const ssh_control = @import("ssh/control.zig");
const lua_engine = @import("scripting/lua_engine.zig");
const config = @import("config/config.zig");
const event_loop = @import("app/event_loop.zig");
const plugin_registry = @import("plugins/registry.zig");

const VERSION = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // The built-in SSH client (what a window runs in its PTY for --ssh).
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--ssh-session")) std.process.exit(ssh_client.main(allocator, args));
        if (std.mem.eql(u8, a, "--ssh-ctl")) std.process.exit(sshCtl(args));
    }

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
            try printVersion();
            return;
        }
        if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
            try printHelp();
            return;
        }
    }
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--print-default-config")) {
            try std.io.getStdOut().writeAll(@import("default_config").text);
            return;
        }
    }
    for (args[1..], 1..) |a, i| {
        if (std.mem.eql(u8, a, "--print-shell-integration")) {
            const name = if (i + 1 < args.len) args[i + 1] else "";
            const sh = std.meta.stringToEnum(shell_inject.Shell, name) orelse {
                std.debug.print("usage: deathterminal --print-shell-integration bash|zsh|fish\n", .{});
                std.process.exit(2);
            };
            try std.io.getStdOut().writeAll(shell_inject.script(sh));
            return;
        }
    }

    // `--plugins list|enable|disable`: no window, no banner.
    for (args[1..], 1..) |a, i| {
        if (std.mem.eql(u8, a, "--plugins")) std.process.exit(pluginsCli(allocator, args, args[i + 1 ..]));
    }

    // Print banner only for interactive runs
    try printBanner();

    // Config: defaults, then config.lua (or legacy config.txt), then flags.
    const config_arg = config.configArg(args);
    const load_opts = config.LoadOptions{ .lua_unsafe = hasFlag(args, "--lua-unsafe") };
    var diags = config.Diagnostics.init(allocator);
    defer diags.deinit();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src = config.locate(&path_buf, config_arg);
    var cfg = try config.load(allocator, src, args, load_opts, &diags);
    defer cfg.deinit();
    if (src) |s| std.debug.print("Config: {s}{s}\n", .{ s.path, if (load_opts.lua_unsafe) " (unsafe Lua)" else "" });
    diags.print();
    if (diags.hasErrors()) std.debug.print("config: {d} error(s); using the defaults\n", .{diags.errorCount()});
    var watch_buf: [std.fs.max_path_bytes]u8 = undefined;
    const watch_path: ?[]const u8 = if (src) |s| s.path else config.userConfigPath(&watch_buf);

    std.debug.print("Initializing DeathTerminal...\n", .{});

    // Initialize subsystems
    std.debug.print("[1/5] Initializing Vulkan renderer...\n", .{});
    var vulkan_renderer = try renderer.VulkanRenderer.init(allocator);
    defer vulkan_renderer.deinit();

    std.debug.print("[2/5] Initializing terminal core...\n", .{});
    var shell_arena = std.heap.ArenaAllocator.init(allocator);
    defer shell_arena.deinit();
    // `--ssh <target>`: the window runs the built-in SSH client instead of a shell.
    const ssh_name = sshArg(args);
    var ssh_display: []const u8 = "";
    var ssh_nonce: []const u8 = "";
    const shell_opts = if (ssh_name) |name| blk: {
        const sa = shell_arena.allocator();
        if (builtin.os.tag != .linux) {
            std.debug.print("--ssh: the built-in SSH client is only available on Linux builds for now\n", .{});
            std.process.exit(2);
        }
        if (!cfg.ssh_enabled) {
            std.debug.print("--ssh: the built-in SSH client is disabled (config.ssh.enabled = false)\n", .{});
            std.process.exit(2);
        }
        const t = ssh_target.resolveForConfig(sa, cfg.ssh_profiles.items, cfg.ssh_config_file, cfg.ssh_keepalive_s, name) catch |err| {
            std.debug.print("--ssh: cannot use \"{s}\": {s} (expected a profile from config.ssh.profiles, a ~/.ssh/config Host, or user@host[:port])\n", .{ name, @errorName(err) });
            std.process.exit(2);
        };
        var db: [300]u8 = undefined;
        ssh_display = try sa.dupe(u8, t.display(&db));
        // A per-window secret for the client's connect/disconnect reports
        // (OSC 7799), so remote output can't fake them.
        var nb: [16]u8 = undefined;
        std.crypto.random.bytes(&nb);
        ssh_nonce = try std.fmt.allocPrint(sa, "{s}", .{std.fmt.fmtSliceHexLower(&nb)});
        var env = std.ArrayList([]const u8).init(sa);
        try env.appendSlice(cfg.shell_env.items);
        try env.append(try std.fmt.allocPrint(sa, "DT_SSH_NONCE={s}", .{ssh_nonce}));
        var child_args = std.ArrayList([]const u8).init(sa);
        try child_args.appendSlice(&.{ "--ssh-session", name });
        if (config_arg) |c| try child_args.appendSlice(&.{ "--config", c });
        if (load_opts.lua_unsafe) try child_args.append("--lua-unsafe");
        std.debug.print("  → SSH session: {s} ({s})\n", .{ name, ssh_display });
        break :blk @import("terminal/pty.zig").ShellOptions{
            .program = try std.fs.selfExePathAlloc(sa),
            .args = child_args.items,
            .env = env.items,
            .cwd = cfg.shell_cwd,
        };
    } else shell_inject.apply(shell_arena.allocator(), .{
        .program = cfg.shell_program,
        .args = cfg.shell_args.items,
        .env = cfg.shell_env.items,
        .cwd = cfg.shell_cwd,
    }, cfg.shell_integration);
    var term = try terminal.Terminal.initWithShell(allocator, cfg.rows, cfg.cols, cfg.scrollback_lines, shell_opts);
    defer term.deinit();
    term.setSshNonce(ssh_nonce);

    std.debug.print("[3/5] Initializing Lua scripting engine...\n", .{});
    var lua = try lua_engine.LuaEngine.init(allocator);
    defer lua.deinit();

    if (cfg.ai_enabled) {
        std.debug.print("[4/5] AI suggestions: {s} at {s}\n", .{ cfg.ai_model, cfg.ai_endpoint });
    } else {
        std.debug.print("[4/5] AI suggestions disabled\n", .{});
    }

    std.debug.print("[5/5] SSH: built-in client (libssh2 {s}){s}\n", .{ ssh_client.libssh2Version(), if (cfg.ssh_enabled) "" else " disabled" });

    std.debug.print("\n✓ DeathTerminal initialized successfully\n", .{});

    var loop = event_loop.EventLoop{
        .allocator = allocator,
        .cfg = &cfg,
        .args = args,
        .config_arg = config_arg,
        .load_opts = load_opts,
        .watch_path = watch_path,
        .startup_diags = &diags,
        .ssh_target = ssh_name,
        .ssh_remote = ssh_display,
    };
    try loop.run(&vulkan_renderer, &term, &lua);
}

/// `deathterminal --plugins list|enable <name>|disable <name>`.
fn pluginsCli(allocator: std.mem.Allocator, all_args: []const []const u8, sub: []const []const u8) u8 {
    var diags = config.Diagnostics.init(allocator);
    defer diags.deinit();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src = config.locate(&path_buf, config.configArg(all_args));
    var cfg = config.load(allocator, src, &.{}, .{ .lua_unsafe = hasFlag(all_args, "--lua-unsafe") }, &diags) catch |err| {
        std.debug.print("config: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer cfg.deinit();
    if (diags.hasErrors()) {
        diags.print();
        std.debug.print("config: {d} error(s); showing plugins without config.plugins grants\n\n", .{diags.errorCount()});
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // Only the subcommand and its name (stop at the next flag).
    var n: usize = 0;
    while (n < sub.len and n < 2 and !std.mem.startsWith(u8, sub[n], "--")) n += 1;
    const out = std.io.getStdOut().writer();
    return plugin_registry.cli(arena.allocator(), sub[0..n], cfg.plugins_dir, cfg.plugins.items, cfg.plugins_enabled, out) catch |err| {
        std.debug.print("plugins: {s}\n", .{@errorName(err)});
        return 1;
    };
}

/// `--ssh-ctl <pid> <command…>`: talk to a running SSH session client.
fn sshCtl(args: []const []const u8) u8 {
    var i: usize = 0;
    while (i < args.len and !std.mem.eql(u8, args[i], "--ssh-ctl")) i += 1;
    if (i + 2 >= args.len) {
        std.debug.print("usage: deathterminal --ssh-ctl <pid> status|list|toggle <n>|on <n>|off <n>|add <spec>|reconnect\n", .{});
        return 2;
    }
    const pid = std.fmt.parseInt(std.posix.pid_t, args[i + 1], 10) catch {
        std.debug.print("ssh-ctl: bad pid {s}\n", .{args[i + 1]});
        return 2;
    };
    var cmd_buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buf);
    for (args[i + 2 ..], 0..) |a, k| {
        if (k > 0) fbs.writer().writeByte(' ') catch {};
        fbs.writer().writeAll(a) catch {};
    }
    var out: [8192]u8 = undefined;
    const r = ssh_control.request(pid, fbs.getWritten(), &out) catch |err| {
        std.debug.print("ssh-ctl: no SSH session with pid {d} ({s})\n", .{ pid, @errorName(err) });
        return 1;
    };
    std.io.getStdOut().writeAll(r) catch {};
    return if (std.mem.startsWith(u8, r, "error")) 1 else 0;
}

fn sshArg(args: []const []const u8) ?[]const u8 {
    for (args[1..], 1..) |a, i| {
        if (std.mem.eql(u8, a, "--ssh") and i + 1 < args.len) return args[i + 1];
        if (std.mem.startsWith(u8, a, "--ssh=")) return a["--ssh=".len..];
    }
    return null;
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args[1..]) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

fn printBanner() !void {
    const banner =
        \\
        \\ ██████╗ ███████╗ █████╗ ████████╗██╗  ██╗
        \\ ██╔══██╗██╔════╝██╔══██╗╚══██╔══╝██║  ██║
        \\ ██║  ██║█████╗  ███████║   ██║   ███████║
        \\ ██║  ██║██╔══╝  ██╔══██║   ██║   ██╔══██║
        \\ ██████╔╝███████╗██║  ██║   ██║   ██║  ██║
        \\ ╚═════╝ ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝
        \\     ████████╗███████╗██████╗ ███╗   ███╗██╗███╗   ██╗ █████╗ ██╗
        \\     ╚══██╔══╝██╔════╝██╔══██╗████╗ ████║██║████╗  ██║██╔══██╗██║
        \\        ██║   █████╗  ██████╔╝██╔████╔██║██║██╔██╗ ██║███████║██║
        \\        ██║   ██╔══╝  ██╔══██╗██║╚██╔╝██║██║██║╚██╗██║██╔══██║██║
        \\        ██║   ███████╗██║  ██║██║ ╚═╝ ██║██║██║ ╚████║██║  ██║███████╗
        \\        ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝
        \\
        \\        Brutalist Terminal Emulator with AI-Powered Autocomplete
        \\
    ;
    std.debug.print("{s}\n", .{banner});
}

fn printVersion() !void {
    std.debug.print("DeathTerminal v{s}\n", .{VERSION});
    std.debug.print("Built with Zig {s}\n", .{builtin.zig_version_string});
    std.debug.print("Target: {s}-{s}\n", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
}

fn printHelp() !void {
    const help_text =
        \\DeathTerminal - Brutalist Terminal Emulator
        \\
        \\USAGE:
        \\    deathterminal [OPTIONS]
        \\
        \\OPTIONS:
        \\    -h, --help       Print this help message
        \\    -v, --version    Print version information
        \\    --config <file>  Config file (.lua, or legacy key = value .txt). Default:
        \\                     $XDG_CONFIG_HOME/death-terminal/config.lua (~/.config/...)
        \\    --print-default-config  Print a documented config.lua with every default
        \\    --lua-unsafe     Give config.lua the full Lua library (io, os.execute, require)
        \\    --print-shell-integration <bash|zsh|fish>  Print the OSC 133 shell snippet
        \\    --ssh <target>   Open a window connected over SSH (built-in client). <target> is a
        \\                     config.ssh.profiles name, a ~/.ssh/config Host, or user@host[:port]
        \\    --ssh-session <target> [-L|-R|-D spec]...  Run the SSH client in this terminal
        \\    --ssh-ctl <pid> <cmd>   Control a running session: status, list, toggle <n>,
        \\                     on <n>, off <n>, add <spec>, reconnect
        \\    --plugins list | enable <name> | disable <name>
        \\                     Show installed plugins (and their permissions), or switch
        \\                     one on/off; see docs/PLUGINS.md
        \\    --no-plugins     Start without loading any plugin
        \\    --no-ai          Disable AI command suggestions
        \\    --headless       Run without a GUI window (default)
        \\    --gui            Open a native window (Wayland/X11/Win32; falls back to headless)
        \\    --scale <n>      UI scale 1–4 (default: auto from DPI / compositor / env)
        \\    --backend <name>  Window backend: auto | x11 | wayland | win32
        \\    --font <retro|default>  Font renderer (retro = built-in 8x8 bitmap)
        \\    --font-family <name>    Font family via fontconfig (default: bundled JetBrains Mono)
        \\    --font-size <pt>        Font size in points (default: 11; Ctrl+= / Ctrl+- / Ctrl+0 zoom)
        \\    --line-height <n>       Cell height multiplier (default: 1.0)
        \\
        \\    Command-line flags override config.lua. Saving config.lua (or Ctrl+Shift+R)
        \\    reloads it live; see docs/CONFIG.md.
        \\
        \\FEATURES:
        \\    • AI command suggestions (OpenAI-compatible, local Ollama by default)
        \\    • Built-in SSH (libssh2): profiles, ProxyJump, -L/-R/-D forwards (Ctrl+Shift+S)
        \\    • Vulkan-accelerated rendering
        \\    • Lua plugins: hooks, command palette (Ctrl+Shift+P), status bar, themes
        \\    • Brutalist, high-performance design
        \\
        \\For more information, visit: https://github.com/AndrewGrayYouNeeK/Death-terminal-
        \\
    ;
    std.debug.print("{s}\n", .{help_text});
}

test {
    _ = @import("terminal/terminal.zig");
    _ = @import("terminal/ansi_parser.zig");
    _ = @import("terminal/scrollback.zig");
    _ = @import("terminal/grid_test.zig");
    _ = @import("terminal/unicode.zig");
    _ = @import("terminal/color.zig");
    _ = @import("terminal/pty.zig");
    _ = @import("terminal/input.zig");
    _ = @import("renderer/vulkan_renderer.zig");
    _ = @import("renderer/loader.zig");
    _ = @import("renderer/vulkan_c.zig");
    _ = @import("renderer/pipeline.zig");
    _ = @import("renderer/text_renderer.zig");
    _ = @import("renderer/gpu_present.zig");
    _ = @import("renderer/text_pipeline.zig");
    _ = @import("renderer/software.zig");
    _ = @import("platform/window.zig");
    _ = @import("platform/dpi.zig");
    _ = @import("platform/events.zig");
    _ = @import("font/atlas.zig");
    _ = @import("font/box.zig");
    _ = @import("font/discovery.zig");
    _ = @import("font/face_set.zig");
    _ = @import("font/retro.zig");
    _ = @import("font/fonts.zig");
    _ = @import("renderer/frame.zig");
    _ = @import("terminal/selection.zig");
    _ = @import("terminal/search.zig");
    _ = @import("terminal/urls.zig");
    _ = @import("app/ui.zig");
    _ = @import("app/palette.zig");
    _ = @import("plugins/permissions.zig");
    _ = @import("plugins/value.zig");
    _ = @import("plugins/manifest.zig");
    _ = @import("plugins/jobs.zig");
    _ = @import("plugins/host_test.zig");
    _ = @import("plugins/registry.zig");
    _ = @import("platform/wayland_backend.zig");
    _ = @import("platform/win32_backend.zig");
    _ = @import("app/event_loop.zig");
    _ = @import("app/config_watch.zig");
    _ = @import("config/config.zig");
    _ = @import("config/themes.zig");
    _ = @import("config/lua_config.zig");
    _ = @import("config/lua_config_test.zig");
    _ = @import("scripting/lua.zig");
    _ = @import("net/dial.zig");
    _ = @import("ai/redact.zig");
    _ = @import("ai/openai.zig");
    _ = @import("ai/context.zig");
    _ = @import("ai/engine.zig");
    _ = @import("app/ai_controller.zig");
    _ = @import("app/shell_inject.zig");
    _ = @import("ssh/forward.zig");
    _ = @import("ssh/ssh_config.zig");
    _ = @import("ssh/target.zig");
    _ = @import("ssh/tty.zig");
    _ = @import("ssh/keyfile.zig");
    _ = @import("ssh/known_hosts.zig");
    _ = @import("ssh/bridge.zig");
    _ = @import("ssh/session.zig");
    _ = @import("ssh/control.zig");
    _ = @import("ssh/client.zig");
    _ = @import("scripting/lua_engine.zig");
}

test "basic functionality" {
    const testing = std.testing;
    try testing.expect(true);
}
