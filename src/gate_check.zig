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
    out_files_scanned: ?*usize,
    verbose: bool,
) !void {
    if (out_files_scanned) |fs| fs.* += 1;
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
        if (verbose) std.debug.print("Gate check error: unable to read {s}: {s}\n", .{ path, @errorName(err) });
        out_violations.* += 1;
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
    out_files_scanned: ?*usize,
    verbose: bool,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        if (verbose) std.debug.print("Gate check error: unable to open dir {s}: {s}\n", .{ dir_path, @errorName(err) });
        out_violations.* += 1;
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        var is_target = false;
        if (entry.kind == .file) {
            is_target = true;
        } else if (entry.kind == .sym_link) {
            const rel = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
            defer allocator.free(rel);
            const st = std.Io.Dir.cwd().statFile(io, rel, .{}) catch continue;
            if (st.kind == .file) is_target = true;
        }
        if (!is_target) continue;

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

        try checkFile(io, allocator, full_path, forbidden_patterns, out_violations, out_files_scanned, verbose);
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
    var files_scanned: usize = 0;
    const stat = std.Io.Dir.cwd().statFile(io, target_path, .{}) catch |err| {
        var dir = std.Io.Dir.cwd().openDir(io, target_path, .{ .iterate = true }) catch {
            if (verbose) std.debug.print("Gate check error: cannot access target path {s}: {s}\n", .{ target_path, @errorName(err) });
            out_violations.* += 1;
            return;
        };
        dir.close(io);
        try checkDir(io, allocator, target_path, forbidden_patterns, extensions, out_violations, &files_scanned, verbose);
        if (files_scanned == 0) {
            if (verbose) std.debug.print("Gate check error: rule for directory '{s}' matched 0 files\n", .{target_path});
            out_violations.* += 1;
        }
        return;
    };

    if (stat.kind == .directory) {
        try checkDir(io, allocator, target_path, forbidden_patterns, extensions, out_violations, &files_scanned, verbose);
        if (files_scanned == 0) {
            if (verbose) std.debug.print("Gate check error: rule for directory '{s}' matched 0 files\n", .{target_path});
            out_violations.* += 1;
        }
    } else {
        try checkFile(io, allocator, target_path, forbidden_patterns, out_violations, &files_scanned, verbose);
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
    var rules_count: usize = 0;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--path")) {
            const p = it.next() orelse {
                std.debug.print("Gate check error: --path requires a path argument\n", .{});
                std.process.exit(1);
            };
            current_path = p;
        } else if (std.mem.eql(u8, arg, "--ext")) {
            const e = it.next() orelse {
                std.debug.print("Gate check error: --ext requires an extension argument\n", .{});
                std.process.exit(1);
            };
            try current_extensions.append(allocator, e);
        } else if (std.mem.eql(u8, arg, "--forbid")) {
            const f = it.next() orelse {
                std.debug.print("Gate check error: --forbid requires a pattern argument\n", .{});
                std.process.exit(1);
            };
            try current_patterns.append(allocator, f);
        } else if (std.mem.eql(u8, arg, "--rule-end")) {
            if (current_path == null and current_patterns.items.len == 0) continue;
            if (current_path == null or current_patterns.items.len == 0) {
                std.debug.print("Gate check error: each rule must specify both a target path and at least one forbidden pattern\n", .{});
                std.process.exit(1);
            }
            rules_count += 1;
            try checkTarget(
                io,
                allocator,
                current_path.?,
                current_patterns.items,
                current_extensions.items,
                &total_violations,
                true,
            );
            current_path = null;
            current_extensions.clearRetainingCapacity();
            current_patterns.clearRetainingCapacity();
        } else {
            std.debug.print("Gate check error: unrecognized argument '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }
    if (current_path != null or current_patterns.items.len > 0) {
        if (current_path == null or current_patterns.items.len == 0) {
            std.debug.print("Gate check error: final rule must specify both a target path and at least one forbidden pattern\n", .{});
            std.process.exit(1);
        }
        rules_count += 1;
        try checkTarget(
            io,
            allocator,
            current_path.?,
            current_patterns.items,
            current_extensions.items,
            &total_violations,
            true,
        );
    }

    if (rules_count == 0) {
        std.debug.print("Gate check error: no check rules provided (must specify at least one --path and --forbid)\n", .{});
        std.process.exit(1);
    }

    if (total_violations > 0) {
        std.debug.print("Explore gate check failed: {d} forbidden pattern violation(s) found.\n", .{total_violations});
        std.process.exit(1);
    }
}

test "checkFile detects forbidden pattern" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "test_file.zig",
        .data = "pub fn testFn() void {\n    badActionPattern();\n}\n",
    });

    const full_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "test_file.zig" });
    defer allocator.free(full_path);

    var violations: usize = 0;
    try checkFile(io, allocator, full_path, &.{ "badActionPattern", "explore.bfs(" }, &violations, null, false);
    try std.testing.expectEqual(@as(usize, 1), violations);

    var clean_violations: usize = 0;
    try checkFile(io, allocator, full_path, &.{"forbiddenPatternNotInFile"}, &clean_violations, null, false);
    try std.testing.expectEqual(@as(usize, 0), clean_violations);

    var missing_violations: usize = 0;
    try checkFile(io, allocator, "does_not_exist_file.zig", &.{"bad"}, &missing_violations, null, false);
    try std.testing.expectEqual(@as(usize, 1), missing_violations);
}
