//! Native explore gate checker.
//!
//! Scans target directories or files for forbidden patterns (e.g. `Ungated` in explore
//! harness files, or `explore.bfs` on live contexts) using Zig's standard library.
//! Replaces fragile shell/grep scripts for adopters.

const std = @import("std");

pub fn checkFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    forbidden_patterns: []const []const u8,
    out_violations: *usize,
    verbose: bool,
) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
        if (verbose) std.debug.print("Gate check warning: unable to read {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer allocator.free(content);

    var line_num: usize = 1;
    var line_start: usize = 0;
    while (line_start < content.len) {
        var line_end = line_start;
        while (line_end < content.len and content[line_end] != '\n') : (line_end += 1) {}
        var line = content[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        for (forbidden_patterns) |pat| {
            if (std.mem.indexOf(u8, line, pat) != null) {
                out_violations.* += 1;
                if (verbose) {
                    std.debug.print("Error: forbidden pattern '{s}' found in {s}:{d}: {s}\n", .{
                        pat,
                        path,
                        line_num,
                        line,
                    });
                }
            }
        }

        line_num += 1;
        line_start = line_end + 1;
    }
}

pub fn checkDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    forbidden_patterns: []const []const u8,
    extensions: []const []const u8,
    out_violations: *usize,
    verbose: bool,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        if (verbose) std.debug.print("Gate check warning: unable to open dir {s}: {s}\n", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        if (extensions.len > 0) {
            var ext_matched = false;
            for (extensions) |ext| {
                if (std.mem.endsWith(u8, entry.path, ext)) {
                    ext_matched = true;
                    break;
                }
            }
            if (!ext_matched) continue;
        }

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(full_path);

        try checkFile(io, allocator, full_path, forbidden_patterns, out_violations, verbose);
    }
}

pub fn checkTarget(
    io: std.Io,
    allocator: std.mem.Allocator,
    target_path: []const u8,
    forbidden_patterns: []const []const u8,
    extensions: []const []const u8,
    out_violations: *usize,
    verbose: bool,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, target_path, .{}) catch |err| {
        var dir = std.Io.Dir.cwd().openDir(io, target_path, .{ .iterate = true }) catch {
            if (verbose) std.debug.print("Gate check warning: cannot access path {s}: {s}\n", .{ target_path, @errorName(err) });
            return;
        };
        dir.close(io);
        try checkDir(io, allocator, target_path, forbidden_patterns, extensions, out_violations, verbose);
        return;
    };

    if (stat.kind == .directory) {
        try checkDir(io, allocator, target_path, forbidden_patterns, extensions, out_violations, verbose);
    } else {
        try checkFile(io, allocator, target_path, forbidden_patterns, out_violations, verbose);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    _ = it.skip();

    var current_path: ?[]const u8 = null;
    var current_extensions: std.ArrayList([]const u8) = .empty;
    var current_patterns: std.ArrayList([]const u8) = .empty;
    var total_violations: usize = 0;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--path")) {
            if (it.next()) |p| {
                current_path = p;
            }
        } else if (std.mem.eql(u8, arg, "--ext")) {
            if (it.next()) |e| {
                try current_extensions.append(allocator, e);
            }
        } else if (std.mem.eql(u8, arg, "--forbid")) {
            if (it.next()) |f| {
                try current_patterns.append(allocator, f);
            }
        } else if (std.mem.eql(u8, arg, "--rule-end")) {
            if (current_path) |p| {
                try checkTarget(
                    io,
                    allocator,
                    p,
                    current_patterns.items,
                    current_extensions.items,
                    &total_violations,
                    true,
                );
            }
            current_path = null;
            current_extensions.clearRetainingCapacity();
            current_patterns.clearRetainingCapacity();
        }
    }
    if (current_path) |p| {
        try checkTarget(
            io,
            allocator,
            p,
            current_patterns.items,
            current_extensions.items,
            &total_violations,
            true,
        );
    }

    if (total_violations > 0) {
        std.debug.print("Explore gate check failed: {d} forbidden pattern violation(s) found.\n", .{total_violations});
        std.process.exit(1);
    }
}

test "checkFile detects forbidden pattern" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = ".zig-cache/tmp_gate_check_test.txt";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = "pub fn testFn() void {\n    badActionPattern();\n}\n",
    });

    var violations: usize = 0;
    try checkFile(io, allocator, path, &.{ "badActionPattern", "explore.bfs(" }, &violations, false);
    try std.testing.expectEqual(@as(usize, 1), violations);

    var clean_violations: usize = 0;
    try checkFile(io, allocator, path, &.{"forbiddenPatternNotInFile"}, &clean_violations, false);
    try std.testing.expectEqual(@as(usize, 0), clean_violations);
}
