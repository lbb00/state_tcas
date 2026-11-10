# Contributing

## Setup

- Zig ≥ 0.17.0 (see `build.zig.zon` `minimum_zig_version`)
- `zig build test` and `zig build examples` (or each `example-*`) must stay green
- `zig fmt --check .` must stay clean (also enforced in CI)

## Stability

Following SemVer, `0.x` releases may introduce minor refinements to contracts or picture-lock byte layouts as highlighted in `CHANGELOG.md`.

Picture lock goldens that embed Role labels must be regenerated in the same PR that changes `participant()` / `participantZh()`.

## Scope

1. `src/` and `examples/` stay strictly `std`-only (no third-party or application dependencies).
2. Clearly document boundary limitations in module doc comments (e.g. not a full discrete-event simulator, not LTL model checking, not production logging).
3. Prioritize edge-case testing: budget exhaustion, empty enabling sets, cancellation-before-dispatch, clock rewinds, duplicate permutations, and `PictureDrift`.
4. Keep pull requests focused, clean, and readable.
5. No private paths or personal identifiers in documentation, tests, or commit messages.
6. Canonical imports should be module-qualified (`st.explore.dfs`, `st.exhaust.orders`).

## Documentation & Recipes

- Maintain realistic documentation regarding exploration limits (avoiding pseudo-clones in BFS, observing proper L0/L1/L2 testing helper layering, and distinguishing strict clock advances from clamps).
- Keep context recipes and integration duck types in `docs/harness.md`.
- Document notable changes in `CHANGELOG.md` following Keep a Changelog.
