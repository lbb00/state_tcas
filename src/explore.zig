//! Bounded enabling-set exploration (BFS/DFS with visit budget).
//!
//! Unlike `exhaust.orders` (fixed list, n! permutations), this walks a graph
//! where the enabled set can change after each step. Hit the budget before the
//! frontier empties → `error.SearchIncomplete`. `dfsKeyed` / `bfs` prune on
//! visited keys; `shuffleSeeded` fixes enabling order. Not P Checker / `.p` DSL.
//! Each frame copies `enabled()` (`max_enabled`) so a shared harness buffer is
//! safe across recursion. Ctx ducks verified by `verifyDfs` / `verifyDfsKeyed` /
//! `verifyBfs` (see `docs/harness.md`).

const std = @import("std");

pub fn Unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

/// Comptime check: enabled/step/undo decls present. `undo` must be `void` at
/// the call site (explore cannot propagate undo errors); verify only checks
/// `@hasDecl`, not the return type. Called by `dfs`.
pub fn verifyDfs(comptime Act: type, comptime Ctx: type) void {
    _ = Act;
    const T = Unwrap(Ctx);
    if (!@hasDecl(T, "enabled")) @compileError("explore dfs Ctx missing enabled; see docs/harness.md#dfs");
    if (!@hasDecl(T, "step")) @compileError("explore dfs Ctx missing step; see docs/harness.md#dfs");
    if (!@hasDecl(T, "undo")) @compileError("explore dfs Ctx missing undo; see docs/harness.md#dfs");
}

/// Comptime check: dfs decls plus key. Called by `dfsKeyed`.
pub fn verifyDfsKeyed(comptime Act: type, comptime Key: type, comptime Ctx: type) void {
    _ = Key;
    verifyDfs(Act, Ctx);
    const T = Unwrap(Ctx);
    if (!@hasDecl(T, "key")) @compileError("explore dfsKeyed Ctx missing key; see docs/harness.md#dfskeyed");
}

/// Comptime check: enabled/step/key/clone/destroy (no undo). Called by `bfs`.
pub fn verifyBfs(comptime Act: type, comptime Key: type, comptime Ctx: type) void {
    _ = Act;
    _ = Key;
    if (!@hasDecl(Ctx, "enabled")) @compileError("explore bfs Ctx missing enabled; see docs/harness.md#bfs");
    if (!@hasDecl(Ctx, "step")) @compileError("explore bfs Ctx missing step; see docs/harness.md#bfs");
    if (!@hasDecl(Ctx, "key")) @compileError("explore bfs Ctx missing key; see docs/harness.md#bfs");
    if (!@hasDecl(Ctx, "clone")) @compileError("explore bfs Ctx missing clone; see docs/harness.md#bfs");
    if (!@hasDecl(Ctx, "destroy")) @compileError("explore bfs Ctx missing destroy; see docs/harness.md#bfs");
}

pub const Stats = struct {
    visits: usize = 0,
    expansions: usize = 0,
    pruned: usize = 0,
};

/// Max length of one `enabled()` result copied per explore frame.
/// Shared/reusable harness buffers are safe up to this size; larger → `EnabledSetTooLarge`.
pub const max_enabled = 64;

fn copyEnabled(comptime Act: type, src: []const Act) error{EnabledSetTooLarge}!struct { buf: [max_enabled]Act, len: usize } {
    if (src.len > max_enabled) return error.EnabledSetTooLarge;
    var buf: [max_enabled]Act = undefined;
    @memcpy(buf[0..src.len], src);
    return .{ .buf = buf, .len = src.len };
}

/// Depth-first bounded explore with undo backtrack.
///
/// Ctx: `enabled` / `step` / `undo` (`undo` must be void; `verifyDfs` checks decl
/// presence — void is enforced by the `ctx.undo(act)` call site; docs/harness.md#dfs).
/// Each frame copies `enabled()` into a stack buffer (`max_enabled`) so a shared
/// harness `acts_buf` rewritten by child frames cannot corrupt the parent loop.
pub fn dfs(
    comptime Act: type,
    ctx: anytype,
    budget: usize,
    stats: *Stats,
) !void {
    verifyDfs(Act, @TypeOf(ctx));
    try dfsRec(Act, ctx, budget, stats);
}

fn dfsRec(
    comptime Act: type,
    ctx: anytype,
    budget: usize,
    stats: *Stats,
) !void {
    if (stats.visits >= budget) return error.SearchIncomplete;
    stats.visits += 1;
    // Copy enabled acts: recursive frames may rewrite the same harness buffer.
    const owned = try copyEnabled(Act, ctx.enabled());
    const acts = owned.buf[0..owned.len];
    if (acts.len == 0) return;
    for (acts) |act| {
        stats.expansions += 1;
        try ctx.step(act);
        try dfsRec(Act, ctx, budget, stats);
        ctx.undo(act);
    }
}

/// BFS explore with explicit state keys for pruning.
///
/// Ctx (value type): `enabled` / `step` / `key` / `clone` / `destroy`
/// (verified by `verifyBfs`; docs/harness.md#bfs). No `undo`.
pub fn bfs(
    comptime Act: type,
    comptime Key: type,
    comptime Ctx: type,
    root: Ctx,
    allocator: std.mem.Allocator,
    budget: usize,
    stats: *Stats,
) !void {
    verifyBfs(Act, Key, Ctx);
    var visited = std.AutoHashMap(Key, void).init(allocator);
    defer visited.deinit();

    var queue: std.ArrayList(Ctx) = .empty;
    // `head` is captured by defer: already-expanded nodes are destroyed inline;
    // only the not-yet-expanded suffix is freed here (avoids O(all-states) retain).
    var head: usize = 0;
    defer {
        for (queue.items[head..]) |*n| n.destroy();
        queue.deinit(allocator);
    }

    try visited.put(root.key(), {});
    try queue.append(allocator, try root.clone());
    stats.visits = 1;

    while (head < queue.items.len) {
        if (stats.visits > budget) return error.SearchIncomplete;
        var node = queue.items[head];
        head += 1;
        defer node.destroy();
        // Copy: sibling clones must not rewrite the slice we are iterating.
        const owned = try copyEnabled(Act, node.enabled());
        const acts = owned.buf[0..owned.len];
        for (acts) |act| {
            stats.expansions += 1;
            var child = try node.clone();
            errdefer child.destroy();
            try child.step(act);
            const k = child.key();
            if (visited.contains(k)) {
                stats.pruned += 1;
                child.destroy();
                continue;
            }
            try visited.put(k, {});
            stats.visits += 1;
            if (stats.visits > budget) {
                child.destroy();
                return error.SearchIncomplete;
            }
            try queue.append(allocator, child);
        }
    }
}

const FakeAct = enum { a, b, reset };

const Fake = struct {
    state: u8 = 0,

    pub fn enabled(self: *Fake) []const FakeAct {
        return switch (self.state) {
            0 => &[_]FakeAct{ .a, .b },
            1, 2 => &[_]FakeAct{.reset},
            else => &[_]FakeAct{},
        };
    }
    pub fn step(self: *Fake, act: FakeAct) !void {
        switch (act) {
            .a => self.state = 1,
            .b => self.state = 2,
            .reset => self.state = 0,
        }
    }
    pub fn key(self: *const Fake) u8 {
        return self.state;
    }
    pub fn clone(self: *const Fake) !Fake {
        return .{ .state = self.state };
    }
    pub fn destroy(self: *Fake) void {
        _ = self;
    }
};

test "dfs enabling explore walks changing enabled set" {
    const Acyclic = struct {
        state: u8 = 0,
        pub fn enabled(self: *@This()) []const FakeAct {
            return switch (self.state) {
                0 => &[_]FakeAct{ .a, .b },
                else => &[_]FakeAct{},
            };
        }
        pub fn step(self: *@This(), act: FakeAct) !void {
            switch (act) {
                .a => self.state = 1,
                .b => self.state = 2,
                .reset => {},
            }
        }
        pub fn undo(self: *@This(), act: FakeAct) void {
            switch (act) {
                .a, .b => self.state = 0,
                .reset => {},
            }
        }
    };
    var ac: Acyclic = .{};
    var stats: Stats = .{};
    try dfs(FakeAct, &ac, 16, &stats);
    try std.testing.expect(stats.visits >= 3);
    try std.testing.expectEqual(@as(usize, 2), stats.expansions);
}

test "bfs prunes revisited keys; budget yields SearchIncomplete" {
    const allocator = std.testing.allocator;
    const root: Fake = .{};
    var stats: Stats = .{};
    try bfs(FakeAct, u8, Fake, root, allocator, 64, &stats);
    try std.testing.expect(stats.visits >= 3);
    try std.testing.expect(stats.pruned >= 1);

    var stats2: Stats = .{};
    try std.testing.expectError(
        error.SearchIncomplete,
        bfs(FakeAct, u8, Fake, root, allocator, 1, &stats2),
    );
}
/// Deterministic Fisher–Yates shuffle (reproducible explore order).
pub fn shuffleSeeded(comptime T: type, items: []T, seed: u64) void {
    if (items.len < 2) return;
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var i: usize = items.len;
    while (i > 1) {
        i -= 1;
        const j = r.intRangeAtMost(usize, 0, i);
        const tmp = items[i];
        items[i] = items[j];
        items[j] = tmp;
    }
}

/// DFS with visited-key prune (in addition to budget).
/// Ctx: dfs decls plus `key` (`undo` void; verified by `verifyDfsKeyed`; docs/harness.md#dfskeyed).
/// A key is marked visited on entry. Undoing then reaching the same key via
/// another path prunes — state-keyed, not path-keyed.
pub fn dfsKeyed(
    comptime Act: type,
    comptime Key: type,
    ctx: anytype,
    budget: usize,
    stats: *Stats,
    visited: *std.AutoHashMap(Key, void),
) !void {
    verifyDfsKeyed(Act, Key, @TypeOf(ctx));
    try dfsKeyedRec(Act, Key, ctx, budget, stats, visited);
}

fn dfsKeyedRec(
    comptime Act: type,
    comptime Key: type,
    ctx: anytype,
    budget: usize,
    stats: *Stats,
    visited: *std.AutoHashMap(Key, void),
) !void {
    if (stats.visits >= budget) return error.SearchIncomplete;
    const k = ctx.key();
    if (visited.contains(k)) {
        stats.pruned += 1;
        return;
    }
    try visited.put(k, {});
    stats.visits += 1;
    // Copy enabled acts: recursive frames may rewrite the same harness buffer.
    const owned = try copyEnabled(Act, ctx.enabled());
    const acts = owned.buf[0..owned.len];
    if (acts.len == 0) return;
    for (acts) |act| {
        stats.expansions += 1;
        try ctx.step(act);
        try dfsKeyedRec(Act, Key, ctx, budget, stats, visited);
        ctx.undo(act);
    }
}

test "shuffleSeeded is deterministic for same seed" {
    var a = [_]u8{ 1, 2, 3, 4, 5, 6 };
    var b = [_]u8{ 1, 2, 3, 4, 5, 6 };
    shuffleSeeded(u8, a[0..], 0xC0FFEE);
    shuffleSeeded(u8, b[0..], 0xC0FFEE);
    try std.testing.expectEqualSlices(u8, &a, &b);
    var c = [_]u8{ 1, 2, 3, 4, 5, 6 };
    shuffleSeeded(u8, c[0..], 0xBEEF);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}

test "dfsKeyed prunes revisited keys" {
    const ActK = enum { a, b };
    // Diamond: 0 -a→ 1 -a→ 3 ; 0 -b→ 2 -a→ 3 (second visit of 3 pruned).
    const Cyc = struct {
        state: u8 = 0,
        stack: [8]u8 = undefined,
        sp: usize = 0,
        pub fn enabled(self: *@This()) []const ActK {
            return switch (self.state) {
                0 => &[_]ActK{ .a, .b },
                1, 2 => &[_]ActK{.a},
                else => &[_]ActK{},
            };
        }
        pub fn step(self: *@This(), act: ActK) !void {
            self.stack[self.sp] = self.state;
            self.sp += 1;
            switch (act) {
                .a => self.state = if (self.state == 0) 1 else 3,
                .b => self.state = 2,
            }
        }
        pub fn undo(self: *@This(), act: ActK) void {
            _ = act;
            self.sp -= 1;
            self.state = self.stack[self.sp];
        }
        pub fn key(self: *const @This()) u8 {
            return self.state;
        }
    };
    var cyc: Cyc = .{};
    var stats: Stats = .{};
    var visited = std.AutoHashMap(u8, void).init(std.testing.allocator);
    defer visited.deinit();
    try dfsKeyed(ActK, u8, &cyc, 64, &stats, &visited);
    try std.testing.expect(stats.visits >= 3);
    try std.testing.expect(stats.pruned >= 1);
}

test "toy FSM: explore+monitor smoke" {
    // Acyclic idle→arm→fire machine + Safety/Liveness monitors.
    // Proves state_tcas harnesses any Zig SUT — package stays std-only.
    const monitor = @import("monitor.zig");
    const Act = enum { arm, fire };
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
            // Observables must restore with phase — sticky saw_fire is a footgun.
            if (act == .fire) self.saw_fire = false;
        }
        pub fn safetyOk(ctx: *@This()) !void {
            // Never arm after done without undo restoring phase first.
            if (ctx.phase == .done and !ctx.saw_fire) return error.SafetyViolation;
        }
        pub fn isEnabled(ctx: *@This()) bool {
            _ = ctx;
            return true;
        }
        pub fn isGoal(ctx: *@This()) bool {
            return ctx.saw_fire;
        }
    };

    var toy: Toy = .{};
    var saf = monitor.Safety(*Toy){ .ctx = &toy, .checkFn = Toy.safetyOk };
    var liv = monitor.Liveness(*Toy){
        .ctx = &toy,
        .enabledFn = Toy.isEnabled,
        .goalFn = Toy.isGoal,
    };

    const Wrapped = struct {
        inner: *Toy,
        saf: *monitor.Safety(*Toy),
        liv: *monitor.Liveness(*Toy),
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
    var stats: Stats = .{};
    try dfs(Act, &wrap, 16, &stats);
    try liv.finish();
    // DFS undoes back to idle; goal is sticky on the monitor, not the SUT bit.
    try std.testing.expect(!toy.saw_fire);
    try std.testing.expect(liv.reached);
    try std.testing.expect(stats.visits >= 3);
    try std.testing.expectEqual(@as(usize, 2), stats.expansions);
}

test "dfs copies enabled buffer across recursive frames" {
    // Regression: shared acts_buf rewritten in enabled() used to corrupt the
    // parent's for-loop slice while dfsRec was still iterating it.
    // Depth-1 overwrites BOTH slots with `.leaf`; without a per-frame copy the
    // parent's second iteration would see `.leaf` instead of `.right`.
    const Act = enum { left, right, leaf };
    const Ctx = struct {
        depth: u8 = 0,
        acts_buf: [4]Act = undefined,
        saw_right: bool = false,
        leaves: usize = 0,

        pub fn enabled(self: *@This()) []const Act {
            if (self.depth >= 2) return self.acts_buf[0..0];
            if (self.depth == 1) {
                self.acts_buf[0] = .leaf;
                self.acts_buf[1] = .leaf; // clobber sibling slot
                return self.acts_buf[0..1];
            }
            self.acts_buf[0] = .left;
            self.acts_buf[1] = .right;
            return self.acts_buf[0..2];
        }
        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .left => self.depth += 1,
                .right => {
                    self.saw_right = true;
                    self.depth += 1;
                },
                .leaf => {
                    self.leaves += 1;
                    self.depth += 1;
                },
            }
        }
        pub fn undo(self: *@This(), act: Act) void {
            _ = act;
            self.depth -= 1;
        }
    };
    var ctx: Ctx = .{};
    var stats: Stats = .{};
    try dfs(Act, &ctx, 64, &stats);
    try std.testing.expect(ctx.saw_right);
    try std.testing.expectEqual(@as(usize, 2), ctx.leaves);
    try std.testing.expectEqual(@as(usize, 4), stats.expansions);
}

test "dfs budget 0 is SearchIncomplete" {
    const Act = enum { a };
    const Ctx = struct {
        pub fn enabled(_: *@This()) []const Act {
            return &[_]Act{.a};
        }
        pub fn step(_: *@This(), _: Act) !void {}
        pub fn undo(_: *@This(), _: Act) void {}
    };
    var ctx: Ctx = .{};
    var stats: Stats = .{};
    try std.testing.expectError(error.SearchIncomplete, dfs(Act, &ctx, 0, &stats));
}

test "enabled set larger than max_enabled is EnabledSetTooLarge" {
    const Act = enum { a };
    const TooBig = struct {
        buf: [max_enabled + 1]Act = undefined,
        pub fn enabled(self: *@This()) []const Act {
            for (&self.buf) |*slot| slot.* = .a;
            return self.buf[0..];
        }
        pub fn step(_: *@This(), _: Act) !void {}
        pub fn undo(_: *@This(), _: Act) void {}
    };
    var ctx: TooBig = .{};
    var stats: Stats = .{};
    try std.testing.expectError(error.EnabledSetTooLarge, dfs(Act, &ctx, 8, &stats));

    // Boundary: exactly max_enabled succeeds (terminal leaf after one step).
    const Exact = struct {
        buf: [max_enabled]Act = undefined,
        depth: u8 = 0,
        pub fn enabled(self: *@This()) []const Act {
            if (self.depth > 0) return self.buf[0..0];
            for (&self.buf) |*slot| slot.* = .a;
            return self.buf[0..];
        }
        pub fn step(self: *@This(), _: Act) !void {
            self.depth += 1;
        }
        pub fn undo(self: *@This(), _: Act) void {
            self.depth -= 1;
        }
    };
    var exact: Exact = .{};
    var stats2: Stats = .{};
    try dfs(Act, &exact, 4096, &stats2);
    try std.testing.expectEqual(@as(usize, max_enabled), stats2.expansions);
}

test "dfsKeyed budget 0 is SearchIncomplete" {
    const Act = enum { a };
    const Ctx = struct {
        pub fn enabled(_: *@This()) []const Act {
            return &[_]Act{.a};
        }
        pub fn step(_: *@This(), _: Act) !void {}
        pub fn undo(_: *@This(), _: Act) void {}
        pub fn key(_: *const @This()) u8 {
            return 0;
        }
    };
    var ctx: Ctx = .{};
    var stats: Stats = .{};
    var visited = std.AutoHashMap(u8, void).init(std.testing.allocator);
    defer visited.deinit();
    try std.testing.expectError(error.SearchIncomplete, dfsKeyed(Act, u8, &ctx, 0, &stats, &visited));
}

test "liveness reached survives dfs undo" {
    const monitor = @import("monitor.zig");
    const Act = enum { go };
    const Box = struct {
        bit: bool = false,
        stack: [4]bool = undefined,
        sp: usize = 0,
        pub fn enabled(self: *@This()) []const Act {
            return if (!self.bit) &[_]Act{.go} else &[_]Act{};
        }
        pub fn step(self: *@This(), _: Act) !void {
            self.stack[self.sp] = self.bit;
            self.sp += 1;
            self.bit = true;
        }
        pub fn undo(self: *@This(), _: Act) void {
            self.sp -= 1;
            self.bit = self.stack[self.sp];
        }
        pub fn isEnabled(_: *@This()) bool {
            return true;
        }
        pub fn isGoal(ctx: *@This()) bool {
            return ctx.bit;
        }
    };
    var box: Box = .{};
    var liv = monitor.Liveness(*Box){
        .ctx = &box,
        .enabledFn = Box.isEnabled,
        .goalFn = Box.isGoal,
    };
    const Wrapped = struct {
        inner: *Box,
        liv: *monitor.Liveness(*Box),
        pub fn enabled(self: *@This()) []const Act {
            return self.inner.enabled();
        }
        pub fn step(self: *@This(), act: Act) !void {
            try self.inner.step(act);
            self.liv.note();
        }
        pub fn undo(self: *@This(), act: Act) void {
            self.inner.undo(act);
        }
    };
    var wrap: Wrapped = .{ .inner = &box, .liv = &liv };
    var stats: Stats = .{};
    try dfs(Act, &wrap, 8, &stats);
    try std.testing.expect(!box.bit);
    try std.testing.expect(liv.reached);
    try liv.finish();
}

test "branching FSM undo restores fire observable" {
    const Act = enum { arm, skip, fire };
    const Phase = enum { idle, armed, done, skipped };
    const Toy = struct {
        phase: Phase = .idle,
        saw_fire: bool = false,
        stack: [8]Phase = undefined,
        sp: usize = 0,
        pub fn enabled(self: *@This()) []const Act {
            return switch (self.phase) {
                .idle => &[_]Act{ .arm, .skip },
                .armed => &[_]Act{.fire},
                .done, .skipped => &[_]Act{},
            };
        }
        pub fn step(self: *@This(), act: Act) !void {
            self.stack[self.sp] = self.phase;
            self.sp += 1;
            switch (act) {
                .arm => self.phase = .armed,
                .skip => self.phase = .skipped,
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
    };
    var toy: Toy = .{};
    var stats: Stats = .{};
    try dfs(Act, &toy, 32, &stats);
    try std.testing.expectEqual(Phase.idle, toy.phase);
    try std.testing.expect(!toy.saw_fire);
    try std.testing.expect(stats.expansions >= 3);
}
