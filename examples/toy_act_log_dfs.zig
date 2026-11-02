//! Act-log rebuild + DFS: origin + log[0..len] is the whole world (no clone).
//! Replace `apply` / `boot` with your live SUT API. Run: `zig build example-act-log`.

const std = @import("std");
const state_tcas = @import("state_tcas");

const Act = enum { tick, tock };

const Ctx = struct {
    log: [32]Act = undefined,
    len: usize = 0,
    phase: u8 = 0,
    acts_buf: [2]Act = undefined,

    fn boot(self: *@This()) void {
        self.phase = 0;
    }
    fn apply(self: *@This(), act: Act) void {
        switch (act) {
            .tick => self.phase +%= 1,
            .tock => self.phase +%= 2,
        }
    }
    fn rebuild(self: *@This()) void {
        self.boot();
        for (self.log[0..self.len]) |a| self.apply(a);
    }

    pub fn enabled(self: *@This()) []const Act {
        if (self.len >= 2) return self.acts_buf[0..0];
        self.acts_buf[0] = .tick;
        self.acts_buf[1] = .tock;
        return self.acts_buf[0..2];
    }
    pub fn step(self: *@This(), act: Act) !void {
        self.log[self.len] = act;
        self.len += 1;
        self.apply(act);
    }
    pub fn undo(self: *@This(), act: Act) void {
        _ = act;
        self.len -= 1;
        self.rebuild();
    }
};

pub fn main(init: std.process.Init) !void {
    _ = init;
    var ctx: Ctx = .{};
    var stats: state_tcas.explore.Stats = .{};
    try state_tcas.explore.dfs(Act, &ctx, 64, &stats);
    if (ctx.len != 0) return error.ExampleFailed;
    if (ctx.phase != 0) return error.ExampleFailed;
    if (stats.visits == 0) return error.ExampleFailed;
    std.debug.print("toy_act_log_dfs ok visits={d} expansions={d} phase={d}\n", .{
        stats.visits,
        stats.expansions,
        ctx.phase,
    });
}
