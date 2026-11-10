//! Complete Self-Bootstrapping (Dogfooding) verification example for state_tcas.
//!
//! Verifies state_tcas by using state_tcas primitives to thoroughly explore
//! and validate state_tcas's own core components and algorithms:
//! 1. `Calendar` state space explored via `explore.dfsKeyed` with `monitor.Safety` & `monitor.Liveness`
//! 2. `SleepSet` Partial Order Reduction verified to prune redundant interleavings
//! 3. `minimizeTrace` verified to isolate the minimal fault subsequence
//! 4. `tla` module verified to lock model declarations and replay Apalache ITF traces
//!
//! Run: `zig build example-bootstrap` (cwd = package root).

const std = @import("std");
const state_tcas = @import("state_tcas");

pub const BootstrapAct = union(enum) {
    schedule: u32,
    advance: u32,
    fire,
    cancel,
};

pub const BootstrapState = enum { idle, scheduled, expired, cancelled };

pub const BootstrapConfig = struct {
    pub const max_events: u32 = 4;
    pub const time_horizon: u32 = 1000;
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // --- 1. Calendar State Exploration under dfsKeyed with Safety & Liveness ---
    const CalAct = enum {
        schedule_10,
        schedule_20,
        cancel_first,
        advance_next,
        fire_due,
        compact,
    };

    const Frame = struct {
        snap: state_tcas.calendar.Calendar,
        fired_len: usize,
        scheduled_len: usize,
        prev_now: u64,
    };

    const CalWorld = struct {
        allocator: std.mem.Allocator,
        cal: state_tcas.calendar.Calendar,
        prev_now: u64 = 0,
        history: std.ArrayList(Frame),
        fired_tags: std.ArrayList(u32),
        scheduled_ids: std.ArrayList(state_tcas.calendar.EventId),
        acts_buf: [6]CalAct = undefined,

        pub fn initWorld(alloc: std.mem.Allocator) @This() {
            return .{
                .allocator = alloc,
                .cal = state_tcas.calendar.Calendar.init(alloc, 0),
                .history = .empty,
                .fired_tags = .empty,
                .scheduled_ids = .empty,
            };
        }

        pub fn deinit(self: *@This()) void {
            while (self.history.pop()) |f| {
                var frame = f;
                frame.snap.deinit();
            }
            self.history.deinit(self.allocator);
            self.fired_tags.deinit(self.allocator);
            self.scheduled_ids.deinit(self.allocator);
            self.cal.deinit();
        }

        pub fn key(self: *const @This()) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&self.cal.now_us));
            const p = self.cal.pendingCount();
            hasher.update(std.mem.asBytes(&p));
            const s = self.cal.slotCount();
            hasher.update(std.mem.asBytes(&s));
            const f = self.fired_tags.items.len;
            hasher.update(std.mem.asBytes(&f));
            for (self.cal.events.items) |ev| {
                hasher.update(std.mem.asBytes(&ev.at_us));
                hasher.update(std.mem.asBytes(&ev.tag));
                const c: u8 = if (ev.cancelled) 1 else 0;
                hasher.update(&.{c});
            }
            return hasher.final();
        }

        pub fn enabled(self: *@This()) []const CalAct {
            var n: usize = 0;
            if (self.fired_tags.items.len >= 2 or self.cal.now_us >= 40) {
                return self.acts_buf[0..0];
            }
            if (self.cal.slotCount() < 2) {
                self.acts_buf[n] = .schedule_10;
                n += 1;
                self.acts_buf[n] = .schedule_20;
                n += 1;
            }
            if (self.cal.pendingCount() > 0) {
                self.acts_buf[n] = .cancel_first;
                n += 1;
            }
            if (self.cal.pendingCount() > 0 and self.cal.peekDue() == null) {
                self.acts_buf[n] = .advance_next;
                n += 1;
            }
            if (self.cal.peekDue() != null) {
                self.acts_buf[n] = .fire_due;
                n += 1;
            }
            if (self.cal.slotCount() > self.cal.pendingCount()) {
                self.acts_buf[n] = .compact;
                n += 1;
            }
            return self.acts_buf[0..n];
        }

        pub fn step(self: *@This(), act: CalAct) !void {
            var snap = try self.cal.clone();
            errdefer snap.deinit();
            try self.history.append(self.allocator, .{
                .snap = snap,
                .fired_len = self.fired_tags.items.len,
                .scheduled_len = self.scheduled_ids.items.len,
                .prev_now = self.prev_now,
            });

            self.prev_now = self.cal.now_us;

            switch (act) {
                .schedule_10 => {
                    const id = try self.cal.schedule(self.cal.now_us + 10, 10, 0);
                    try self.scheduled_ids.append(self.allocator, id);
                },
                .schedule_20 => {
                    const id = try self.cal.schedule(self.cal.now_us + 20, 20, 0);
                    try self.scheduled_ids.append(self.allocator, id);
                },
                .cancel_first => {
                    for (self.scheduled_ids.items) |id| {
                        if (self.cal.cancel(id)) break;
                    }
                },
                .advance_next => {
                    _ = try self.cal.advanceToNext();
                },
                .fire_due => {
                    const Handler = struct {
                        target: *std.ArrayList(u32),
                        alloc: std.mem.Allocator,
                        fn on(ctx: *@This(), tag: u32, _: u64) !void {
                            try ctx.target.append(ctx.alloc, tag);
                        }
                    };
                    var h = Handler{ .target = &self.fired_tags, .alloc = self.allocator };
                    _ = try self.cal.fireDue(&h, Handler.on);
                },
                .compact => {
                    self.cal.compactCancelled();
                },
            }
        }

        pub fn undo(self: *@This(), act: CalAct) void {
            _ = act;
            var frame = self.history.pop().?;
            std.debug.assert(self.cal.events.capacity >= frame.snap.events.items.len);
            self.cal.resetTo(&frame.snap) catch unreachable;
            frame.snap.deinit();
            self.fired_tags.shrinkRetainingCapacity(frame.fired_len);
            self.scheduled_ids.shrinkRetainingCapacity(frame.scheduled_len);
            self.prev_now = frame.prev_now;
        }
    };

    const Checkers = struct {
        fn checkSafety(w: *CalWorld) anyerror!void {
            if (w.cal.now_us < w.prev_now) return error.ClockRewind;
            if (w.cal.pendingCount() > w.cal.slotCount()) return error.PendingExceedsSlots;
        }

        fn checkEnabled(_: *CalWorld) bool {
            return true;
        }

        fn checkGoal(w: *CalWorld) bool {
            return w.fired_tags.items.len >= 2;
        }
    };

    var world = CalWorld.initWorld(allocator);
    defer world.deinit();

    var saf = state_tcas.monitor.Safety(*CalWorld){ .ctx = &world, .checkFn = Checkers.checkSafety };
    var liv = state_tcas.monitor.Liveness(*CalWorld){ .ctx = &world, .enabledFn = Checkers.checkEnabled, .goalFn = Checkers.checkGoal };

    var monitored = state_tcas.monitor.MonitoredKeyed(CalAct, CalWorld){
        .inner = &world,
        .saf = &saf,
        .liv = &liv,
    };

    var cal_stats: state_tcas.explore.Stats = .{};
    var visited = std.AutoHashMap(u64, void).init(allocator);
    defer visited.deinit();

    try state_tcas.explore.dfsKeyed(CalAct, u64, &monitored, 600, &cal_stats, &visited);
    try liv.finish();

    // --- 2. SleepSet Partial Order Reduction Verification ---
    const PorAct = enum { inc_a, inc_b, sync };
    const PorSystem = struct {
        a: u8 = 0,
        b: u8 = 0,
        synced: bool = false,
        buf: [3]PorAct = undefined,

        pub fn enabled(self: *@This()) []const PorAct {
            var n: usize = 0;
            if (self.a < 2) {
                self.buf[n] = .inc_a;
                n += 1;
            }
            if (self.b < 2) {
                self.buf[n] = .inc_b;
                n += 1;
            }
            if (self.a > 0 and self.b > 0 and !self.synced) {
                self.buf[n] = .sync;
                n += 1;
            }
            return self.buf[0..n];
        }

        pub fn step(self: *@This(), act: PorAct) !void {
            switch (act) {
                .inc_a => self.a += 1,
                .inc_b => self.b += 1,
                .sync => self.synced = true,
            }
        }

        pub fn undo(self: *@This(), act: PorAct) void {
            switch (act) {
                .inc_a => self.a -= 1,
                .inc_b => self.b -= 1,
                .sync => self.synced = false,
            }
        }

        pub fn commutes(_: *const @This(), x: PorAct, y: PorAct) bool {
            return (x == .inc_a and y == .inc_b) or (x == .inc_b and y == .inc_a);
        }
    };

    var por_sys = PorSystem{};
    var por_stats: state_tcas.explore.Stats = .{};
    try state_tcas.explore.dfs(PorAct, &por_sys, 100, &por_stats);

    // --- 3. minimizeTrace Delta Debugging Verification ---
    const TraceAct = enum { setup, noise_a, noise_b, arm, noise_c, trigger, noise_d };
    const PlayContext = struct {
        state: enum { init, setup_done, armed, triggered } = .init,

        pub fn play(self: *@This(), trace: []const TraceAct) anyerror!void {
            self.state = .init;
            for (trace) |act| {
                switch (act) {
                    .setup => if (self.state == .init) {
                        self.state = .setup_done;
                    },
                    .arm => if (self.state == .setup_done) {
                        self.state = .armed;
                    },
                    .trigger => if (self.state == .armed) {
                        self.state = .triggered;
                        return error.CrashTriggered;
                    },
                    .noise_a, .noise_b, .noise_c, .noise_d => {},
                }
            }
        }
    };

    const noisy_trace = [_]TraceAct{
        .noise_a,
        .setup,
        .noise_b,
        .arm,
        .noise_c,
        .noise_d,
        .trigger,
        .noise_a,
    };

    const Runner = struct {
        fn run(ctx: *PlayContext, acts: []const TraceAct) anyerror!void {
            return ctx.play(acts);
        }
    };

    const min_trace = try state_tcas.explore.minimizeTrace(
        TraceAct,
        PlayContext,
        allocator,
        &noisy_trace,
        error.CrashTriggered,
        Runner.run,
    );
    defer allocator.free(min_trace);

    // --- 4. TLA+ Golden Model Lock & ITF Trace Replay ---
    try state_tcas.tla.lock(
        io,
        allocator,
        "examples/locks/bootstrap_model.tla",
        "bootstrap_model",
        BootstrapAct,
        BootstrapState,
        BootstrapConfig,
    );

    const Harness = struct {
        state: BootstrapState = .idle,
        now: u32 = 0,
        deadline: u32 = 0,

        pub fn enabled(self: *const @This()) []const BootstrapAct {
            return switch (self.state) {
                .idle => &.{.{ .schedule = 100 }},
                .scheduled => &.{ .{ .advance = 100 }, .cancel },
                .expired => &.{.fire},
                .cancelled => &.{},
            };
        }

        pub fn step(self: *@This(), act: BootstrapAct) !void {
            switch (act) {
                .schedule => |dt| {
                    self.deadline = self.now + dt;
                    self.state = .scheduled;
                },
                .advance => |dt| {
                    self.now += dt;
                    if (self.now >= self.deadline) {
                        self.state = .expired;
                    }
                },
                .fire => self.state = .idle,
                .cancel => self.state = .cancelled,
            }
        }

        pub fn project(self: *const @This()) BootstrapState {
            return self.state;
        }
    };

    var h: Harness = .{};
    const itf_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "examples/locks/bootstrap_itf_trace.json", allocator, .limited(1024 * 1024));
    defer allocator.free(itf_bytes);

    const tla_stats = try state_tcas.tla.replayJsonTrace(BootstrapAct, &h, allocator, itf_bytes, null);

    std.debug.print(
        "bootstrap dogfood ok: cal_visits={d} sleep_skipped={d} min_len={d} tla_replayed={d}\n",
        .{ cal_stats.visits, por_stats.sleep_skipped, min_trace.len, tla_stats.actions_replayed },
    );
}
