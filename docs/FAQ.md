# Frequently Asked Questions

Concise answers to common architectural and integration questions. Implementation recipes and context templates are detailed in [`harness.md`](harness.md).

## How does `state_tcas` compare to TLA+ or Microsoft P?

`state_tcas` is a pure Zig library (`std`-only) designed for bounded Safety and Liveness verification directly against **your actual Zig code**. 

Formal model checkers (such as TLA+ or Microsoft P) are powerful for analyzing abstract mathematical models, but require creating and maintaining a second specification in a separate language. `state_tcas` eliminates this synchronization cost by driving your existing implementation directly via test harness closures, with bounded search depths and permutation limits (`error.SearchIncomplete` on budget exhaustion).

## Can `state_tcas` be used alongside TLA+ or formal specifications?

**Yes.** While `state_tcas` is fully self-contained, teams with high-assurance requirements can optionally use `st.tla` for bidirectional interop without breaking the `std`-only rule:

- **Vocabulary Locking (`st.tla.lock` / `st.tla.lockWithOptions`)**: Format and lock TLA+ action/state vocabularies and bounded configuration constants directly from Zig types. Test runs enforce byte-level consistency, preventing vocabulary naming and configuration drift (`error.TlaDrift`).
- **Trace Replay & Model-Based Testing (`st.tla.replayJsonTrace` / `st.tla.replayJsonTraceWithOptions`)**: Replay JSON traces or ITF (Informal Trace Format) executions (e.g. from Apalache or Quint `--mbt`) directly against your Zig harness. It supports both standard state-only ITF traces (Apalache ADR-015, inferring transition actions between adjacent states via `enabled()` and `project()`) and action-annotated traces (`action`, `actionTaken`, `mbt::actionTaken`), payload arguments (`payload`, `mbt::nondetPicks`), single-label or multi-variable struct state projections (`state`, `after`, or struct field mappings), enabling guards (`error.ActionNotEnabled`), state divergence checks (`error.TraceDiverged`), missing action detection (`error.ActionMissing`), and counterexample expected rejection regression testing (`expect_rejection`).
- **Pure Zig `std` Implementation**: The `tla` module is 100% pure Zig with no Java, TLC, or external CLI tool requirements in test runs.

## Can I use BFS to explore a live event loop or driver?

**Generally no.** `explore.bfs` requires a value-type context that implements genuine `clone` and `destroy` operations. Stateful systems containing operating system handles, thread pools, or event loops cannot be safely deep-copied. Attempting to mock or fake a clone often masks real concurrency issues.

For such systems, use **action-log rebuild with DFS (`explore.dfs` or `explore.dfsKeyed`)**. The harness records actions along a path and replays them from a clean state during backtracking. See [Act-log rebuild vs BFS](harness.md#act-log-vs-bfs) and [`examples/toy_act_log_dfs.zig`](../examples/toy_act_log_dfs.zig).

Pure value layers that can be faithfully cloned (such as pure scheduler state machines) may safely use `bfs`.

## Which exploration entrypoint should I choose?

| Scenario | Recommended API |
|----------|-----------------|
| Live / stateful system (non-cloneable) | `dfs` or `dfsKeyed` with action-log rebuild |
| Cloneable value context | `bfs` (or `dfs` with snapshot undo) |
| Every unique permutation is valid | `exhaust.orders` |
| Specific, constrained execution story | `exhaust.play` |

## How should SUT testing helpers be structured (L0 / L1 / L2)?

To keep exploration honest, testing helpers exposed by your library under test (SUT) should be categorized by their invocation guarantees:

| Layer | Semantics | Role in Exploration |
|-------|-----------|---------------------|
| **L0** | Production-gated turn (`runOnce`, `advance`) | **Primary path**: The only operations that should advance state in explore acts |
| **L1** | Clock advance only (`setNow`, `clampNow`) | Pure clock updates without dispatching work |
| **L2** | Ungated escape hatch (`dispatchEventsUngated`) | **Never used as an explore act**: reserved for separate boundary gap tests |

If your SUT previously exposed shortcuts that bypassed turn gates, deprecate or rename them explicitly to prevent accidental inclusion in exploration action sets.

## What is the difference between `ClockRewind` and clock clamping?

| Clock Role | Rewind Behavior | Exploration Semantics |
|------------|-----------------|------------------------|
| SUT install helper (`setNow`) | Reject rewinds with `error.ClockRewind` | Strict clock update (L1) |
| SUT host tick helper (`advance`) | May saturate/clamp (`@max`) | Simulates stale host timestamps; not an exploration backtrack |
| Package `Calendar` | Rejects rewinds with `error.ClockRewind` | Monotonic virtual time; restore via snapshot (`clone`/`resetTo`) |

Saturating or clamping a clock forward is not an undo mechanism. In state exploration, past time states must be restored via snapshot restoration or action-log replay.

## How does Liveness tracking behave during DFS backtracking?

Calling `note()` sets `Liveness.reached` monotonically for the remainder of the test run. DFS backtracking (`undo`) intentionally does **not** reset this flag. 

If a required goal state was reached along any valid exploration branch, `finish()` succeeds. Conversely, if exploration returns to idle without ever triggering the goal condition, `finish()` will report failure if the goal was enabled.

## How should RAII lifecycles and paired `begin`/`end` calls be handled?

Map RAII operations directly to standard exploration primitives:
- In DFS, map `begin` to `step` and `end` (or state restoration) to `undo`.
- Ensure paired operations cannot oscillate indefinitely in `enabled()` by adding state-dependent guards or including active phases in `dfsKeyed` state keys.
- If a queue or resource is empty, omit the drain action from `enabled()` entirely.

## Public Modules & Contracts

The public API contract of `state_tcas` consists of:

- `explore`: `dfs`, `dfsKeyed`, `bfs`, `shuffleSeeded`, `Stats`, `max_enabled`, compile-time validators (`verify*`).
- `exhaust`: `orders`, `play`, `publish`, `render`, `Shell`, `fact`, `SkipOrder`, `verify*`.
- `calendar`: `Calendar`, `Timed`, `EventId`, `ClockRewind`, `clone`, `resetTo`.
- `monitor`: `Safety`, `Liveness`, `Bundle`.
- `picture`: `Picture`, `Observation`, `lock`.
- `role`: Standard participant labels and localized formatters.
- `trace`: Structured JSON event recording.
