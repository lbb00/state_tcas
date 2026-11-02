//! Virtual clock and timed calendar (DES-lite).
//!
//! Virtual `now_us`, schedule/cancel, advanceTo / advanceBy, popDue / fireDue.
//! Entries are `Timed` (id/at_us/tag/payload). Same-time fire in insertion-seq
//! order. Cancelled slots stay until `compactCancelled` or a due `popDue`
//! removes them. No resource queues, parallel worlds, or wall-clock I/O.
//!
//! Clock never rewinds (`error.ClockRewind` from `advanceTo` / `advanceToNext`).
//! `advanceBy` uses checked add (`error.Overflow`) — wrapping would look like a
//! silent rewind. For `explore.dfs`, clone before a step and `resetTo` inside
//! void `undo` (`catch unreachable` when restore cannot allocate — see
//! docs/harness.md#calendar-explore), or keep advances on a linear / `exhaust`
//! path only.

const std = @import("std");

pub const EventId = u32;

/// Error set alias for `advanceTo` / `advanceToNext` rewinds (also `error.ClockRewind`).
pub const ClockRewind = error{ClockRewind};

pub const Timed = struct {
    id: EventId,
    at_us: u64,
    /// Opaque tag for the harness (e.g. timeout / deliver_held).
    tag: u32,
    /// Opaque payload (harness-defined).
    payload: u64 = 0,
    /// Insertion order for same-time tie-break (lower fires first).
    seq: u64,
    cancelled: bool = false,
};

pub const Calendar = struct {
    allocator: std.mem.Allocator,
    now_us: u64 = 0,
    next_id: EventId = 1,
    next_seq: u64 = 0,
    events: std.ArrayList(Timed) = .empty,

    pub fn init(allocator: std.mem.Allocator, start_us: u64) Calendar {
        return .{
            .allocator = allocator,
            .now_us = start_us,
        };
    }

    pub fn deinit(self: *Calendar) void {
        self.events.deinit(self.allocator);
    }

    /// Schedule an event at absolute `at_us`. Past-or-equal times are allowed
    /// and become immediately due on the next pop/fire.
    pub fn schedule(self: *Calendar, at_us: u64, tag: u32, payload: u64) !EventId {
        const id = self.next_id;
        self.next_id +%= 1;
        const seq = self.next_seq;
        self.next_seq +%= 1;
        try self.events.append(self.allocator, .{
            .id = id,
            .at_us = at_us,
            .tag = tag,
            .payload = payload,
            .seq = seq,
        });
        return id;
    }

    /// Cancel by id. Already-fired or unknown ids are no-ops (return false).
    pub fn cancel(self: *Calendar, id: EventId) bool {
        for (self.events.items) |*e| {
            if (e.id == id and !e.cancelled) {
                e.cancelled = true;
                return true;
            }
        }
        return false;
    }

    /// Advance by delta. Refuses wraparound (`error.Overflow`) so a huge delta
    /// cannot silently land below `now_us` (that would look like a rewind).
    pub fn advanceBy(self: *Calendar, delta_us: u64) error{Overflow}!void {
        self.now_us = try std.math.add(u64, self.now_us, delta_us);
    }

    /// Jump virtual clock forward. Rewinds are refused.
    pub fn advanceTo(self: *Calendar, t_us: u64) error{ClockRewind}!void {
        if (t_us < self.now_us) return error.ClockRewind;
        self.now_us = t_us;
    }

    fn dueIndex(self: *const Calendar) ?usize {
        var best: ?usize = null;
        for (self.events.items, 0..) |e, i| {
            if (e.cancelled) continue;
            if (e.at_us > self.now_us) continue;
            if (best) |b| {
                const be = self.events.items[b];
                if (e.at_us < be.at_us or (e.at_us == be.at_us and e.seq < be.seq)) {
                    best = i;
                }
            } else {
                best = i;
            }
        }
        return best;
    }

    pub fn peekDue(self: *const Calendar) ?Timed {
        const i = self.dueIndex() orelse return null;
        return self.events.items[i];
    }

    pub fn popDue(self: *Calendar) ?Timed {
        const i = self.dueIndex() orelse return null;
        return self.events.orderedRemove(i);
    }

    /// Fire all currently due events. `handler` is `fn (ctx, tag, payload) !void`.
    pub fn fireDue(
        self: *Calendar,
        ctx: anytype,
        comptime handler: fn (@TypeOf(ctx), u32, u64) anyerror!void,
    ) !usize {
        var n: usize = 0;
        while (self.popDue()) |e| {
            try handler(ctx, e.tag, e.payload);
            n += 1;
        }
        return n;
    }

    /// Advance to the next scheduled (non-cancelled) event time, or stay put.
    pub fn advanceToNext(self: *Calendar) error{ClockRewind}!bool {
        var soonest: ?u64 = null;
        for (self.events.items) |e| {
            if (e.cancelled) continue;
            if (e.at_us < self.now_us) continue;
            if (soonest == null or e.at_us < soonest.?) soonest = e.at_us;
        }
        if (soonest) |t| {
            try self.advanceTo(t);
            return true;
        }
        return false;
    }

    pub fn pendingCount(self: *const Calendar) usize {
        var n: usize = 0;
        for (self.events.items) |e| {
            if (!e.cancelled) n += 1;
        }
        return n;
    }

    /// Deep copy (same allocator). Call from explore `step` (fallible) before
    /// mutating; restore in void `undo` via `resetTo` (see docs/harness.md).
    pub fn clone(self: *const Calendar) !Calendar {
        var copy = Calendar.init(self.allocator, self.now_us);
        errdefer copy.deinit();
        copy.next_id = self.next_id;
        copy.next_seq = self.next_seq;
        try copy.events.appendSlice(self.allocator, self.events.items);
        return copy;
    }

    /// Replace this calendar's clock and slots with `saved` (same allocator).
    /// May allocate if live capacity < `saved` length. Explore `undo` is `void`:
    /// call from `undo` only as `resetTo(...) catch unreachable` when the harness
    /// has proven no alloc (usual clone-before-mutate Frame — docs/harness.md).
    pub fn resetTo(self: *Calendar, saved: *const Calendar) !void {
        // Caller must use the same allocator family as `saved` (typically `clone`).
        self.now_us = saved.now_us;
        self.next_id = saved.next_id;
        self.next_seq = saved.next_seq;
        self.events.clearRetainingCapacity();
        try self.events.appendSlice(self.allocator, saved.events.items);
    }

    /// Drop cancelled slots so cancel/reschedule churn does not grow without bound.
    /// Live events keep relative order. Call from harnesses that churn timers.
    pub fn compactCancelled(self: *Calendar) void {
        var w: usize = 0;
        for (self.events.items) |e| {
            if (e.cancelled) continue;
            self.events.items[w] = e;
            w += 1;
        }
        self.events.shrinkRetainingCapacity(w);
    }

    /// Total slots including cancelled (leak checks). Prefer `pendingCount` for live work.
    pub fn slotCount(self: *const Calendar) usize {
        return self.events.items.len;
    }
};

test "calendar schedule fireDue same-time order is insertion seq" {
    const allocator = std.testing.allocator;
    var cal = Calendar.init(allocator, 100);
    defer cal.deinit();

    _ = try cal.schedule(200, 1, 10);
    _ = try cal.schedule(200, 2, 20);
    _ = try cal.schedule(150, 3, 30);
    try cal.advanceTo(200);

    const Sink = struct {
        got: [3]u32 = undefined,
        n: usize = 0,
        fn on(self: *@This(), tag: u32, payload: u64) !void {
            _ = payload;
            self.got[self.n] = tag;
            self.n += 1;
        }
    };
    var sink: Sink = .{};
    const fired = try cal.fireDue(&sink, Sink.on);
    try std.testing.expectEqual(@as(usize, 3), fired);
    try std.testing.expectEqual(@as(u32, 3), sink.got[0]);
    try std.testing.expectEqual(@as(u32, 1), sink.got[1]);
    try std.testing.expectEqual(@as(u32, 2), sink.got[2]);
    try std.testing.expectEqual(@as(usize, 0), cal.pendingCount());
}

test "calendar cancel skips event; rewind refused" {
    const allocator = std.testing.allocator;
    var cal = Calendar.init(allocator, 0);
    defer cal.deinit();
    const id = try cal.schedule(50, 9, 0);
    try std.testing.expect(cal.cancel(id));
    try std.testing.expect(!cal.cancel(id));
    try cal.advanceTo(50);
    try std.testing.expect(cal.popDue() == null);
    try std.testing.expectError(error.ClockRewind, cal.advanceTo(10));
}

test "calendar advanceBy and advanceToNext" {
    const allocator = std.testing.allocator;
    var cal = Calendar.init(allocator, 0);
    defer cal.deinit();
    _ = try cal.schedule(1000, 1, 0);
    try cal.advanceBy(100);
    try std.testing.expectEqual(@as(u64, 100), cal.now_us);
    try std.testing.expect(try cal.advanceToNext());
    try std.testing.expectEqual(@as(u64, 1000), cal.now_us);
    const e = cal.popDue().?;
    try std.testing.expectEqual(@as(u32, 1), e.tag);
    try std.testing.expect(!(try cal.advanceToNext()));
}

test "calendar past-due is immediately poppable" {
    const allocator = std.testing.allocator;
    var cal = Calendar.init(allocator, 100);
    defer cal.deinit();
    _ = try cal.schedule(50, 7, 1);
    const e = cal.popDue().?;
    try std.testing.expectEqual(@as(u32, 7), e.tag);
    try std.testing.expect(!cal.cancel(9999));
}

test "calendar compactCancelled drops cancelled slots" {
    const allocator = std.testing.allocator;
    var cal = Calendar.init(allocator, 0);
    defer cal.deinit();
    const a = try cal.schedule(10, 1, 0);
    const b = try cal.schedule(20, 2, 0);
    _ = try cal.schedule(30, 3, 0);
    try std.testing.expect(cal.cancel(a));
    try std.testing.expect(cal.cancel(b));
    try std.testing.expectEqual(@as(usize, 3), cal.slotCount());
    try std.testing.expectEqual(@as(usize, 1), cal.pendingCount());
    cal.compactCancelled();
    try std.testing.expectEqual(@as(usize, 1), cal.slotCount());
    try std.testing.expectEqual(@as(usize, 1), cal.pendingCount());
}

test "calendar clone and resetTo restore clock and slots" {
    const allocator = std.testing.allocator;
    var cal = Calendar.init(allocator, 10);
    defer cal.deinit();
    _ = try cal.schedule(100, 1, 7);
    const id2 = try cal.schedule(200, 2, 8);
    var snap = try cal.clone();
    defer snap.deinit();

    try std.testing.expect(cal.cancel(id2));
    try cal.advanceTo(100);
    _ = cal.popDue();
    try std.testing.expectEqual(@as(usize, 0), cal.pendingCount());
    try std.testing.expectEqual(@as(u64, 100), cal.now_us);

    try cal.resetTo(&snap);
    try std.testing.expectEqual(@as(u64, 10), cal.now_us);
    try std.testing.expectEqual(@as(usize, 2), cal.pendingCount());
    try std.testing.expectEqual(@as(EventId, 3), cal.next_id);
}

test "calendar advanceBy overflow is refused" {
    const allocator = std.testing.allocator;
    var cal = Calendar.init(allocator, std.math.maxInt(u64) - 10);
    defer cal.deinit();
    try std.testing.expectError(error.Overflow, cal.advanceBy(11));
    try std.testing.expectEqual(std.math.maxInt(u64) - 10, cal.now_us);
    try cal.advanceBy(10);
    try std.testing.expectEqual(std.math.maxInt(u64), cal.now_us);
}

test "calendar clone/resetTo frame under explore.dfs" {
    const explore = @import("explore.zig");
    const allocator = std.testing.allocator;
    const Act = enum { schedule, fire };
    const Frame = struct {
        snap: Calendar,
        fired: usize,
    };
    const Ctx = struct {
        allocator: std.mem.Allocator,
        cal: Calendar,
        frames: std.ArrayList(Frame) = .empty,
        fired: usize = 0,
        acts_buf: [2]Act = undefined,

        pub fn enabled(self: *@This()) []const Act {
            if (self.cal.pendingCount() == 0 and self.fired == 0 and self.cal.now_us == 0) {
                self.acts_buf[0] = .schedule;
                return self.acts_buf[0..1];
            }
            if (self.cal.pendingCount() > 0) {
                self.acts_buf[0] = .fire;
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
                .schedule => _ = try self.cal.schedule(self.cal.now_us + 50, 1, 0),
                .fire => {
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
    var ctx: Ctx = .{
        .allocator = allocator,
        .cal = Calendar.init(allocator, 0),
    };
    defer {
        while (ctx.frames.pop()) |f| {
            var frame = f;
            frame.snap.deinit();
        }
        ctx.frames.deinit(allocator);
        ctx.cal.deinit();
    }
    var stats: explore.Stats = .{};
    try explore.dfs(Act, &ctx, 32, &stats);
    try std.testing.expectEqual(@as(u64, 0), ctx.cal.now_us);
    try std.testing.expectEqual(@as(usize, 0), ctx.fired);
    try std.testing.expectEqual(@as(usize, 0), ctx.cal.pendingCount());
    try std.testing.expect(stats.expansions >= 2);
}
