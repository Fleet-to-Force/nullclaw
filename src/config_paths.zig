const std = @import("std");
const platform = @import("platform.zig");

pub fn defaultConfigDirFromInputs(
    allocator: std.mem.Allocator,
    nullclaw_home: ?[]const u8,
    home_dir: ?[]const u8,
) ![]u8 {
    if (nullclaw_home) |config_dir| return allocator.dupe(u8, config_dir);
    const home = home_dir orelse return error.HomeDirNotFound;
    return std.fs.path.join(allocator, &.{ home, ".nullclaw" });
}

pub fn defaultConfigDir(allocator: std.mem.Allocator) ![]u8 {
    const nullclaw_home = std.process.getEnvVarOwned(allocator, "NULLCLAW_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (nullclaw_home) |config_dir| return config_dir;

    const home_dir = try platform.getHomeDir(allocator);
    defer allocator.free(home_dir);
    return defaultConfigDirFromInputs(allocator, null, home_dir);
}

pub fn pathFromConfigDir(
    allocator: std.mem.Allocator,
    config_dir: []const u8,
    leaf_name: []const u8,
) ![]u8 {
    return std.fs.path.join(allocator, &.{ config_dir, leaf_name });
}

test "defaultConfigDirFromInputs prefers NULLCLAW_HOME override" {
    const config_dir = try defaultConfigDirFromInputs(std.testing.allocator, "/tmp/nullclaw-home", "/home/ignored");
    defer std.testing.allocator.free(config_dir);

    try std.testing.expectEqualStrings("/tmp/nullclaw-home", config_dir);
}

test "defaultConfigDirFromInputs falls back to HOME/.nullclaw" {
    const config_dir = try defaultConfigDirFromInputs(std.testing.allocator, null, "/home/alice");
    defer std.testing.allocator.free(config_dir);

    const expected = try std.fs.path.join(std.testing.allocator, &.{ "/home/alice", ".nullclaw" });
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, config_dir);
}

test "defaultConfigDirFromInputs reports missing home" {
    try std.testing.expectError(error.HomeDirNotFound, defaultConfigDirFromInputs(std.testing.allocator, null, null));
}

test "pathFromConfigDir appends a leaf name" {
    const path = try pathFromConfigDir(std.testing.allocator, "/tmp/nullclaw-home", "config.json");
    defer std.testing.allocator.free(path);

    const expected = try std.fs.path.join(std.testing.allocator, &.{ "/tmp/nullclaw-home", "config.json" });
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, path);
}
