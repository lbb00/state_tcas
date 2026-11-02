//! Toy FSM: idle → arm → fire with explore + Safety/Liveness.
//! `undo` restores observables (`saw_fire`); goal sticks on the Liveness monitor.
//! Run: `zig build example-toy` from the package root.

const std = @import("std");
const state_tcas = @import("state_tcas");

const Act = enum { arm, fire };

comptime {
    const Probe = struct {
        pub fn enabled(self: *@This()) []const Act {
            _ = self;
            return &.{};
        }
        pub fn step(self: *@This(), act: Act) !void {
            _ = self;
            _ = act;
        }
        pub fn undo(self: *@This(), act: Act) void {
            _ = self;
            _ = act;
        }
    };
    state_tcas.explore.verifyDfs(Act, *Probe);
}

const Phase = enum { idle, armed, done };

const Toy = struct {
    phase: Phase = .idle,
    saw_fire: bool = false,
    stack: [8]Phase = undefined,
    sp: usize = 0,

    pub fn enabled(self: *@This()) []const Act {
        return switch (self.phase) {
            .idle => &[_]Act{.arm},
            .armed => &[_]Act{.fire},
            .done => &[_]Act{},
        };
    }
    pub fn step(self: *@This(), act: Act) !void {
        self.stack[self.sp] = self.phase;
        self.sp += 1;
        switch (act) {
            .arm => self.phase = .armed,
            .fire => {
                self.phase = .done;
                self.saw_fire = true;
            },
        }
    }
    pub fn undo(self: *@This(), act: Act) void {
        self.sp -= 1;
        self.phase = self.stack[self.sp];
        if (act == .fire) self.saw_fire = false;
    }
    pub fn safetyOk(ctx: *@This()) !void {
        if (ctx.phase == .done and !ctx.saw_fire) return error.SafetyViolation;
    }
    pub fn isEnabled(_: *@This()) bool {
        return true;
    }
    pub fn isGoal(ctx: *@This()) bool {
        return ctx.saw_fire;
    }
};

pub fn main(init: std.process.Init) !void {
    _ = init;
    var toy: Toy = .{};
    var saf = state_tcas.monitor.Safety(*Toy){ .ctx = &toy, .checkFn = Toy.safetyOk };
    var liv = state_tcas.monitor.Liveness(*Toy){
        .ctx = &toy,
        .enabledFn = Toy.isEnabled,
        .goalFn = Toy.isGoal,
    };
    const Wrapped = struct {
        inner: *Toy,
        saf: *state_tcas.monitor.Safety(*Toy),
        liv: *state_tcas.monitor.Liveness(*Toy),
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
    var wrap: Wrapped = .{ .inner = &toy, .saf = &saf, .liv = &liv };
    var stats: state_tcas.explore.Stats = .{};
    try state_tcas.explore.dfs(Act, &wrap, 16, &stats);
    try liv.finish();
    if (toy.saw_fire) return error.ExampleFailed;
    if (!liv.reached) return error.ExampleFailed;
    std.debug.print("toy_fsm ok visits={d} expansions={d} reached={}\n", .{ stats.visits, stats.expansions, liv.reached });
}
