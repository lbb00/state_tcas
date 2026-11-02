//! Exhaust + publish + Role → picture lock.
//! Run: `zig build example-exhaust-lock` (cwd = package root).
//! Update golden: touch .state_tcas-update-pictures && zig build example-exhaust-lock

const std = @import("std");
const state_tcas = @import("state_tcas");

const Act = enum { ping, pong };
const Phase = enum { idle, after_ping, after_pong, done };

const Ctx = struct {
    allocator: std.mem.Allocator,
    phase: Phase = .idle,

    fn name(self: *const @This()) []const u8 {
        return switch (self.phase) {
            .idle => "idle",
            .after_ping => "after_ping",
            .after_pong => "after_pong",
            .done => "done",
        };
    }

    pub fn prepare(self: *@This()) !void {
        self.phase = .idle;
    }

    pub fn release(_: *@This()) void {}

    pub fn step(self: *@This(), act: Act, pic: ?*state_tcas.Picture) !void {
        const before = self.name();
        switch (self.phase) {
            .idle => switch (act) {
                .ping => self.phase = .after_ping,
                .pong => self.phase = .after_pong,
            },
            .after_ping => switch (act) {
                .pong => self.phase = .done,
                .ping => return error.BadOrder,
            },
            .after_pong => switch (act) {
                .ping => self.phase = .done,
                .pong => return error.BadOrder,
            },
            .done => return error.BadOrder,
        }
        if (pic) |p| {
            try p.observe(self.allocator, .{
                .before = before,
                .after = self.name(),
                .label = @tagName(act),
                .rejected = false,
                .mutated = true,
                .note = self.name(),
                .from = state_tcas.Role.initiator.participant(),
                .to = state_tcas.Role.responder.participant(),
            });
        }
    }

    pub fn finish(_: *@This(), _: []const Act) !void {}
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var ctx: Ctx = .{ .allocator = allocator };
    const seed = [_]Act{ .ping, .pong };
    const story = &[_]Act{ .ping, .pong };
    const must = [_][]const u8{ "idle", "after_ping", "after_pong", "done" };

    const text = try state_tcas.exhaust.publish(
        init.io,
        allocator,
        "examples/locks/toy_exhaust.md",
        "# toy exhaust lock\n\n",
        state_tcas.Role.initiator.participant(),
        state_tcas.Role.responder.participant(),
        Act,
        2,
        seed,
        story,
        2, // 2! unique orders
        &must,
        &ctx,
    );
    defer allocator.free(text);
    std.debug.print("toy_exhaust_lock ok visits=2 bytes={d}\n", .{text.len});
}
