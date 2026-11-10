//! TLA+ specification lock and ITF trace replay example.
//! Run: `zig build example-tla-lock` (cwd = package root).
//! Update golden: touch .state_tcas-update-tla && zig build example-tla-lock

const std = @import("std");
const state_tcas = @import("state_tcas");

pub const Act = enum { propose, commit, abort };
pub const State = enum { idle, preparing, committed, aborted };

pub const Config = struct {
    pub const max_retries: usize = 3;
    pub const timeout_ms: usize = 1000;
};

pub const Ctx = struct {
    state: State = .idle,
    allocator: std.mem.Allocator,

    pub fn prepare(self: *@This()) !void {
        self.state = .idle;
    }

    pub fn release(_: *@This()) void {}

    pub fn enabled(self: *const @This()) []const Act {
        return switch (self.state) {
            .idle => &.{.propose},
            .preparing => &.{ .commit, .abort },
            .committed, .aborted => &.{},
        };
    }

    pub fn step(self: *@This(), act: Act, pic: ?*state_tcas.Picture) !void {
        const before = @tagName(self.state);
        switch (self.state) {
            .idle => switch (act) {
                .propose => self.state = .preparing,
                else => return error.IllegalAction,
            },
            .preparing => switch (act) {
                .commit => self.state = .committed,
                .abort => self.state = .aborted,
                else => return error.IllegalAction,
            },
            .committed, .aborted => return error.IllegalAction,
        }
        if (pic) |p| {
            try p.observe(self.allocator, .{
                .before = before,
                .after = @tagName(self.state),
                .label = @tagName(act),
                .rejected = false,
                .mutated = true,
                .note = @tagName(self.state),
            });
        }
    }

    pub fn project(self: *const @This()) State {
        return self.state;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // 1. Lock TLA+ model declarations against disk golden
    try state_tcas.tla.lock(
        io,
        allocator,
        "examples/locks/toy_model.tla",
        "toy_model",
        Act,
        State,
        Config,
    );

    // 2. Read and replay ITF trace fixture
    var ctx: Ctx = .{ .allocator = allocator };
    const trace_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "examples/locks/toy_itf_trace.json", allocator, .limited(1024 * 1024));
    defer allocator.free(trace_bytes);

    var pic: state_tcas.Picture = .{};
    defer pic.deinit(allocator);

    const stats = try state_tcas.tla.replayJsonTrace(Act, &ctx, allocator, trace_bytes, &pic);
    if (ctx.state != .committed) return error.ReplayMismatch;
    if (pic.steps.items.len != 2) return error.PictureStepsMissing;

    std.debug.print("toy_tla_lock ok replayed={d} states={d}\n", .{ stats.actions_replayed, stats.states_verified });
}
