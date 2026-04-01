//! Agent subprocess runner — spawns `nullclaw agent -m "<prompt>"` as a child
//! process with timeout, output capture, and platform-specific exec fallbacks.
//!
//! Extracted from cron.zig so that any subsystem (cron, heartbeat, etc.) can
//! spawn agent jobs without depending on the scheduler.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.agent_runner);

pub const AgentRunResult = struct {
    success: bool,
    output: []const u8,
};

pub const MAX_OUTPUT_BYTES: usize = 1_048_576;
const POLL_STEP_NS: u64 = 200 * std.time.ns_per_ms;
const LINUX_SELF_EXE_PATH = "/proc/self/exe";
const DELETED_EXE_SUFFIX = " (deleted)";

fn pathAgentExecutableName() []const u8 {
    return if (comptime builtin.os.tag == .windows) "nullclaw.exe" else "nullclaw";
}

fn hasTimeoutExpired(start_ns: i128, timeout_secs: u64) bool {
    if (timeout_secs == 0) return false;
    const timeout_ns = @as(i128, @intCast(timeout_secs)) * std.time.ns_per_s;
    const now_ns = std.time.nanoTimestamp();
    return now_ns - start_ns >= timeout_ns;
}

fn collectChildOutputWithTimeout(
    child: *std.process.Child,
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    timeout_secs: u64,
    start_ns: i128,
) !bool {
    var poller = std.Io.poll(allocator, enum { stdout, stderr }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    const stdout_r = poller.reader(.stdout);
    stdout_r.buffer = stdout.allocatedSlice();
    stdout_r.seek = 0;
    stdout_r.end = stdout.items.len;

    const stderr_r = poller.reader(.stderr);
    stderr_r.buffer = stderr.allocatedSlice();
    stderr_r.seek = 0;
    stderr_r.end = stderr.items.len;

    defer {
        stdout.* = .{
            .items = stdout_r.buffer[0..stdout_r.end],
            .capacity = stdout_r.buffer.len,
        };
        stderr.* = .{
            .items = stderr_r.buffer[0..stderr_r.end],
            .capacity = stderr_r.buffer.len,
        };
        stdout_r.buffer = &.{};
        stderr_r.buffer = &.{};
    }

    var timed_out = false;
    while (true) {
        const keep_polling = if (timeout_secs == 0 or timed_out)
            try poller.poll()
        else
            try poller.pollTimeout(POLL_STEP_NS);

        if (stdout_r.bufferedLen() > MAX_OUTPUT_BYTES) return error.StdoutStreamTooLong;
        if (stderr_r.bufferedLen() > MAX_OUTPUT_BYTES) return error.StderrStreamTooLong;

        if (!keep_polling) break;

        if (!timed_out and hasTimeoutExpired(start_ns, timeout_secs)) {
            try terminateChildHard(child);
            timed_out = true;
        }
    }

    return timed_out;
}

fn terminateChildHard(child: *std.process.Child) !void {
    if (comptime builtin.os.tag == .windows) {
        _ = child.killWindows(1) catch |err| switch (err) {
            error.AlreadyTerminated => return,
            else => return err,
        };
        return;
    }
    if (comptime builtin.os.tag == .wasi) return error.UnsupportedOperation;

    std.posix.kill(child.id, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => return,
        else => return err,
    };
}

fn buildAgentOutput(
    allocator: std.mem.Allocator,
    stdout: []const u8,
    stderr: []const u8,
    timeout_secs: u64,
    timed_out: bool,
) ![]const u8 {
    if (timed_out) {
        const source = if (stdout.len > 0) stdout else stderr;
        if (source.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}\n\n[agent timed out after {d}s]", .{ source, timeout_secs });
        }
        return std.fmt.allocPrint(allocator, "agent timed out after {d}s", .{timeout_secs});
    }

    const output_source = if (stdout.len > 0) stdout else if (stderr.len > 0) stderr else "";
    return allocator.dupe(u8, output_source);
}

fn preferExecPath(self_exe_path: []const u8) []const u8 {
    if (comptime builtin.os.tag == .linux) {
        if (std.mem.endsWith(u8, self_exe_path, DELETED_EXE_SUFFIX)) {
            return LINUX_SELF_EXE_PATH;
        }
    }
    return self_exe_path;
}

pub fn run(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    prompt: []const u8,
    model: ?[]const u8,
    timeout_secs: u64,
) !AgentRunResult {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    var exec_path = preferExecPath(exe_path);
    var exec_cwd = cwd;
    var tried_no_cwd = false;
    var tried_proc_self_exe = std.mem.eql(u8, exec_path, LINUX_SELF_EXE_PATH);
    var tried_path_exec = false;

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    var child: std.process.Child = undefined;
    spawn_loop: while (true) {
        argv.clearRetainingCapacity();
        try argv.append(allocator, exec_path);
        try argv.append(allocator, "agent");
        if (model) |m| {
            try argv.append(allocator, "--model");
            try argv.append(allocator, m);
        }
        try argv.append(allocator, "-m");
        try argv.append(allocator, prompt);

        child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.cwd = exec_cwd;

        child.spawn() catch |err| switch (err) {
            error.FileNotFound => {
                // If cwd disappeared, retry from process cwd.
                if (exec_cwd != null and !tried_no_cwd) {
                    exec_cwd = null;
                    tried_no_cwd = true;
                    continue :spawn_loop;
                }

                // If current binary path became stale after in-place rebuild,
                // Linux can still re-exec through /proc/self/exe.
                if (comptime builtin.os.tag == .linux) {
                    if (!tried_proc_self_exe and !std.mem.eql(u8, exec_path, LINUX_SELF_EXE_PATH)) {
                        exec_path = LINUX_SELF_EXE_PATH;
                        exec_cwd = cwd;
                        tried_no_cwd = false;
                        tried_proc_self_exe = true;
                        continue :spawn_loop;
                    }
                }

                // Cross-platform fallback: try resolving `nullclaw` from PATH.
                // Useful when self-exe path is stale or inaccessible outside Linux.
                if (!tried_path_exec) {
                    exec_path = pathAgentExecutableName();
                    exec_cwd = null;
                    tried_no_cwd = true;
                    tried_path_exec = true;
                    continue :spawn_loop;
                }

                return err;
            },
            else => return err,
        };
        break :spawn_loop;
    }

    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const start_ns = std.time.nanoTimestamp();

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const timed_out = try collectChildOutputWithTimeout(
        &child,
        allocator,
        &stdout,
        &stderr,
        timeout_secs,
        start_ns,
    );

    const term = try child.wait();
    const success = !timed_out and switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    const output = try buildAgentOutput(allocator, stdout.items, stderr.items, timeout_secs, timed_out);
    return .{ .success = success, .output = output };
}

// ── Tests ──────────────────────────────────────────────────────────

const platform = @import("platform.zig");

test "collectChildOutputWithTimeout disables timeout when set to zero" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{ platform.getShell(), platform.getShellFlag(), "echo ready" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const timed_out = try collectChildOutputWithTimeout(
        &child,
        allocator,
        &stdout,
        &stderr,
        0,
        std.time.nanoTimestamp(),
    );
    const term = try child.wait();

    try std.testing.expect(!timed_out);
    switch (term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => try std.testing.expect(false),
    }
    try std.testing.expect(std.mem.indexOf(u8, stdout.items, "ready") != null);
}

test "collectChildOutputWithTimeout kills process after deadline" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{ platform.getShell(), platform.getShellFlag(), "sleep 2; echo never" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const timed_out = try collectChildOutputWithTimeout(
        &child,
        allocator,
        &stdout,
        &stderr,
        1,
        std.time.nanoTimestamp(),
    );
    const term = try child.wait();

    try std.testing.expect(timed_out);
    const completed_ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    try std.testing.expect(!completed_ok);
}

test "preferExecPath keeps regular executable path" {
    const input = "/home/user/bin/nullclaw";
    try std.testing.expectEqualStrings(input, preferExecPath(input));
}

test "preferExecPath uses proc self exe for deleted linux path" {
    if (comptime builtin.os.tag != .linux) return;
    try std.testing.expectEqualStrings(LINUX_SELF_EXE_PATH, preferExecPath("/tmp/nullclaw (deleted)"));
}

test "pathAgentExecutableName returns platform command name" {
    const expected = if (comptime builtin.os.tag == .windows) "nullclaw.exe" else "nullclaw";
    try std.testing.expectEqualStrings(expected, pathAgentExecutableName());
}
