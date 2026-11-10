# Harness Ctx cookbook

Copy-paste ducks for `exhaust` / `explore`. Contracts are checked at the public
entry by `verifyExhaust` / `verifyDfs` / `verifyDfsKeyed` / `verifyBfs`
(`@compileError` names the missing decl). Keep `anytype`; no package-owned
mega-wrapper.

Pointer vs value: pass whatever your method receivers expect. Verify unwraps
one pointer layer for exhaust/dfs; bfs takes a value `Ctx` type parameter.
Methods must be `pub` — Zig `@hasDecl` only sees public decls (verify runs on
the duck type at the API edge).

## Exhaust {#exhaust}

`prepare` → `step(act, pic)` → `finish(acts)` → `release`.
Do not `release` if `prepare` failed. `pic` may be null.

**When to use what**

| Goal | API |
|------|-----|
| Every unique perm is legal | `exhaust.orders` |
| Only one (or a few) constrained stories | `exhaust.play` (or `Shell(Act, Ctx).play`) / `publish`'s `story` |
| Most perms illegal but you still want `orders` | Return `error.SkipOrder` from `step` or `finish`; other errors fail the run |

`orders` walks unique permutations. If `step` returns a hard error on an illegal
order, the **whole** run fails (and a low `limit` can surface as
`SearchIncomplete` while later perms remain). Prefer `play` for constrained
stories; use `SkipOrder` only when skipping that perm and continuing is what
you mean.

```zig
const Act = enum { a, b };
const ExhaustCtx = struct {
    // your SUT fields…
    pub fn prepare(self: *@This()) !void { self.* = .{}; }
    pub fn step(self: *@This(), act: Act, pic: ?*state_tcas.Picture) !void {
        _ = self; _ = act; _ = pic;
    }
    pub fn finish(self: *@This(), acts: []const Act) !void {
        _ = self; _ = acts;
    }
    pub fn release(self: *@This()) void { _ = self; }
};
// try st.exhaust.orders(Act, 2, .{ .a, .b }, limit, &ctx, pic);
// try st.exhaust.play(Act, &ctx, &[_]Act{ .a, .b }, pic);
```

## DFS {#dfs}

`enabled` / `step` / `undo`. No `key` / `clone` / `destroy`. Explore `step`
takes no picture arg.

`undo` is **`void`** (infallible). Explore calls it during backtrack and cannot
propagate an error from it. If restore needs allocation, do that work in
`step` (e.g. `clone` before mutate) and keep `undo` allocation-free, or
`catch unreachable` only when the harness has proven the restore cannot fail
(see [Calendar + explore](#calendar-explore)).

Each explore frame **copies** the `enabled()` slice into a stack buffer
(`explore.max_enabled`, currently 64). A shared `acts_buf` rewritten on every
`enabled()` call is safe across recursion; larger sets return
`error.EnabledSetTooLarge`. Static and comptime slices are fully supported.

```zig
const DfsCtx = struct {
    pub fn enabled(self: *@This()) []const Act { _ = self; return &.{}; }
    pub fn step(self: *@This(), act: Act) !void { _ = self; _ = act; }
    pub fn undo(self: *@This(), act: Act) void { _ = self; _ = act; }
};
```

## DFS keyed {#dfskeyed}

Same as DFS plus `key`. State-keyed prune on entry (not path-keyed). Same
enabled-slice copy as plain DFS.

The call site provides a caller-allocated `visited` map:

```zig
const DfsKeyedCtx = struct {
    // …enabled/step/undo as above…
    pub fn key(self: *const @This()) u64 { _ = self; return 0; }
};

var visited = std.AutoHashMap(u64, void).init(allocator);
defer visited.deinit();
var stats: st.explore.Stats = .{};
try st.explore.dfsKeyed(Act, u64, &ctx, budget, &stats, &visited);
```

## BFS {#bfs}

`enabled` / `step` / `key` / `clone` / `destroy`. **No** `undo`. `step` runs
on a clone, not the parent. Public API takes value `Ctx` + allocator for the
queue/map only. Enabled acts are copied per expansion for the same reason as DFS.

```zig
const BfsCtx = struct {
    pub fn enabled(self: *@This()) []const Act { _ = self; return &.{}; }
    pub fn step(self: *@This(), act: Act) !void { _ = self; _ = act; }
    pub fn key(self: *const @This()) u64 { _ = self; return 0; }
    pub fn clone(self: *const @This()) !@This() { return self.*; }
    pub fn destroy(self: *@This()) void { _ = self; }
};
```

## Calendar + explore {#calendar-explore}

`Calendar` refuses clock rewinds (`ClockRewind`). Pairing it with `explore.dfs`
means **you** snapshot the calendar; explore does not.

**Types that must match:**

| Call | Signature | Notes |
|------|-----------|--------|
| explore `undo` | `void` | Infallible; no `try` |
| `Calendar.clone` | `!Calendar` | May OOM — call from `step` |
| `Calendar.resetTo` | `!void` | May allocate if live capacity < snap len |

Do **not** put `try cal.resetTo(...)` inside `undo` — it does not typecheck.
In the usual Frame pattern (clone **before** mutate), the live list has already
grown, so `resetTo` to the smaller snap keeps capacity and does not allocate.
Then `catch unreachable` is honest for that harness (GPA tests, fixed arena,
or any setup where you have proven the restore). If you cannot prove it, keep
calendar advances on a linear path or under `exhaust` / `exhaust.play` only.

Copy-paste Frame stack:

```zig
const Frame = struct {
    snap: Calendar,
    // other undo state: phase, seq_len, …
};

const Ctx = struct {
    allocator: Allocator,
    cal: Calendar,
    frames: std.ArrayList(Frame) = .empty,
    // …

    pub fn enabled(self: *@This()) []const Act { /* … */ }

    pub fn step(self: *@This(), act: Act) !void {
        var snap = try self.cal.clone();
        // Transfer ownership into the frame stack (no errdefer after append).
        self.frames.append(self.allocator, .{ .snap = snap }) catch |err| {
            snap.deinit();
            return err;
        };
        // mutate self.cal (schedule / advance / fire) and apply `act` …
        _ = act;
    }

    pub fn undo(self: *@This(), act: Act) void {
        _ = act;
        var frame = self.frames.pop().?;
        // Proven no-alloc restore after clone-before-mutate (see table above).
        self.cal.resetTo(&frame.snap) catch unreachable;
        frame.snap.deinit();
    }
};

// After explore returns, drain any leftover frames (error path) then cal:
// while (ctx.frames.pop()) |*f| f.snap.deinit();
// ctx.frames.deinit(allocator);
// ctx.cal.deinit();
```

Runnable package example: `examples/toy_calendar_dfs.zig`
(`zig build example-calendar-dfs`).

`clone` failing in `step` aborts that branch (allowed). Only `undo` must stay
`void`.

## RAII / paired begin·end + explore {#raii-explore}

SUT APIs that are RAII (`begin` returns a handle; `end` / `deinit` releases)
do **not** need a package-level admit/release type. Map them onto the duck
you already have:

| Explore mode | RAII mapping |
|--------------|--------------|
| DFS / dfsKeyed | `step` = begin (or apply act); void `undo` = end / restore / rebuild |
| BFS | Only if the **whole** ctx (including what the handle owns) is `clone`able |

Discarding the begin handle and rebuilding Task / waiter / checkpoint on
`undo` is a valid harness if restore is observationally equal. Prefer an
explicit `undo` that ends the same instance when the SUT allows it.

Do **not** invent a second lifecycle parallel to exhaust's
`prepare`/`release` — that pair is for `orders`/`play` only.

### Paired begin↔end must be gated or keyed

If `enabled()` can return both `begin` and `end` (or toggles) with no
restriction, plain `dfs` oscillates until the budget dies. Fix in the
harness (package already has the tools):

1. **Gate:** enable `end` only while waiting; enable `begin` only while idle.
2. **`dfsKeyed`:** put the waiting bit (and other phase) in `key` so re-entry
   prunes.
3. Direct unit tests + `monitor.Safety` are fine **extra** coverage; they do
   not replace a correct enabling set.

`error.SkipOrder` is exhaust-only; do not expect it from explore.

### Empty work: do not enable

If a drain / checkpoint / pump would be a no-op (e.g. the work queue is
empty), **omit** that act from `enabled()`. An empty enabling set is a
terminal leaf — that is what explore expects.

## Act-log rebuild vs BFS {#act-log-vs-bfs}

`bfs` requires `clone` and `destroy` operations on a value-type context. For live reactors, drivers, or event loops with non-cloneable OS state, avoid constructing pseudo-clones.

Instead, use **action-log rebuild with DFS**:

1. Record acts along the active exploration branch (an action log).
2. On backtracking or branch divergence, rebuild the system state from a baseline origin and replay the recorded prefix.
3. Apply `dfs` or `dfsKeyed` with a defined visit budget.

### Using `explore.ActLogReplay` (Recommended)

`state_tcas` provides `explore.ActLogReplay` to eliminate manual log array and rollback boilerplate:

```zig
const Act = enum { tick, tock };

var sut: LiveSUT = .{}; // Implements enabled(), step(), and reset()
var replay = st.explore.ActLogReplay(Act, LiveSUT, null).init(allocator, &sut);
defer replay.deinit();

var stats: st.explore.Stats = .{};
try st.explore.dfs(Act, &replay, 64, &stats);
```

If your SUT uses a custom reset or replay routine, pass it as `RebuildFn` (`fn (*LiveSUT) void` or `fn (*LiveSUT, []const Act) void`). If `LiveSUT` exposes `key()` or `commutes()`, `ActLogReplay` forwards them transparently to support `dfsKeyed` and commutativity pruning.

### Manual Action-Log Pattern

Minimal reference implementation (replace `apply` and `boot` with your SUT APIs). Runnable example: [`examples/toy_act_log_dfs.zig`](../examples/toy_act_log_dfs.zig).

```zig
const Act = enum { tick, tock };

const Ctx = struct {
    // Origin + log[0..len] represents the reproducible state.
    log: [32]Act = undefined,
    len: usize = 0,
    phase: u8 = 0, // Rebuilt observable state
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
        if (self.len >= 2) return self.acts_buf[0..0]; // Depth bound
        self.acts_buf[0] = .tick;
        self.acts_buf[1] = .tock;
        return self.acts_buf[0..2];
    }
    pub fn step(self: *@This(), act: Act) !void {
        self.log[self.len] = act;
        self.len += 1;
        self.apply(act); // Or rebuild() if apply is not incremental
    }
    pub fn undo(self: *@This(), act: Act) void {
        _ = act;
        self.len -= 1;
        self.rebuild(); // Truncate and replay; must be void / infallible
    }
};

// var ctx: Ctx = .{}; var stats: st.explore.Stats = .{};
// try st.explore.dfs(Act, &ctx, 64, &stats);
```

When schedulable state is a pure structure that can be deep-copied, `bfs` is appropriate. For stateful live loops, action-log replay with DFS provides accurate, deterministic state restoration without mocking.

**Architecture recommendation:** Clearly document in test harness headers whether a suite uses value-copy BFS or action-log DFS. CI checks can verify that stateful harnesses do not invoke `explore.bfs`.

## Event-loop clock checklist {#event-loop-clock}

`Calendar` refuses rewinds (`error.ClockRewind`). Event-loop **SUT** testing
clocks (not this package) should split **install** vs **host-tick**
(recommended adopter shape — names below are illustrative):

| API role | Behavior | Explore? |
|----------|----------|----------|
| Install clock (`setNow`-style) | `now < current` → `error.ClockRewind`; first install OK; equal OK | L1 pure clock acts only |
| Host tick (`advance`-style) | Push clock with **clamp** (`max`) then run a production turn — stale host timestamps are product semantics, not harness undo | L0 world step |
| Explicit clamp (`clampNow`) | Today's `@max`; multi-source / dirty stamp merge | Setup / L1 when you mean clamp |
| `Calendar` | Always `ClockRewind` on rewind | Snapshot undo — never rewind |

Clamp is **never** explore undo. Restore time via snapshot/rebuild (`clone` /
`resetTo`, act-log replay). Do not treat a clamped `advance` as “time rolled back.”

If the SUT exposes an engine/C testing `advance` with a fixed integer ABI that
must stay clamp-compatible, freeze that signature; put `ClockRewind` on
`setNow` (and optional `advanceStrict`) instead of breaking the clamp advance.

### Testing helpers and dispatch layering {#testing-helpers}

When testing libraries that wrap event loops, organize testing entrypoints into explicit layers according to their safety guarantees:

| Layer | Intent | Role in Exploration |
|-------|--------|---------------------|
| **L0** | Production-gated turn (`runOnce`, `advance`) | **Primary path**: The only operations that should advance state in explore acts |
| **L1** | Clock advance only (`setNow`, `clampNow`) | Pure clock updates without dispatching work |
| **L2** | Ungated escape hatch (`dispatchEventsUngated`) | **Never used as an explore act**: reserved for separate boundary gap tests |

If your system provides shortcuts that bypass turn gates, deprecate them or ensure they cannot be accidentally selected by `enabled()` during state space exploration.

**Continuous integration pattern:** Keep ungated escape hatches in separate gap test files, and include a CI verification step to ensure that exploration harnesses do not call ungated dispatchers or invoke `explore.bfs` on live event loop instances. Adopters can use the native Zig `explore_gate_check` artifact exported by `state_tcas` in `build.zig`, eliminating fragile shell/grep dependencies:

```zig
// build.zig
const st = b.dependency("state_tcas", .{ .target = target, .optimize = optimize });
const gate_exe = st.artifact("explore_gate_check");
const gate_check = b.addRunArtifact(gate_exe);
gate_check.setCwd(b.path("."));
gate_check.addArgs(&.{
    "--path", "harness/explore",
    "--ext", ".zig",
    "--forbid", "Ungated",
    "--forbid", "dispatchEventsUngated",
    "--ignore-comments",
    "--rule-end",
    "--path", "harness/live",
    "--ext", ".zig",
    "--forbid", "explore.bfs(",
    "--ignore-comments",
    "--rule-end",
});
test_step.dependOn(&gate_check.step);
```

Legacy bash equivalent for ad-hoc terminal runs:

```bash
#!/usr/bin/env bash
set -euo pipefail
if rg -n 'Ungated|dispatchEventsUngated' harness/explore ; then
  echo "Error: Ungated helper referenced in exploration harness" >&2
  exit 1
fi
if rg -n 'explore\.bfs\(' harness/live ; then
  echo "Error: explore.bfs invoked on live stateful harness — use action-log + dfs" >&2
  exit 1
fi
```

## Wire monitor (not a duck) {#safety-liveness}

Safety / Liveness stay outside explore/exhaust decls. Wrap `step` to call
`observe` / `note` — see `examples/toy_fsm.zig`.

### Generic Adapters (`Monitored` / `MonitoredKeyed` / `KeyedOnly`)

To avoid writing boilerplate wrapper structs in every harness, use `monitor.Monitored` or `monitor.MonitoredKeyed`:

```zig
var world: World = .{};
var saf = st.monitor.Safety(*World){ .ctx = &world, .checkFn = World.checkSafety };
var liv = st.monitor.Liveness(*World){ .ctx = &world, .enabledFn = World.isEnabled, .goalFn = World.isGoal };

// Wraps inner, calls step(), saf.observe(), and liv.note(), forwarding enabled() and undo()
var mon = st.monitor.Monitored(Act, World){
    .inner = &world,
    .saf = &saf,
    .liv = &liv,
};

var stats: st.explore.Stats = .{};
try st.explore.dfs(Act, &mon, 64, &stats);
```

For keyed DFS, use `monitor.MonitoredKeyed(Act, World)` (forwards `key()` as well). If you only need `key()` forwarding without monitors, use `monitor.KeyedOnly(Act, World)`.

### Manual Monitoring Pattern

**Safety:** check a **diff since the last observe**, not a sticky “last byte
forever” flag. Snapshot before the step (or keep `prev_len`) and assert only
the new suffix:

```zig
var prev_len: usize = 0;
fn safetyOk(ctx: *Toy) !void {
    // Only the step that grew seq is accountable for the new byte.
    if (ctx.seq_len == prev_len + 1) {
        if (ctx.seq[ctx.seq_len - 1] == bad) return error.SafetyViolation;
    }
    prev_len = ctx.seq_len;
}
```

**Liveness:** `note()` sets `reached` for the rest of the run. DFS `undo` does
**not** clear it — expected. After backtrack to idle, `enabledFn` / `goalFn`
may both be false while `reached` stays true and `finish` still succeeds.
Clear or re-create the monitor in the harness if a path-local goal is required.
Runnable act-log shape: `examples/toy_act_log_dfs.zig`.

## Role labels

The `Role` enum defines core participant categories (`initiator`, `responder`, `harness`) with helper methods:
- `participant()`: Canonical ASCII labels (`Initiator`, `Responder`, `Harness`).
- `participantZh()`: Localized labels (`发起端`, `应答端`, `测试`).
- `tag()`: Lowercase identifiers for JSON serialization.

For domain-specific actors (such as engines, schedulers, or timers), pass custom strings directly to `Observation.from` and `Observation.to`.

## Picture Lock Normalization {#picture-lock}

When verifying Mermaid diagrams against golden markdown locks via `picture.lock`, differences in newline conventions between Windows (CRLF) and Unix (LF) checkouts can cause false `error.PictureDrift` failures.

`picture.lock` normalizes on-disk CRLF (`\r\n`) line endings to LF (`\n`) in memory during comparison without mutating disk files (safe for read-only checkouts). If `expected` matches the normalized content, verification succeeds.

## Action Commutativity & Partial Order Reduction {#commutativity}

When independent concurrent actions can be executed in any order without changing the resulting system state, exploring all $N!$ interleavings wastes exploration budget. You can provide an optional commutativity predicate:

```zig
pub fn commutes(self: *const @This(), a: Act, b: Act) bool {
    // Both actions must be mutually independent in the current state s:
    // 1. Neither action disables the other (when both are enabled in s, executing a leaves b enabled).
    // 2. Commutative outcome: executing a then b yields the exact same state as b then a (s · a · b = s · b · a).
    return isIndependent(a, b);
}
```

When present on the exploration context, `explore.dfs` and `explore.dfsKeyed` maintain a bounded sleep set (`explore.SleepSet`), pruning redundant commuting interleavings while guaranteeing full reachable state coverage. Skipped transitions increment `stats.sleep_skipped`.

**State vs. transition coverage:** Partial Order Reduction guarantees full coverage of all **reachable states** ($S_{reachable}$), but intentionally skips redundant interleavings. Therefore:
- If a harness records Mermaid diagram edges (`Picture` observations) or asserts path-dependent sequence orderings, pruned transitions will not appear in the generated picture.
- When full transition diagrams or path-history assertions are required, omit `commutes`.

## Trace Minimization / Delta Debugging {#minimize-trace}

When state exploration discovers a failing sequence of actions containing irrelevant spurious steps, use `explore.minimizeTrace`:

```zig
const minimal = try st.explore.minimizeTrace(
    Act,
    Harness,
    allocator,
    failing_trace,
    error.SafetyViolation, // optional expected error filter (or null for any error)
    Harness.play,
);
defer allocator.free(minimal);
```

`Harness.play` receives `*Harness` and must cleanly initialize the harness context and release any allocated resources before returning.

Using Delta Debugging (ddmin), `minimizeTrace` systematically isolates the 1-minimal reproducing action sequence that still triggers the failure.

## Summary of Exploration Contracts

| Context Method | DFS (`dfs`) | Keyed DFS (`dfsKeyed`) | BFS (`bfs`) |
|----------------|-------------|------------------------|-------------|
| `enabled()` | Required | Required | Required |
| `step(act)` | Required | Required | Required |
| `undo(act)` | Required (`void`) | Required (`void`) | Not used |
| `key()` | Not used | Required | Required |
| `commutes(a, b)` | Optional | Optional | Not used |
| `clone()` | Not used | Not used | Required |
| `destroy()` | Not used | Not used | Required |
