//! Attachable Safety / Liveness checks for harness steps and calendar fires.
//!
//! Safety: never violate after a step. Liveness: finish-style goal
//! (eventually / enabled-then-must). Not LTL, not a production conformance pipe.

const std = @import("std");

pub const SafetyError = error{
    SafetyViolation,
};

/// Caller-owned Safety checker. `check` runs after every observed step/fire.
pub fn Safety(comptime Ctx: type) type {
    return struct {
        ctx: Ctx,
        /// Invoked after each observation; return error to fail the run.
        checkFn: *const fn (ctx: Ctx) anyerror!void,
        observations: usize = 0,

        pub fn observe(self: *@This()) !void {
            try self.checkFn(self.ctx);
            self.observations += 1;
        }
    };
}

/// Finish-style Liveness: after a run, if `enabledFn` is true then either
/// `note()` saw the goal or `goalFn` holds at `finish`.
/// If `enabledFn` is false, `finish` succeeds even without the goal (disabled run).
/// Not LTL □◇; only a harness finish check.
pub fn Liveness(comptime Ctx: type) type {
    return struct {
        ctx: Ctx,
        enabledFn: *const fn (ctx: Ctx) bool,
        goalFn: *const fn (ctx: Ctx) bool,
        reached: bool = false,

        pub fn note(self: *@This()) void {
            if (self.goalFn(self.ctx)) self.reached = true;
        }

        pub fn finish(self: *@This()) error{LivenessMissed}!void {
            if (self.enabledFn(self.ctx) and !self.reached and !self.goalFn(self.ctx)) {
                return error.LivenessMissed;
            }
        }
    };
}

/// Bundles Safety + optional Liveness for exhaust `step` or calendar `fireDue`.
pub fn Bundle(comptime Ctx: type) type {
    return struct {
        safety: Safety(Ctx),
        liveness: ?Liveness(Ctx) = null,

        pub fn afterStep(self: *@This()) !void {
            try self.safety.observe();
            if (self.liveness) |*liv| liv.note();
        }

        pub fn finish(self: *@This()) !void {
            try self.safety.observe();
            if (self.liveness) |*liv| try liv.finish();
        }
    };
}

test "Safety fails on violation; Liveness only when enabled" {
    const Box = struct {
        bad: bool = false,
        goal: bool = false,
        enable: bool = false,

        fn safetyOk(ctx: *@This()) !void {
            if (ctx.bad) return error.SafetyViolation;
        }
        fn isEnabled(ctx: *@This()) bool {
            return ctx.enable;
        }
        fn isGoal(ctx: *@This()) bool {
            return ctx.goal;
        }
    };
    var box: Box = .{};
    var saf = Safety(*Box){ .ctx = &box, .checkFn = Box.safetyOk };
    try saf.observe();
    box.bad = true;
    try std.testing.expectError(error.SafetyViolation, saf.observe());

    box.bad = false;
    var liv = Liveness(*Box){
        .ctx = &box,
        .enabledFn = Box.isEnabled,
        .goalFn = Box.isGoal,
    };
    // Not enabled → finish ok even without goal.
    try liv.finish();
    box.enable = true;
    try std.testing.expectError(error.LivenessMissed, liv.finish());
    box.goal = true;
    liv.note();
    try liv.finish();
}

test "Bundle afterStep hooks Safety then Liveness note" {
    const Box = struct {
        steps: usize = 0,
        ok: bool = true,
        goal: bool = false,
        enable: bool = true,

        fn safetyOk(ctx: *@This()) !void {
            if (!ctx.ok) return error.SafetyViolation;
            ctx.steps += 1;
        }
        fn isEnabled(ctx: *@This()) bool {
            return ctx.enable;
        }
        fn isGoal(ctx: *@This()) bool {
            return ctx.goal;
        }
    };
    var box: Box = .{};
    var bun = Bundle(*Box){
        .safety = .{ .ctx = &box, .checkFn = Box.safetyOk },
        .liveness = .{
            .ctx = &box,
            .enabledFn = Box.isEnabled,
            .goalFn = Box.isGoal,
        },
    };
    try bun.afterStep();
    try std.testing.expectEqual(@as(usize, 1), box.steps);
    box.goal = true;
    try bun.finish();
    try std.testing.expect(bun.liveness.?.reached or bun.liveness.?.goalFn(&box));
}
