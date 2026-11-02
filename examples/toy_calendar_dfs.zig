//! Calendar + explore.dfs Frame: clone in step, resetTo in void undo.
//! Run: `zig build example-calendar-dfs` from the package root.

const std = @import("std");
const state_tcas = @import("state_tcas");

const Act = enum { schedule_timeout, advance_and_fire };

const Frame = struct {
    snap: state_tcas.calendar.Calendar,
    fired: usize,
};

const Ctx = struct {
    allocator: std.mem.Allocator,
    cal: state_tcas.calendar.Calendar,
    frames: std.ArrayList(Frame) = .empty,
    fired: usize = 0,
    acts_buf: [2]Act = undefined,

    pub fn enabled(self: *@This()) []const Act {
        if (self.cal.pendingCount() == 0 and self.fired == 0 and self.cal.now_us == 0) {
            self.acts_buf[0] = .schedule_timeout;
            return self.acts_buf[0..1];
        }
        if (self.cal.pendingCount() > 0) {
            self.acts_buf[0] = .advance_and_fire;
            return self.acts_buf[0..1];
        }
        return self.acts_buf[0..0];
    }

    pub fn step(self: *@This(), act: Act) !void {
        var snap = try self.cal.clone();
        self.frames.append(self.allocator, .{ .snap = snap, .fired = self.fired }) catch |err| {
            snap.deinit();
            return err;
        };
        switch (act) {
            .schedule_timeout => {
                _ = try self.cal.schedule(self.cal.now_us + 100, 1, 0);
            },
            .advance_and_fire => {
                _ = try self.cal.advanceToNext();
                const Sink = struct {
                    n: usize = 0,
                    fn on(s: *@This(), _: u32, _: u64) !void {
                        s.n += 1;
                    }
                };
                var sink: Sink = .{};
                _ = try self.cal.fireDue(&sink, Sink.on);
                self.fired += sink.n;
            },
        }
    }

    pub fn undo(self: *@This(), act: Act) void {
        _ = act;
        var frame = self.frames.pop().?;
        self.cal.resetTo(&frame.snap) catch unreachable;
        self.fired = frame.fired;
        frame.snap.deinit();
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var ctx: Ctx = .{
        .allocator = allocator,
        .cal = state_tcas.calendar.Calendar.init(allocator, 0),
    };
    defer {
        while (ctx.frames.pop()) |f| {
            var frame = f;
            frame.snap.deinit();
        }
        ctx.frames.deinit(allocator);
        ctx.cal.deinit();
    }

    var stats: state_tcas.explore.Stats = .{};
    try state_tcas.explore.dfs(Act, &ctx, 32, &stats);

    if (ctx.cal.now_us != 0 or ctx.fired != 0 or ctx.cal.pendingCount() != 0) {
        return error.ExampleFailed;
    }
    if (stats.expansions < 2) return error.ExampleFailed;
    std.debug.print("toy_calendar_dfs ok visits={d} expansions={d}\n", .{ stats.visits, stats.expansions });
}
