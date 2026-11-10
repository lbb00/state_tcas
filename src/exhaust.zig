//! Exhaustive orders of a finite action list (unique permutations).
//!
//! Fixed finite actions; identical-action duplicates walked once. Invariants
//! after every step. Early stop (including limit 0) is `error.SearchIncomplete`.
//! Edges only on state change unless `keep_unchanged`. Sequence comes from one
//! story pass, not the exhaustive pass. Missing required states → `StateUnseen`.
//! Mermaid bytes must match the lock document (`Picture.lock` / `PictureDrift`).
//!
//! Use `orders` only when every unique permutation is legal. Constrained stories
//! (most perms illegal): call `play` / `Shell.play` for one sequence, or return
//! `error.SkipOrder` from `step`/`finish` so `orders` skips that perm and continues.
//! A hard error from `step` still fails the whole run.
//!
//! Order lifecycle: `prepare` → `step` (per action) → `finish` → `release`.
//! Prefer `finish` for Liveness-style goals; keep per-step checks for Safety.
//! Do not `release` if `prepare` failed. `publish` runs the pass, checks, Mermaid, and lock.
//! Ctx duck contract is verified by `verifyExhaust` (see `docs/harness.md#exhaust`).

const std = @import("std");
const picture = @import("picture.zig");

/// From `step` / `finish`: this permutation is illegal; `orders` skips it and
/// continues. Other errors still fail the whole run. Counted toward `limit`.
pub const SkipOrder = error{SkipOrder};

pub fn Unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

/// Comptime check that Ctx has prepare/step/finish/release. Called by `orders`.
pub fn verifyExhaust(comptime Act: type, comptime Ctx: type) void {
    _ = Act;
    const T = Unwrap(Ctx);
    if (!@hasDecl(T, "prepare")) @compileError("exhaust Ctx missing prepare; see docs/harness.md#exhaust");
    if (!@hasDecl(T, "step")) @compileError("exhaust Ctx missing step; see docs/harness.md#exhaust");
    if (!@hasDecl(T, "finish")) @compileError("exhaust Ctx missing finish; see docs/harness.md#exhaust");
    if (!@hasDecl(T, "release")) @compileError("exhaust Ctx missing release; see docs/harness.md#exhaust");
}

/// n! . Fails when the product does not fit in usize, so a wrapped count cannot look complete.
pub fn fact(n: usize) error{Overflow}!usize {
    var v: usize = 1;
    var i: usize = 2;
    while (i <= n) : (i += 1) v = try std.math.mul(usize, v, i);
    return v;
}

/// Skip duplicate permutations. Equality comparison uses `std.meta.eql`.
/// Note: Pointer and slice fields are compared by address and length rather than element contents.
pub fn skipSwap(comptime Act: type, acts: []const Act, n: usize, i: usize) bool {
    var j = n;
    while (j < i) : (j += 1) if (std.meta.eql(acts[j], acts[i])) return true;
    return false;
}

pub fn Shell(comptime Act: type, comptime Ctx: type) type {
    return struct {
        pub fn play(ctx: Ctx, acts: []const Act, pic: ?*picture.Picture) !void {
            try ctx.prepare();
            defer ctx.release();
            // Check after each step. The invariant lives in step, not at the end of the order.
            for (acts) |act| try ctx.step(act, pic);
            try ctx.finish(acts);
        }

        pub fn walk(acts: []Act, n: usize, visits: *usize, limit: usize, ctx: Ctx, pic: ?*picture.Picture) !void {
            if (n == acts.len) {
                visits.* += 1;
                // A limit of 0 is already exceeded by the first completed order, so that order is not run.
                if (visits.* > limit) return error.SearchIncomplete;
                @This().play(ctx, acts, pic) catch |err| {
                    // Illegal perm: skip and keep walking. Still counted toward limit.
                    if (err == error.SkipOrder) return;
                    return err;
                };
                return;
            }
            var i = n;
            while (i < acts.len) : (i += 1) {
                if (skipSwap(Act, acts, n, i)) continue;
                std.mem.swap(Act, &acts[n], &acts[i]);
                try walk(acts, n + 1, visits, limit, ctx, pic);
                std.mem.swap(Act, &acts[n], &acts[i]);
            }
        }
    };
}

pub fn orders(comptime Act: type, comptime n: usize, seed: [n]Act, limit: usize, ctx: anytype, pic: ?*picture.Picture) !usize {
    verifyExhaust(Act, @TypeOf(ctx));
    var acts = seed;
    var visits: usize = 0;
    try Shell(Act, @TypeOf(ctx)).walk(&acts, 0, &visits, limit, ctx, pic);
    return visits;
}

/// Run one fixed action sequence (prepare → step* → finish → release).
/// Prefer this (or `publish`'s `story`) when most permutations would be illegal;
/// use `orders` when every unique perm should succeed.
pub fn play(comptime Act: type, ctx: anytype, acts: []const Act, pic: ?*picture.Picture) !void {
    verifyExhaust(Act, @TypeOf(ctx));
    try Shell(Act, @TypeOf(ctx)).play(ctx, acts, pic);
}

pub fn render(
    allocator: std.mem.Allocator,
    preamble: []const u8,
    actor: []const u8,
    target: []const u8,
    comptime Act: type,
    comptime n: usize,
    seed: [n]Act,
    story: []const Act,
    expected: usize,
    must: []const []const u8,
    ctx: anytype,
) ![]u8 {
    var edges = picture.Picture{ .record_steps = false };
    defer edges.deinit(allocator);
    const visits = try orders(Act, n, seed, std.math.maxInt(usize), ctx, &edges);
    if (visits != expected) return error.SearchIncomplete;
    if (edges.unseen(must)) |_| return error.StateUnseen;
    edges.steps.deinit(allocator);
    edges.steps = .empty;
    var seq = picture.Picture{ .record_edges = false };
    defer seq.deinit(allocator);
    try Shell(Act, @TypeOf(ctx)).play(ctx, story, &seq);
    seq.edges.deinit(allocator);
    seq.edges = edges.edges;
    edges.edges = .empty;
    return seq.render(allocator, preamble, actor, target);
}

pub fn publish(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    preamble: []const u8,
    actor: []const u8,
    target: []const u8,
    comptime Act: type,
    comptime n: usize,
    seed: [n]Act,
    story: []const Act,
    expected: usize,
    must: []const []const u8,
    ctx: anytype,
) ![]u8 {
    const text = try render(allocator, preamble, actor, target, Act, n, seed, story, expected, must, ctx);
    errdefer allocator.free(text);
    try picture.lock(io, allocator, path, text);
    return text;
}

test "factorial overflow is an error" {
    const too_big: usize = if (@bitSizeOf(usize) >= 64) 21 else 13;
    try std.testing.expectError(error.Overflow, fact(too_big));
    const fits = try fact(too_big - 1);
    try std.testing.expect(fits > 1);
}

test "orders limit 0 is SearchIncomplete" {
    const Act = enum { a, b };
    const Ctx = struct {
        n: usize = 0,
        pub fn prepare(self: *@This()) !void {
            self.n = 0;
        }
        pub fn release(_: *@This()) void {}
        pub fn step(self: *@This(), _: Act, _: ?*@import("picture.zig").Picture) !void {
            self.n += 1;
        }
        pub fn finish(_: *@This(), _: []const Act) !void {}
    };
    var ctx: Ctx = .{};
    const seed = [_]Act{ .a, .b };
    try std.testing.expectError(error.SearchIncomplete, orders(Act, 2, seed, 0, &ctx, null));
}

test "orders empty seed visits once" {
    const Act = enum { a };
    const Ctx = struct {
        prepared: bool = false,
        pub fn prepare(self: *@This()) !void {
            self.prepared = true;
        }
        pub fn release(_: *@This()) void {}
        pub fn step(_: *@This(), _: Act, _: ?*@import("picture.zig").Picture) !void {
            unreachable;
        }
        pub fn finish(_: *@This(), _: []const Act) !void {}
    };
    var ctx: Ctx = .{};
    const seed = [_]Act{};
    const visits = try orders(Act, 0, seed, 8, &ctx, null);
    try std.testing.expectEqual(@as(usize, 1), visits);
    try std.testing.expect(ctx.prepared);
}

test "orders dedupes duplicate identical actions" {
    const Act = enum { x, y };
    const Ctx = struct {
        plays: usize = 0,
        pub fn prepare(_: *@This()) !void {}
        pub fn release(_: *@This()) void {}
        pub fn step(_: *@This(), _: Act, _: ?*@import("picture.zig").Picture) !void {}
        pub fn finish(self: *@This(), _: []const Act) !void {
            self.plays += 1;
        }
    };
    var ctx: Ctx = .{};
    const seed = [_]Act{ .x, .x, .y };
    const visits = try orders(Act, 3, seed, 64, &ctx, null);
    try std.testing.expectEqual(@as(usize, 3), visits);
    try std.testing.expectEqual(@as(usize, 3), ctx.plays);
}

test "orders SkipOrder skips illegal perm without failing run" {
    const Act = enum { a, b };
    const Ctx = struct {
        plays_ok: usize = 0,
        skipped: usize = 0,
        pub fn prepare(_: *@This()) !void {}
        pub fn release(_: *@This()) void {}
        pub fn step(self: *@This(), act: Act, _: ?*@import("picture.zig").Picture) !void {
            // Only a-then-b is legal; b-first → SkipOrder.
            _ = self;
            _ = act;
        }
        pub fn finish(self: *@This(), acts: []const Act) !void {
            if (acts.len == 2 and acts[0] == .b) {
                self.skipped += 1;
                return error.SkipOrder;
            }
            self.plays_ok += 1;
        }
    };
    var ctx: Ctx = .{};
    const seed = [_]Act{ .a, .b };
    const visits = try orders(Act, 2, seed, 64, &ctx, null);
    try std.testing.expectEqual(@as(usize, 2), visits);
    try std.testing.expectEqual(@as(usize, 1), ctx.plays_ok);
    try std.testing.expectEqual(@as(usize, 1), ctx.skipped);
}

test "play runs a single constrained story" {
    const Act = enum { a1, m1, a2 };
    const Ctx = struct {
        n: usize = 0,
        pub fn prepare(self: *@This()) !void {
            self.n = 0;
        }
        pub fn release(_: *@This()) void {}
        pub fn step(self: *@This(), _: Act, _: ?*@import("picture.zig").Picture) !void {
            self.n += 1;
        }
        pub fn finish(self: *@This(), acts: []const Act) !void {
            try std.testing.expectEqual(@as(usize, 3), acts.len);
            try std.testing.expectEqual(@as(usize, 3), self.n);
        }
    };
    var ctx: Ctx = .{};
    const story = [_]Act{ .a1, .m1, .a2 };
    try play(Act, &ctx, &story, null);
}

test "orders hard error from step fails whole run" {
    const Act = enum { a, b };
    const Ctx = struct {
        pub fn prepare(_: *@This()) !void {}
        pub fn release(_: *@This()) void {}
        pub fn step(_: *@This(), act: Act, _: ?*@import("picture.zig").Picture) !void {
            if (act == .b) return error.SafetyViolation;
        }
        pub fn finish(_: *@This(), _: []const Act) !void {}
    };
    var ctx: Ctx = .{};
    const seed = [_]Act{ .a, .b };
    try std.testing.expectError(error.SafetyViolation, orders(Act, 2, seed, 64, &ctx, null));
}

test "orders SkipOrder from step skips perm" {
    const Act = enum { a, b };
    const Ctx = struct {
        ok: usize = 0,
        skipped: usize = 0,
        saw_first: bool = false,
        pub fn prepare(self: *@This()) !void {
            self.saw_first = false;
        }
        pub fn release(_: *@This()) void {}
        pub fn step(self: *@This(), act: Act, _: ?*@import("picture.zig").Picture) !void {
            if (!self.saw_first) {
                self.saw_first = true;
                if (act == .b) {
                    self.skipped += 1;
                    return error.SkipOrder;
                }
            }
        }
        pub fn finish(self: *@This(), _: []const Act) !void {
            self.ok += 1;
        }
    };
    var ctx: Ctx = .{};
    const seed = [_]Act{ .a, .b };
    const visits = try orders(Act, 2, seed, 64, &ctx, null);
    try std.testing.expectEqual(@as(usize, 2), visits);
    try std.testing.expectEqual(@as(usize, 1), ctx.ok);
    try std.testing.expectEqual(@as(usize, 1), ctx.skipped);
}

test "orders SkipOrder burns tight limit before legal perm" {
    const Act = enum { a, b };
    const Ctx = struct {
        legal: usize = 0,
        skipped: usize = 0,
        pub fn prepare(_: *@This()) !void {}
        pub fn release(_: *@This()) void {}
        pub fn step(_: *@This(), _: Act, _: ?*@import("picture.zig").Picture) !void {}
        pub fn finish(self: *@This(), acts: []const Act) !void {
            // Heap's first completed leaf is a-then-b; Skip it so visits=1 burns
            // limit=1 and the later b-then-a legal leaf hits SearchIncomplete.
            if (acts.len == 2 and acts[0] == .a) {
                self.skipped += 1;
                return error.SkipOrder;
            }
            self.legal += 1;
        }
    };
    var ctx: Ctx = .{};
    const seed = [_]Act{ .a, .b };
    try std.testing.expectError(error.SearchIncomplete, orders(Act, 2, seed, 1, &ctx, null));
    try std.testing.expectEqual(@as(usize, 0), ctx.legal);
    try std.testing.expectEqual(@as(usize, 1), ctx.skipped);
}

test "render StateUnseen when must missing" {
    const Act = enum { a };
    const Ctx = struct {
        allocator: std.mem.Allocator,
        pub fn prepare(_: *@This()) !void {}
        pub fn release(_: *@This()) void {}
        pub fn step(self: *@This(), _: Act, pic: ?*@import("picture.zig").Picture) !void {
            if (pic) |p| {
                try p.observe(self.allocator, .{
                    .before = "idle",
                    .after = "done",
                    .label = "a",
                    .rejected = false,
                    .mutated = true,
                    .note = "done",
                });
            }
        }
        pub fn finish(_: *@This(), _: []const Act) !void {}
    };
    var ctx: Ctx = .{ .allocator = std.testing.allocator };
    const seed = [_]Act{.a};
    const story = [_]Act{.a};
    const must = [_][]const u8{ "idle", "done", "never_seen" };
    try std.testing.expectError(
        error.StateUnseen,
        render(std.testing.allocator, "", "A", "B", Act, 1, seed, &story, 1, &must, &ctx),
    );
}

test "render SearchIncomplete when visits mismatch expected" {
    const Act = enum { a, b };
    const Ctx = struct {
        pub fn prepare(_: *@This()) !void {}
        pub fn release(_: *@This()) void {}
        pub fn step(_: *@This(), _: Act, _: ?*@import("picture.zig").Picture) !void {}
        pub fn finish(_: *@This(), _: []const Act) !void {}
    };
    var ctx: Ctx = .{};
    const seed = [_]Act{ .a, .b };
    const story = [_]Act{ .a, .b };
    const must = [_][]const u8{};
    try std.testing.expectError(
        error.SearchIncomplete,
        render(std.testing.allocator, "", "A", "B", Act, 2, seed, &story, 99, &must, &ctx),
    );
}

test "orders supports tagged union Act with payload" {
    const Act = union(enum) {
        push: u32,
        pop,
    };
    const Ctx = struct {
        calls: usize = 0,
        orders_seen: usize = 0,
        seen_push_push_pop: bool = false,
        seen_push_pop_push: bool = false,
        seen_pop_push_push: bool = false,

        pub fn prepare(_: *@This()) !void {}
        pub fn release(_: *@This()) void {}
        pub fn step(self: *@This(), _: Act, _: ?*@import("picture.zig").Picture) !void {
            self.calls += 1;
        }
        pub fn finish(self: *@This(), acts: []const Act) !void {
            self.orders_seen += 1;
            if (acts[0] == .push and acts[1] == .push and acts[2] == .pop) self.seen_push_push_pop = true;
            if (acts[0] == .push and acts[1] == .pop and acts[2] == .push) self.seen_push_pop_push = true;
            if (acts[0] == .pop and acts[1] == .push and acts[2] == .push) self.seen_pop_push_push = true;
        }
    };
    var ctx: Ctx = .{};
    // 3 elements with a duplicate: push(1), push(1), pop -> unique permutations should be 3! / 2! = 3
    const seed = [_]Act{ .{ .push = 1 }, .{ .push = 1 }, .pop };
    _ = try orders(Act, 3, seed, 10, &ctx, null);
    try std.testing.expectEqual(@as(usize, 9), ctx.calls); // 3 orders * 3 steps each
    try std.testing.expectEqual(@as(usize, 3), ctx.orders_seen);
    try std.testing.expect(ctx.seen_push_push_pop);
    try std.testing.expect(ctx.seen_push_pop_push);
    try std.testing.expect(ctx.seen_pop_push_push);
}
