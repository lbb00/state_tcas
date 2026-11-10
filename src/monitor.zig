//! Attachable Safety / Liveness checks for harness steps and calendar fires.
//!
//! Safety: never violate after a step. Liveness: finish-style goal
//! (eventually / enabled-then-must). Not LTL, not a production conformance pipe.

const std = @import("std");
const explore = @import("explore.zig");

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
/// Liveness check verifying reachability of a goal condition.
///
/// Semantics: `state_tcas` treats `Liveness` as monotonic branch reachability:
/// it verifies that at least one reachable exploration branch reaches the goal
/// (`note()` sets `reached = true` monotonically; `undo` does not reset it).
/// To assert that *every* terminal execution path reaches a goal (e.g. deadlock
/// without goal), enforce this via `Safety` (e.g. assert when `enabled().len == 0`).
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

/// Generic adapter wrapping an inner world context with attached Safety and
/// Liveness monitors. On `step(act)`, calls `inner.step(act)`, `saf.observe()`,
/// and `liv.note()`. Forwards `enabled()` and `undo(act)` to `inner`.
pub fn Monitored(comptime Act: type, comptime World: type) type {
    const has_commutes = @hasDecl(World, "commutes");
    if (has_commutes) {
        return struct {
            inner: *World,
            saf: *Safety(*World),
            liv: *Liveness(*World),

            pub fn enabled(self: *@This()) []const Act {
                return self.inner.enabled();
            }

            pub fn step(self: *@This(), act: Act) !void {
                try self.inner.step(act);
                try self.saf.observe();
                self.liv.note();
            }

            pub fn undo(self: *@This(), act: Act) void {
                self.inner.undo(act);
            }

            pub fn commutes(self: *const @This(), a: Act, b: Act) bool {
                return self.inner.commutes(a, b);
            }
        };
    } else {
        return struct {
            inner: *World,
            saf: *Safety(*World),
            liv: *Liveness(*World),

            pub fn enabled(self: *@This()) []const Act {
                return self.inner.enabled();
            }

            pub fn step(self: *@This(), act: Act) !void {
                try self.inner.step(act);
                try self.saf.observe();
                self.liv.note();
            }

            pub fn undo(self: *@This(), act: Act) void {
                self.inner.undo(act);
            }
        };
    }
}

/// Generic adapter identical to `Monitored` plus forwarding `key()` from
/// `inner.key()` to satisfy `verifyDfsKeyed`.
pub fn MonitoredKeyed(comptime Act: type, comptime World: type) type {
    const has_commutes = @hasDecl(World, "commutes");
    if (has_commutes) {
        return struct {
            inner: *World,
            saf: *Safety(*World),
            liv: *Liveness(*World),

            pub fn enabled(self: *@This()) []const Act {
                return self.inner.enabled();
            }

            pub fn step(self: *@This(), act: Act) !void {
                try self.inner.step(act);
                try self.saf.observe();
                self.liv.note();
            }

            pub fn undo(self: *@This(), act: Act) void {
                self.inner.undo(act);
            }

            pub fn key(self: *const @This()) @TypeOf(self.inner.key()) {
                return self.inner.key();
            }

            pub fn commutes(self: *const @This(), a: Act, b: Act) bool {
                return self.inner.commutes(a, b);
            }
        };
    } else {
        return struct {
            inner: *World,
            saf: *Safety(*World),
            liv: *Liveness(*World),

            pub fn enabled(self: *@This()) []const Act {
                return self.inner.enabled();
            }

            pub fn step(self: *@This(), act: Act) !void {
                try self.inner.step(act);
                try self.saf.observe();
                self.liv.note();
            }

            pub fn undo(self: *@This(), act: Act) void {
                self.inner.undo(act);
            }

            pub fn key(self: *const @This()) @TypeOf(self.inner.key()) {
                return self.inner.key();
            }
        };
    }
}

/// Generic adapter forwarding `enabled`, `step`, `undo`, and `key` to `inner`.
pub fn KeyedOnly(comptime Act: type, comptime World: type) type {
    const has_commutes = @hasDecl(World, "commutes");
    if (has_commutes) {
        return struct {
            inner: *World,

            pub fn enabled(self: *@This()) []const Act {
                return self.inner.enabled();
            }

            pub fn step(self: *@This(), act: Act) !void {
                try self.inner.step(act);
            }

            pub fn undo(self: *@This(), act: Act) void {
                self.inner.undo(act);
            }

            pub fn key(self: *const @This()) @TypeOf(self.inner.key()) {
                return self.inner.key();
            }

            pub fn commutes(self: *const @This(), a: Act, b: Act) bool {
                return self.inner.commutes(a, b);
            }
        };
    } else {
        return struct {
            inner: *World,

            pub fn enabled(self: *@This()) []const Act {
                return self.inner.enabled();
            }

            pub fn step(self: *@This(), act: Act) !void {
                try self.inner.step(act);
            }

            pub fn undo(self: *@This(), act: Act) void {
                self.inner.undo(act);
            }

            pub fn key(self: *const @This()) @TypeOf(self.inner.key()) {
                return self.inner.key();
            }
        };
    }
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

test "Monitored, MonitoredKeyed, KeyedOnly adapters verify and run" {
    const Act = enum { a, b };
    const Model = struct {
        state: u8 = 0,
        bad: bool = false,
        goal: bool = false,

        pub fn enabled(self: *@This()) []const Act {
            if (self.state == 0) return &[_]Act{ .a, .b };
            return &[_]Act{};
        }
        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .a => self.state = 1,
                .b => {
                    self.state = 2;
                    self.goal = true;
                },
            }
        }
        pub fn undo(self: *@This(), act: Act) void {
            _ = act;
            self.state = 0;
            self.goal = false;
        }
        pub fn key(self: *const @This()) u64 {
            return self.state;
        }
        pub fn checkSafety(self: *@This()) !void {
            if (self.bad) return error.SafetyViolation;
        }
        pub fn isEnabled(_: *@This()) bool {
            return true;
        }
        pub fn isGoal(self: *@This()) bool {
            return self.goal;
        }
    };

    // 1. Monitored satisfies verifyDfs and runs under explore.dfs
    explore.verifyDfs(Act, *Monitored(Act, Model));
    var model: Model = .{};
    var saf = Safety(*Model){ .ctx = &model, .checkFn = Model.checkSafety };
    var liv = Liveness(*Model){ .ctx = &model, .enabledFn = Model.isEnabled, .goalFn = Model.isGoal };
    var monitored = Monitored(Act, Model){ .inner = &model, .saf = &saf, .liv = &liv };

    var stats1: explore.Stats = .{};
    try explore.dfs(Act, &monitored, 16, &stats1);
    try std.testing.expect(saf.observations >= 2);
    try std.testing.expect(liv.reached);
    try liv.finish();

    // 2. MonitoredKeyed satisfies verifyDfsKeyed and runs under explore.dfsKeyed
    explore.verifyDfsKeyed(Act, u64, *MonitoredKeyed(Act, Model));
    var model2: Model = .{};
    var saf2 = Safety(*Model){ .ctx = &model2, .checkFn = Model.checkSafety };
    var liv2 = Liveness(*Model){ .ctx = &model2, .enabledFn = Model.isEnabled, .goalFn = Model.isGoal };
    var mon_keyed = MonitoredKeyed(Act, Model){ .inner = &model2, .saf = &saf2, .liv = &liv2 };

    var stats2: explore.Stats = .{};
    var visited = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer visited.deinit();
    try explore.dfsKeyed(Act, u64, &mon_keyed, 16, &stats2, &visited);
    try std.testing.expect(saf2.observations >= 2);
    try std.testing.expect(liv2.reached);

    // 3. KeyedOnly satisfies verifyDfsKeyed and runs under explore.dfsKeyed
    explore.verifyDfsKeyed(Act, u64, *KeyedOnly(Act, Model));
    var model3: Model = .{};
    var keyed_only = KeyedOnly(Act, Model){ .inner = &model3 };
    var stats3: explore.Stats = .{};
    var visited2 = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer visited2.deinit();
    try explore.dfsKeyed(Act, u64, &keyed_only, 16, &stats3, &visited2);
    try std.testing.expect(stats3.visits >= 2);
}
