//! `config.plugins.<name> = { ... }`: what the user grants a plugin.

const std = @import("std");
const permissions = @import("permissions.zig");
const value = @import("value.zig");

pub const PluginConfig = struct {
    name: []const u8,
    /// null = not set in config.lua (the plugins state file / default decides).
    enabled: ?bool = null,
    /// Granted permissions (only those the manifest also requests apply).
    allow: permissions.Set = permissions.Set.initEmpty(),
    /// Programs `dt.exec` may run (with the `exec` permission): bare names
    /// looked up in $PATH, or absolute paths.
    exec: []const []const u8 = &.{},
    /// Hosts `dt.http` may reach (with `network`): "api.example.com",
    /// "*.example.com", optionally with ":port".
    hosts: []const []const u8 = &.{},
    /// Memory cap for the plugin's Lua state.
    memory_mb: u16 = 32,
    /// Time budget per callback (load gets 10x).
    cpu_ms: u16 = 100,
    /// Plain data handed to the plugin as `dt.settings`.
    settings: ?value.Value = null,

    pub const fields = "enabled, allow, exec, hosts, memory_mb, cpu_ms, settings";

    pub fn hash(self: *const PluginConfig, h: *std.hash.Wyhash) void {
        h.update(self.name);
        h.update(if (self.enabled) |e| (if (e) "1" else "0") else "-");
        h.update(std.mem.asBytes(&self.allow.bits.mask));
        for (self.exec) |e| h.update(e);
        h.update("|");
        for (self.hosts) |e| h.update(e);
        h.update(std.mem.asBytes(&self.memory_mb));
        h.update(std.mem.asBytes(&self.cpu_ms));
        if (self.settings) |s| value.hash(h, s);
    }
};

pub fn find(list: []const PluginConfig, name: []const u8) ?*const PluginConfig {
    for (list) |*p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}
