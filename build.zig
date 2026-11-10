const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("state_tcas", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run state_tcas package tests");
    test_step.dependOn(&run_tests.step);

    const gate_exe = b.addExecutable(.{
        .name = "explore_gate_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gate_check.zig"),
            .target = b.graph.host,
        }),
    });
    b.installArtifact(gate_exe);

    const gate_step = b.step("gate-check", "Scan codebase for forbidden exploration patterns");
    const gate_check = addExploreGateCheck(b, .{
        .rules = &.{
            .{
                .path = "examples",
                .forbidden_patterns = &.{"dispatchEventsUngated"},
                .extensions = &.{".zig"},
                .ignore_comments = true,
            },
        },
    });
    gate_step.dependOn(gate_check);
    test_step.dependOn(gate_check);

    const toy = b.addExecutable(.{
        .name = "toy_fsm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/toy_fsm.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "state_tcas", .module = mod },
            },
        }),
    });
    const run_toy = b.addRunArtifact(toy);
    const example_toy = b.step("example-toy", "Run examples/toy_fsm.zig");
    example_toy.dependOn(&run_toy.step);

    const exhaust_ex = b.addExecutable(.{
        .name = "toy_exhaust_lock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/toy_exhaust_lock.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "state_tcas", .module = mod },
            },
        }),
    });
    const run_exhaust = b.addRunArtifact(exhaust_ex);
    // Lock path is relative to package root.
    run_exhaust.setCwd(b.path("."));
    const example_exhaust = b.step("example-exhaust-lock", "Run examples/toy_exhaust_lock.zig + picture lock");
    example_exhaust.dependOn(&run_exhaust.step);

    const cal_ex = b.addExecutable(.{
        .name = "toy_calendar_timeout",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/toy_calendar_timeout.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "state_tcas", .module = mod },
            },
        }),
    });
    const run_cal = b.addRunArtifact(cal_ex);
    const example_cal = b.step("example-calendar", "Run examples/toy_calendar_timeout.zig");
    example_cal.dependOn(&run_cal.step);

    const cal_dfs_ex = b.addExecutable(.{
        .name = "toy_calendar_dfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/toy_calendar_dfs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "state_tcas", .module = mod },
            },
        }),
    });
    const run_cal_dfs = b.addRunArtifact(cal_dfs_ex);
    const example_cal_dfs = b.step("example-calendar-dfs", "Run examples/toy_calendar_dfs.zig");
    example_cal_dfs.dependOn(&run_cal_dfs.step);

    const act_log_ex = b.addExecutable(.{
        .name = "toy_act_log_dfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/toy_act_log_dfs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "state_tcas", .module = mod },
            },
        }),
    });
    const run_act_log = b.addRunArtifact(act_log_ex);
    const example_act_log = b.step("example-act-log", "Run examples/toy_act_log_dfs.zig");
    example_act_log.dependOn(&run_act_log.step);

    const examples = b.step("examples", "Run all example-* executables");
    examples.dependOn(example_toy);
    examples.dependOn(example_exhaust);
    examples.dependOn(example_cal);
    examples.dependOn(example_cal_dfs);
    examples.dependOn(example_act_log);
}

pub const GateRule = struct {
    /// Target path (directory or file relative to build root).
    path: []const u8,
    /// Forbidden patterns that must not appear in any scanned file.
    forbidden_patterns: []const []const u8,
    /// File extension filter (default: &.{ ".zig" }). If empty, matches all files.
    extensions: []const []const u8 = &.{".zig"},
    /// When true, strips line comments (`//`, `///`, `//!`) outside quotes before pattern scanning.
    ignore_comments: bool = false,
};

pub const ExploreGateOptions = struct {
    rules: []const GateRule,
};

/// Expose a native Zig build step helper for adopters.
/// Scans target directories/files for forbidden patterns (e.g. `Ungated` in explore
/// harness files, or `explore.bfs` on live contexts) using Zig's standard library.
pub fn addExploreGateCheck(b: *std.Build, options: ExploreGateOptions) *std.Build.Step {
    // Note: Do not use b.path("src/gate_check.zig") here because `b` is provided by
    // the caller (which may be a downstream package). b.path resolves relative to
    // the caller's build root rather than state_tcas. @embedFile embeds the source
    // directly, guaranteeing portability when called from any adopter project.
    const wf = b.addWriteFiles();
    const gate_src = wf.add("gate_check.zig", @embedFile("src/gate_check.zig"));
    const exe = b.addExecutable(.{
        .name = "explore_gate_check",
        .root_module = b.createModule(.{
            .root_source_file = gate_src,
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    for (options.rules) |rule| {
        run.addArg("--path");
        run.addArg(rule.path);
        for (rule.extensions) |ext| {
            run.addArg("--ext");
            run.addArg(ext);
        }
        for (rule.forbidden_patterns) |pat| {
            run.addArg("--forbid");
            run.addArg(pat);
        }
        if (rule.ignore_comments) {
            run.addArg("--ignore-comments");
        }
        run.addArg("--rule-end");
    }
    return &run.step;
}
