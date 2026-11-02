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
