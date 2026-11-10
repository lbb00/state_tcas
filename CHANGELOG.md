# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-11-10

### Added

- **Generic duck adapters (`monitor.Monitored`, `monitor.MonitoredKeyed`, `monitor.KeyedOnly`)**:
  - Eliminates boilerplate wrapper code for attaching `Safety` and `Liveness` monitors to state machine contexts under `explore.dfs` and `explore.dfsKeyed`.
  - Re-exported under root namespace for convenient access.
- **Action-log replay adapter (`explore.ActLogReplay`)**:
  - Generic wrapper for live/stateful systems that cannot implement genuine `clone()` and require action-log replay for DFS backtracking.
  - Manages action histories, steps forward, and upon backtrack resets and replays the prefix via `RebuildFn` or `inner.reset()`.
- **Action commutativity / Partial Order Reduction (`explore.dfs`, `explore.dfsKeyed`)**:
  - Added optional `commutes(self: *const @This(), a: Act, b: Act) bool` contract for contexts.
  - Automatically identifies independent, commuting actions and skips redundant interleavings using bounded sleep sets (`SleepSet`), pruning symmetric transitions while preserving full reachable state coverage (`stats.sleep_skipped`).
- **Trace minimization / Delta debugging (`explore.minimizeTrace`)**:
  - Automated Delta Debugging (ddmin) algorithm that isolates the minimal reproducing subset of actions from a failing trace with optional expected error filtering.
- **Cross-platform CRLF golden lock normalization (`picture.lock`)**:
  - Automatically normalizes on-disk Windows `\r\n` (CRLF) line endings to `\n` (LF) in memory during comparison, preventing spurious `error.PictureDrift` across multi-platform CI runners without mutating disk files.
- **Native build gate check (`build.zig` `addExploreGateCheck`)**:
  - Native Zig build step helper using `std.fs` and string searching to scan targets for forbidden patterns (e.g. `Ungated` in exploration harness files or `explore.bfs` on stateful contexts), replacing fragile shell/grep scripts.

## [0.1.0] - 2026-11-09

### Added

- **Core exploration toolkit (`explore`)**:
  - Enabling-set exploration via Depth-First Search (`dfs`), state-keyed DFS (`dfsKeyed`), Breadth-First Search (`bfs`), and pseudorandom seeded order exploration (`shuffleSeeded`).
  - Budget-bounded exploration with `Stats` reporting and explicit `error.SearchIncomplete` on budget exhaustion.
  - Per-frame stack buffering of enabled actions up to `max_enabled` (64) with `error.EnabledSetTooLarge` protection.
  - Compile-time duck-type verification for context structures (`verifyDfs`, `verifyDfsKeyed`, `verifyBfs`).
- **Permutation enumeration (`exhaust`)**:
  - Full unique permutation testing via `orders` with factorial scale limits.
  - Single constrained execution scenarios via `exhaust.play`.
  - Permutation skipping via `error.SkipOrder` without failing the entire run.
  - Mermaid state and sequence diagram rendering with byte-level golden locks (`publish`, `render`, `Shell`).
- **Discrete virtual time (`calendar`)**:
  - Monotonic discrete virtual calendar (`Calendar`, `Timed`, `EventId`) supporting microsecond deadlines.
  - Monotonic clock validation returning `error.ClockRewind` on backwards time jumps.
  - State snapshotting and restoration (`clone` / `resetTo`) for exploration backtracking.
  - Slot compaction for cancelled timers (`compactCancelled`).
- **Safety and liveness monitors (`monitor`)**:
  - Configurable `Safety` invariant checkers for state transitions.
  - `Liveness` monitors with monotonic `reached` status tracking across backtracking.
- **Visual diagrams and regression locking (`picture`)**:
  - Mermaid sequence and state diagram emission (`Picture`, `Observation`).
  - Byte-accurate consistency locking (`lockBytes` / `lock`) with silent `error.PictureDrift`.
- **Role semantics and tracing (`role`, `trace`)**:
  - Standard participants (`Initiator`, `Responder`, `Harness`) supporting ASCII and localized Chinese labels.
  - Structural test event tracing (`trace.Event`, `trace.writeJson`).
- **Integration examples**:
  - `toy_fsm`: State machine exploration with DFS and Safety/Liveness assertions.
  - `toy_exhaust_lock`: Exhaustive permutation execution and Mermaid picture locking.
  - `toy_calendar_timeout`: Virtual calendar scheduling, cancellation, and timeout dispatch.
  - `toy_calendar_dfs`: Discrete event simulation with snapshot-based backtracking.
  - `toy_act_log_dfs`: Action-log rebuild with DFS for non-cloneable / live systems.
- **Documentation**:
  - Complete integration guide and recipes in `docs/harness.md`.
  - Architectural FAQs and boundary disciplines in `docs/FAQ.md`.
