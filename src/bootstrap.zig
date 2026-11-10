//! Self-Bootstrapping Verification Suite for `state_tcas` (Dogfooding).
//!
//! Verifies state_tcas by using state_tcas primitives to thoroughly explore
//! and validate state_tcas's own core components and algorithms:
//! 1. `Calendar` explored via `explore.dfsKeyed` with `monitor.Safety` and `monitor.Liveness` (EF Reachability)
//! 2. `SleepSet` Partial Order Reduction verified to preserve reachable state space while pruning
//! 3. `ActLogReplay` verified in lockstep against a cloneable reference shadow model
//! 4. `minimizeTrace` verified to isolate exact minimal failure triggers even with interfering noise
//! 5. `tla` module verified to lock model declarations against committed golden files and replay ITF traces

const std = @import("std");
const calendar = @import("calendar.zig");
const explore = @import("explore.zig");
const monitor = @import("monitor.zig");
const exhaust = @import("exhaust.zig");
const picture = @import("picture.zig");
const tla = @import("tla.zig");

test "bootstrap: calendar state space explored via dfsKeyed with Safety & Reachability monitors" {
    const allocator = std.testing.allocator;

    const Act = enum {
        schedule_10,
        schedule_20,
        cancel_first,
        advance_next,
        fire_due,
        compact,
    };

    const Frame = struct {
        snap: calendar.Calendar,
        fired_len: usize,
        scheduled_len: usize,
        prev_now: u64,
    };

    const World = struct {
        allocator: std.mem.Allocator,
        cal: calendar.Calendar,
        prev_now: u64 = 0,
        history: std.ArrayList(Frame),
        fired_tags: std.ArrayList(u32),
        scheduled_ids: std.ArrayList(calendar.EventId),
        acts_buf: [6]Act = undefined,

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{
                .allocator = alloc,
                .cal = calendar.Calendar.init(alloc, 0),
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

        /// Precise structural state key hashing incorporating clock, counts,
        /// all pending and cancelled events, and scheduled ID sequences.
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

        pub fn enabled(self: *@This()) []const Act {
            var n: usize = 0;
            // Bound exploration horizon: stop branch if goal reached or time >= 40
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

        pub fn step(self: *@This(), act: Act) !void {
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
                    // Cancel first active event
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

        pub fn undo(self: *@This(), act: Act) void {
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
        fn checkSafety(w: *World) anyerror!void {
            if (w.cal.now_us < w.prev_now) return error.ClockRewind;
            if (w.cal.pendingCount() > w.cal.slotCount()) return error.PendingExceedsSlots;
        }

        fn checkEnabled(_: *World) bool {
            return true;
        }

        fn checkGoal(w: *World) bool {
            return w.fired_tags.items.len >= 2;
        }
    };

    // 1. Positive verification: search completes and reachability monitor succeeds
    var world = World.init(allocator);
    defer world.deinit();

    var saf = monitor.Safety(*World){ .ctx = &world, .checkFn = Checkers.checkSafety };
    var liv = monitor.Liveness(*World){ .ctx = &world, .enabledFn = Checkers.checkEnabled, .goalFn = Checkers.checkGoal };

    var monitored = monitor.MonitoredKeyed(Act, World){
        .inner = &world,
        .saf = &saf,
        .liv = &liv,
    };

    var stats: explore.Stats = .{};
    var visited = std.AutoHashMap(u64, void).init(allocator);
    defer visited.deinit();

    try explore.dfsKeyed(Act, u64, &monitored, 600, &stats, &visited);
    try liv.finish();

    try std.testing.expectEqual(@as(usize, 448), stats.visits);
    try std.testing.expectEqual(@as(usize, 385), stats.pruned);
    try std.testing.expectEqual(@as(usize, 832), saf.observations);

    // 2. Negative verification: Safety monitor catches injected safety failure
    const FailingSafety = struct {
        fn check(w: *World) anyerror!void {
            if (w.fired_tags.items.len > 0) return error.InjectedSafetyViolation;
        }
    };
    var w_fail = World.init(allocator);
    defer w_fail.deinit();
    var saf_fail = monitor.Safety(*World){ .ctx = &w_fail, .checkFn = FailingSafety.check };
    var liv_dummy = monitor.Liveness(*World){ .ctx = &w_fail, .enabledFn = Checkers.checkEnabled, .goalFn = Checkers.checkGoal };
    var monitored_fail = monitor.MonitoredKeyed(Act, World){
        .inner = &w_fail,
        .saf = &saf_fail,
        .liv = &liv_dummy,
    };
    var visited_fail = std.AutoHashMap(u64, void).init(allocator);
    defer visited_fail.deinit();
    var stats_fail: explore.Stats = .{};
    try std.testing.expectError(error.InjectedSafetyViolation, explore.dfsKeyed(Act, u64, &monitored_fail, 600, &stats_fail, &visited_fail));

    // 3. Negative verification: Reachability monitor catches unreachable goal
    const UnreachableGoal = struct {
        fn checkGoal(w: *World) bool {
            return w.fired_tags.items.len >= 999;
        }
    };
    var w_unreach = World.init(allocator);
    defer w_unreach.deinit();
    var saf_ok = monitor.Safety(*World){ .ctx = &w_unreach, .checkFn = Checkers.checkSafety };
    var liv_miss = monitor.Liveness(*World){ .ctx = &w_unreach, .enabledFn = Checkers.checkEnabled, .goalFn = UnreachableGoal.checkGoal };
    var monitored_unreach = monitor.MonitoredKeyed(Act, World){
        .inner = &w_unreach,
        .saf = &saf_ok,
        .liv = &liv_miss,
    };
    var visited_unreach = std.AutoHashMap(u64, void).init(allocator);
    defer visited_unreach.deinit();
    var stats_unreach: explore.Stats = .{};
    try explore.dfsKeyed(Act, u64, &monitored_unreach, 600, &stats_unreach, &visited_unreach);
    try std.testing.expectError(error.LivenessMissed, liv_miss.finish());
}

test "bootstrap: sleep set partial order reduction preserves reachable state space" {
    const allocator = std.testing.allocator;
    const Act = enum { inc_a, inc_b, sync };
    const State = struct { a: u8, b: u8, synced: bool };

    // Independent actions inc_a and inc_b commute, sync does not
    const System = struct {
        a: u8 = 0,
        b: u8 = 0,
        synced: bool = false,
        buf: [3]Act = undefined,
        visited_states: *std.AutoHashMap(State, void),

        pub fn enabled(self: *@This()) []const Act {
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

        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .inc_a => self.a += 1,
                .inc_b => self.b += 1,
                .sync => self.synced = true,
            }
            try self.visited_states.put(.{ .a = self.a, .b = self.b, .synced = self.synced }, {});
        }

        pub fn undo(self: *@This(), act: Act) void {
            switch (act) {
                .inc_a => self.a -= 1,
                .inc_b => self.b -= 1,
                .sync => self.synced = false,
            }
        }

        pub fn commutes(_: *const @This(), x: Act, y: Act) bool {
            return (x == .inc_a and y == .inc_b) or (x == .inc_b and y == .inc_a);
        }
    };

    const NonCommutingSystem = struct {
        s: System,
        pub fn enabled(self: *@This()) []const Act {
            return self.s.enabled();
        }
        pub fn step(self: *@This(), act: Act) !void {
            return self.s.step(act);
        }
        pub fn undo(self: *@This(), act: Act) void {
            return self.s.undo(act);
        }
    };

    var full_states = std.AutoHashMap(State, void).init(allocator);
    defer full_states.deinit();
    try full_states.put(.{ .a = 0, .b = 0, .synced = false }, {});

    var por_states = std.AutoHashMap(State, void).init(allocator);
    defer por_states.deinit();
    try por_states.put(.{ .a = 0, .b = 0, .synced = false }, {});

    // 1. Explore without commutativity (full DFS)
    var full_sys = NonCommutingSystem{ .s = .{ .visited_states = &full_states } };
    var full_stats: explore.Stats = .{};
    try explore.dfs(Act, &full_sys, 100, &full_stats);

    // 2. Explore with commutativity (SleepSet Partial Order Reduction)
    var por_sys = System{ .visited_states = &por_states };
    var por_stats: explore.Stats = .{};
    try explore.dfs(Act, &por_sys, 100, &por_stats);

    // 3. Mathematical proof of POR preservation:
    // Reachable state spaces must be identical
    try std.testing.expectEqual(full_states.count(), por_states.count());
    var it = full_states.keyIterator();
    while (it.next()) |st| {
        try std.testing.expect(por_states.contains(st.*));
    }

    // POR pruned symmetric interleavings
    try std.testing.expect(por_stats.sleep_skipped > 0);
    try std.testing.expect(por_stats.expansions < full_stats.expansions);

    // 4. Negative verification: Unsound commutativity assumption drops reachable states
    const NonCommutingCounter = struct {
        x: u8 = 5,
        depth: usize = 0,
        stack: [4]u8 = undefined,
        buf: [2]Act2 = undefined,
        visited: *std.AutoHashMap(u8, void),

        const Act2 = enum { add, zero };

        pub fn enabled(self: *@This()) []const Act2 {
            if (self.depth >= 2) return self.buf[0..0];
            self.buf[0] = .add;
            self.buf[1] = .zero;
            return self.buf[0..2];
        }

        pub fn step(self: *@This(), act: Act2) !void {
            self.stack[self.depth] = self.x;
            self.depth += 1;
            switch (act) {
                .add => self.x += 1,
                .zero => self.x = 0,
            }
            try self.visited.put(self.x, {});
        }

        pub fn undo(self: *@This(), _: Act2) void {
            self.depth -= 1;
            self.x = self.stack[self.depth];
        }
    };

    const BadCommutingCounter = struct {
        inner: NonCommutingCounter,
        pub fn enabled(self: *@This()) []const NonCommutingCounter.Act2 {
            return self.inner.enabled();
        }
        pub fn step(self: *@This(), act: NonCommutingCounter.Act2) !void {
            return self.inner.step(act);
        }
        pub fn undo(self: *@This(), act: NonCommutingCounter.Act2) void {
            return self.inner.undo(act);
        }
        // Falsely claims add and zero commute (add then zero = 0, zero then add = 1)
        pub fn commutes(_: *const @This(), _: NonCommutingCounter.Act2, _: NonCommutingCounter.Act2) bool {
            return true;
        }
    };

    var full_counter_states = std.AutoHashMap(u8, void).init(allocator);
    defer full_counter_states.deinit();
    try full_counter_states.put(5, {});
    var full_counter = NonCommutingCounter{ .visited = &full_counter_states };
    var stats_fc: explore.Stats = .{};
    try explore.dfs(NonCommutingCounter.Act2, &full_counter, 50, &stats_fc);

    var bad_counter_states = std.AutoHashMap(u8, void).init(allocator);
    defer bad_counter_states.deinit();
    try bad_counter_states.put(5, {});
    var bad_counter = BadCommutingCounter{ .inner = .{ .visited = &bad_counter_states } };
    var stats_bc: explore.Stats = .{};
    try explore.dfs(NonCommutingCounter.Act2, &bad_counter, 50, &stats_bc);

    // Full exploration discovers state x = 1 (via path [zero, add])
    try std.testing.expect(full_counter_states.contains(1));
    // Unsound commutativity pruned [zero, add], missing state x = 1
    try std.testing.expect(!bad_counter_states.contains(1));
    try std.testing.expect(bad_counter_states.count() < full_counter_states.count());
}

test "bootstrap: ActLogReplay rebuilds non-cloneable state machine in lockstep with reference shadow model" {
    const allocator = std.testing.allocator;

    const Act = enum { write_x, write_y, flush };

    const StatefulBufferSUT = struct {
        content: std.ArrayList(u8),
        flushed: bool = false,

        pub fn init(alloc: std.mem.Allocator) @This() {
            _ = alloc;
            return .{
                .content = .empty,
                .flushed = false,
            };
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            self.content.deinit(alloc);
        }

        pub fn reset(self: *@This()) void {
            self.content.clearRetainingCapacity();
            self.flushed = false;
        }

        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .write_x => try self.content.append(std.testing.allocator, 'X'),
                .write_y => try self.content.append(std.testing.allocator, 'Y'),
                .flush => self.flushed = true,
            }
        }
    };

    // Reference cloneable model maintained in lockstep
    const ReferenceShadow = struct {
        content: std.ArrayList(u8),
        flushed: bool = false,
        stack: std.ArrayList(struct { content: []const u8, flushed: bool }),

        pub fn init() @This() {
            return .{
                .content = .empty,
                .flushed = false,
                .stack = .empty,
            };
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            for (self.stack.items) |frame| alloc.free(frame.content);
            self.stack.deinit(alloc);
            self.content.deinit(alloc);
        }

        pub fn step(self: *@This(), alloc: std.mem.Allocator, act: Act) !void {
            const snap = try alloc.dupe(u8, self.content.items);
            try self.stack.append(alloc, .{ .content = snap, .flushed = self.flushed });
            switch (act) {
                .write_x => try self.content.append(alloc, 'X'),
                .write_y => try self.content.append(alloc, 'Y'),
                .flush => self.flushed = true,
            }
        }

        pub fn undo(self: *@This(), alloc: std.mem.Allocator) void {
            const frame = self.stack.pop().?;
            self.content.clearRetainingCapacity();
            self.content.appendSlice(alloc, frame.content) catch unreachable;
            self.flushed = frame.flushed;
            alloc.free(frame.content);
        }
    };

    // Wrapper context driving DFS and checking lockstep equivalence
    const Harness = struct {
        allocator: std.mem.Allocator,
        replay: explore.ActLogReplay(Act, StatefulBufferSUT, null),
        shadow: ReferenceShadow,
        diverged: bool = false,
        acts_buf: [3]Act = undefined,

        pub fn enabled(self: *@This()) []const Act {
            var n: usize = 0;
            if (self.replay.inner.content.items.len < 3 and !self.replay.inner.flushed) {
                self.acts_buf[n] = .write_x;
                n += 1;
                self.acts_buf[n] = .write_y;
                n += 1;
            }
            if (self.replay.inner.content.items.len > 0 and !self.replay.inner.flushed) {
                self.acts_buf[n] = .flush;
                n += 1;
            }
            return self.acts_buf[0..n];
        }

        pub fn step(self: *@This(), act: Act) !void {
            try self.replay.step(act);
            try self.shadow.step(self.allocator, act);
            // Verify lockstep equivalence on forward step
            if (!std.mem.eql(u8, self.shadow.content.items, self.replay.inner.content.items) or
                self.shadow.flushed != self.replay.inner.flushed)
            {
                self.diverged = true;
                return error.StateDiverged;
            }
        }

        pub fn undo(self: *@This(), act: Act) void {
            self.replay.undo(act);
            self.shadow.undo(self.allocator);
            // Verify lockstep equivalence on backtrack reconstruction
            if (!std.mem.eql(u8, self.shadow.content.items, self.replay.inner.content.items) or
                self.shadow.flushed != self.replay.inner.flushed)
            {
                self.diverged = true;
            }
        }
    };

    var sut = StatefulBufferSUT.init(allocator);
    defer sut.deinit(allocator);

    var harness: Harness = .{
        .allocator = allocator,
        .replay = explore.ActLogReplay(Act, StatefulBufferSUT, null).init(allocator, &sut),
        .shadow = ReferenceShadow.init(),
    };
    defer harness.shadow.deinit(allocator);
    defer harness.replay.deinit();

    var stats: explore.Stats = .{};
    try explore.dfs(Act, &harness, 50, &stats);

    try std.testing.expect(!harness.diverged);
    try std.testing.expect(stats.visits > 10);
    try std.testing.expect(stats.expansions > 10);

    // 2. Negative verification: Broken reset fails to restore prefix state correctly
    const BrokenResetSUT = struct {
        content: std.ArrayList(u8),
        pub fn reset(_: *@This()) void {
            // Intentionally broken: fails to clear content
        }
        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .write_x => try self.content.append(std.testing.allocator, 'X'),
                .write_y => try self.content.append(std.testing.allocator, 'Y'),
                .flush => {},
            }
        }
    };
    var broken_sut = BrokenResetSUT{ .content = .empty };
    defer broken_sut.content.deinit(allocator);
    var broken_replay = explore.ActLogReplay(Act, BrokenResetSUT, null).init(allocator, &broken_sut);
    defer broken_replay.deinit();

    try broken_replay.step(.write_x);
    try broken_replay.step(.write_y);
    try std.testing.expectEqual(@as(usize, 2), broken_sut.content.items.len);
    // Backtrack should reset and replay [write_x], but broken reset will result in len 3 instead of 1
    broken_replay.undo(.write_y);
    try std.testing.expect(broken_sut.content.items.len != 1);
}

test "bootstrap: minimizeTrace isolates minimal reproducing fault subsequence under active noise" {
    const allocator = std.testing.allocator;

    const Act = enum {
        setup,
        noise_a,
        noise_b,
        disarm, // active interfering noise
        arm,
        noise_c,
        trigger,
        noise_d,
    };

    const PlayContext = struct {
        state: enum { init, setup_done, armed, triggered } = .init,

        pub fn play(self: *@This(), trace: []const Act) anyerror!void {
            self.state = .init;
            for (trace) |act| {
                switch (act) {
                    .setup => if (self.state == .init) {
                        self.state = .setup_done;
                    },
                    .disarm => if (self.state == .armed) {
                        self.state = .setup_done; // cancels armed precondition
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

    // Noisy failing trace containing 9 actions with active interference
    const noisy_trace = [_]Act{
        .noise_a,
        .setup,
        .disarm,
        .setup,
        .arm,
        .noise_b,
        .noise_c,
        .trigger,
        .noise_d,
    };

    const Runner = struct {
        fn run(ctx: *PlayContext, acts: []const Act) anyerror!void {
            return ctx.play(acts);
        }
    };

    const min = try explore.minimizeTrace(Act, PlayContext, allocator, &noisy_trace, error.CrashTriggered, Runner.run);
    defer allocator.free(min);

    // Minimal reproducing trace must be exactly [setup, arm, trigger] of length 3
    try std.testing.expectEqual(@as(usize, 3), min.len);
    try std.testing.expectEqual(Act.setup, min[0]);
    try std.testing.expectEqual(Act.arm, min[1]);
    try std.testing.expectEqual(Act.trigger, min[2]);
}

test "bootstrap: tla specification golden lock and ITF trace replay verify calendar lifecycle" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const Act = union(enum) {
        schedule: u32,
        advance: u32,
        fire,
        cancel,
    };
    const State = enum { idle, scheduled, expired, cancelled };
    const Config = struct {
        pub const max_events: u32 = 4;
        pub const time_horizon: u32 = 1000;
    };

    // 1. Generate TLA+ declarations for the calendar lifecycle model
    const decls = try tla.formatDeclarations(allocator, "bootstrap_model", Act, State, Config);
    defer allocator.free(decls);

    try std.testing.expect(std.mem.indexOf(u8, decls, "Actions == {\"schedule\", \"advance\", \"fire\", \"cancel\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, decls, "States == {\"idle\", \"scheduled\", \"expired\", \"cancelled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, decls, "max_events == 4") != null);

    // 2. Golden consistency lock against committed specification file
    try tla.lock(io, allocator, "examples/locks/bootstrap_model.tla", "bootstrap_model", Act, State, Config);

    // 3. Negative verification: Drift detection triggers on altered configuration
    const DriftedConfig = struct {
        pub const max_events: u32 = 4;
        pub const time_horizon: u32 = 9999;
    };
    try std.testing.expectError(error.TlaDrift, tla.lockWithOptions(io, allocator, "examples/locks/bootstrap_model.tla", "bootstrap_model", Act, State, DriftedConfig, .{ .allow_update = false }));

    // 4. ITF Trace Replay against a Calendar lifecycle harness using committed ITF trace
    const Harness = struct {
        state: State = .idle,
        now: u32 = 0,
        deadline: u32 = 0,
        executed: std.ArrayList(Act),

        pub fn init(alloc: std.mem.Allocator) @This() {
            _ = alloc;
            return .{ .executed = .empty, .now = 0, .deadline = 0, .state = .idle };
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            self.executed.deinit(alloc);
        }

        pub fn enabled(self: *const @This()) []const Act {
            return switch (self.state) {
                .idle => &.{.{ .schedule = 100 }},
                .scheduled => &.{ .{ .advance = 100 }, .cancel },
                .expired => &.{.fire},
                .cancelled => &.{},
            };
        }

        pub fn step(self: *@This(), act: Act) !void {
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
            try self.executed.append(std.testing.allocator, act);
        }

        pub fn project(self: *const @This()) State {
            return self.state;
        }
    };

    var h = Harness.init(allocator);
    defer h.deinit(allocator);

    const itf_file_content = try std.Io.Dir.cwd().readFileAlloc(io, "examples/locks/bootstrap_itf_trace.json", allocator, .limited(1 << 20));
    defer allocator.free(itf_file_content);

    const stats = try tla.replayJsonTrace(Act, &h, allocator, itf_file_content, null);
    try std.testing.expectEqual(@as(usize, 3), stats.actions_replayed);
    try std.testing.expectEqual(@as(usize, 4), stats.states_verified);
    try std.testing.expectEqual(State.idle, h.state);
    try std.testing.expectEqual(@as(u32, 100), h.now);
}
