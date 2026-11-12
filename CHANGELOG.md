# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Sectional / Block-Level Specification Locking (`st.tla`)**:
  - `formatDeclarationSectionWithMarkers` / `formatDeclarationSection`: Format declaration blocks enclosed by section markers (`\* BEGIN DECLARATIONS` ... `\* END DECLARATIONS` or custom markers via `options.section`), allowing custom variables, initial state predicates, transition relations, and invariants to live alongside auto-generated constants and vocabularies within a single `.tla` specification file.
  - `lockWithOptions`: Line-anchored automatic detection and in-place updating of sectional blocks without overwriting user-authored formulas or module definitions outside the block, maintaining byte-level golden locks and CRLF line ending preservation.
- **Pure-Zig Lightweight TLA+ Spec Syntax Validator (`st.tla`)**:
  - `validateSpecSyntax`: In-process structural syntax validator for TLA+ modules without external Java, TLC, or SANY runtime dependencies. Validates line-anchored module headers (`---- MODULE <Name> ----`), footers (`====`), balanced delimiters (`()`, `[]`, `{}`, `<<>>`), unclosed strings, and unclosed nested comments, while ignoring pre-module and post-footer notes.
- **Direct Action Coverage Verification (`st.picture`, `st.tla`)**:
  - `Picture.verifyCoverage(Act)`: Verify that every defined variant of `Act` was exercised in recorded edges or sequence steps (`error.ActUncovered`), skipping rejected steps and supporting tagged union actions with payloads.
  - `ReplayStats.verifyCoverage(Act, pic)`: One-line coverage assertion on trace replay statistics.
- **Apalache ADR-015 ITF Trace Export (`st.picture`)**:
  - `Picture.renderItfJson`: Render recorded exploration steps as standard Apalache ADR-015 compliant Informal Trace Format (ITF) JSON traces with step continuity verification (`error.DiscontinuousTrace`, `error.EmptyTrace`), skipping rejected steps, and emitting `mbt::actionTaken` annotations.
- **Custom State Variable Configuration (`st.picture`, `st.tla`)**:
  - `RenderItfOptions.state_var_name` and `ReplayOptions.state_var_name`: Configure custom primary state variable name for ITF export and trace replay, validated against reserved keywords via `validateStateVarName` (`error.InvalidStateVariableName`).
- **Rejection State Immutability & Deep Cloning (`st.tla`)**:
  - `error.RejectedButMutated`: Rejection immutability verification ensuring that steps asserting `rejected: true` (or rejecting in step execution/guard) do not mutate the harness state snapshot.
  - `deepClone`: Deep recursive allocator-based cloning for slices (including sentinel-terminated and aligned slices), single-item pointers, structs (skipping comptime fields), arrays, optionals, and tagged unions.

### Changed

- **Trace Replay Verification Strictness (`st.tla`)**:
  - In `replayJsonTraceWithOptions`, detect custom state variables in JSON/ITF step objects that are not checked by scalar/enum projections, raising `error.TraceVariablesUnverified` by default to prevent false confidence when a trace specifies multi-variable state assertions. Added `allow_unverified_variables: bool = false` to `ReplayOptions` for explicit opt-in.
  - Trace event fields (`before`, `rejected`) emitted by serializers are now actively verified: mismatched `before` projections return `error.TraceDiverged`, and unfulfilled rejections return `error.RejectionExpected`.
  - `before` assertion verification aligns trace ingest validation and step execution against the primary state variable, rejecting incompatible projections early with `error.ProjectionUnavailable`.
  - Disallowed infrastructure errors (e.g. `OutOfMemory`) take precedence over mutation checks during rejected steps.

### Fixed

- **Large Integer Bigint Serialization (`st.picture`)**:
  - Wrapped integers beyond 64-bit safe bounds into ADR-015 `{"#bigint": "..."}` objects upon parse overflow in `appendJsonPayload`.
- **Allocation-Free `parseAct` for Zig 0.17 (`st.tla`)**:
  - Refactored `parseAct` to use `std.meta.stringToEnum` for enum actions and inline inspection for void union variants without invoking heap allocators, resolving compatibility with Zig 0.17 std library.

## [0.3.0] - 2026-11-11

### Added

- **TLA+ specification interoperability (`st.tla`)**:
  - `formatDeclarations`: Automatically format TLA+ module declarations (constants, actions, states) from Zig types with string escaping (quotes, backslashes, newlines), SANY-compliant lexical identifier validation (`isValidTlaIdentifier`), compile-time rejection of collisions with standard prelude definitions (`isTlaPreludeCollision`, e.g., `Nat`, `Int`, `Seq`, `Append`, `Actions`, `Next`), and compile-time safety checks rejecting unsupported types (floating point, pointers).
  - `lock`: Golden consistency lock for TLA+ declaration files with automatic CRLF normalization and module name validation, preventing vocabulary and configuration drift (`error.TlaDrift`).
  - `replayJsonTrace` / `replayJsonTraceWithOptions`: Two-phase replay engine for JSON action traces, standard Apalache ADR-015 state-only traces (with adjacent-state transition inference via `enabled()` and `project()`, and `error.ActionMissing` on unreachable transitions), and action-annotated ITF/Quint traces against context harnesses. Structurally separates trace ingestion & validation (`ingestStepPlan` returning strongly-typed `StepPlan`) from domain execution & invariant verification (`executeStepPlan` returning typed `StepOutcome`), verifying enabling guards (`error.ActionNotEnabled`), single-label and strict multi-variable struct state projections (`error.TraceDiverged`, `error.ProjectionFieldMissing`, `error.ProjectionUnavailable`), verified state accounting ensuring non-trivial projection validation, initial step-0 struct projection assertions without requiring string state labels, typed state and `after` alias validation mapping non-string state assertions directly to struct projection fields, non-dispatching ITF step-0 `init` predicate semantics, Quint `mbt::nondetPicks` payload support, synonym conflict detection, and counterexample expected rejection regression testing (`expect_rejection`) with step-bounds enforcement (`error.RejectionStepOutOfBounds`) and strict setup/parser error whitelisting rejecting parser overflow and trace-parse failures (`error.InvalidExpectedRejection`).
  - `decodeItfValue` & recursive variant adaptation: Recursive decoder for Apalache ITF wrappers (`#bigint`, `#tup`, `#set`, `#map`), type-directed recursive variant adaptation for Apalache ADT objects (`{"tag": ..., "value": ...}`) nested within structs, arrays, slices, optionals (`?T`), and tagged unions, with recursion depth protection (`error.NestingTooDeep`) and validation rejecting malformed wrappers (`error.InvalidTraceFormat`).
  - `TlaLexer` & `checkExtends`: Reusable minimal lexical scanner (`TlaLexer`) and comment- and string-literal-aware verification utility (`checkExtends`) confirming that a TLA+ specification contains an `EXTENDS` clause for a required module outside of comments (`\*`, nested `(* ... *)`) and string literals (`"..."`), strictly terminating at the clause boundary before examining operator definitions.
  - `deepEql`: Deep recursive structural equality comparator supporting slices, single-item pointers (including `*anyopaque` and function pointers via address identity), structs, arrays, optionals, and tagged unions.
  - `jsonValueEql`: Dedicated recursive value equality comparator for `std.json.Value` types across numbers, strings, arrays, and associative map objects.
  - Exported `picture.matchesNormalizingCRLF` for reusable cross-platform CRLF golden lock comparisons.
  - `verifyCoverage`: Verification helper asserting all action branches in `Act` were exercised (`error.ActUncovered`).
  - End-to-end example `examples/toy_tla_lock.zig` executable via `zig build example-tla-lock`.
- **Self-bootstrapping verification suite (`src/bootstrap.zig`, `examples/toy_bootstrap_dogfood.zig`)**:
  - Comprehensive dogfooding test suite covering `Calendar` state exploration via `dfsKeyed` with `Safety` and `Liveness` (EF Reachability) monitors with structural pending-event key hashing and active cancellation tracking; `SleepSet` partial order reduction state space preservation and negative non-commutativity detection; `ActLogReplay` state reconstruction validated in lockstep against a cloneable shadow reference model; `minimizeTrace` delta debugging fault isolation under active interfering noise; and `tla` model declaration locking against committed specifications with Apalache ITF trace replay.
  - Dedicated build step `zig build bootstrap` (aliased to `zig build example-bootstrap`) registered in `zig build examples` and CI workflow matrix (`.github/workflows/ci.yml`).

### Fixed

- **Exhaustive permutation equality for tagged union `Act` (`exhaust.skipSwap`)**:
  - Switched from operator `==` to `std.meta.eql` in `exhaust.skipSwap`, enabling support for tagged union actions with payloads under `exhaust.orders` (with pointers and slices compared by address and length).

## [0.2.1] - 2026-11-10

### Added

- **Installed gate check artifact (`explore_gate_check`)**:
  - Exported `explore_gate_check` via `b.installArtifact` so downstream packages can directly reference `st.artifact("explore_gate_check")`.
- **Comment-aware pattern checking (`--ignore-comments`)**:
  - Added `--ignore-comments` flag and `GateRule.ignore_comments` option to strip line comments (`//`, `///`, `//!`) outside string literals before matching, preventing false positives from architectural documentation.

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
