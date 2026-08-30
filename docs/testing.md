# Local Agent TestKit

SCV Control uses a repository-local development Mod and a PowerShell process runner. No GitHub Actions workflow is required.

## Agent loop

```text
edit production modules
  -> tools/test.ps1 creates an isolated mod directory
  -> Factorio smoke-loads and benchmarks the mod
  -> a headless automated scenario builds deterministic fixtures
  -> production path/follower/input modules run against real Factorio objects
  -> a separate pathfinding scenario compares engine and experimental planners
  -> JSON assertions and a completion marker are emitted
  -> the runner returns success/failure and cleans up
```

Run everything:

```powershell
pwsh -NoProfile -File .\tools\test.ps1 -Suite all
```

Available suites:

| Suite | Purpose |
| --- | --- |
| `smoke` | Loads settings/data/control stages and exits after Factorio successfully creates a map. |
| `integration` | Runs deterministic engine-backed tasks until planning, character movement, queue execution, and failure cases actually complete. |
| `benchmark` | Runs the shared pathfinding test set against engine, alternate, A*, weighted A*, and Theta* variants. |
| `all` | Runs smoke, integration, and benchmark. This is the required pre-commit command. |

Use `-Verbose` for Factorio stdout. Successful runs clean their temporary directory. Failures retain it and print its path; `-KeepArtifacts` retains successful artifacts as well.

## Reports

The integration scenario writes:

```text
<test-root>/write-data/script-output/scv-control/test-results.json
```

The schema includes Factorio and Mod versions, actual duration ticks, pass/fail totals, and per-assertion completion details. The engine log also contains:

```text
SCV_TESTKIT_REPORT {...}
SCV_TESTKIT_COMPLETE passed=N failed=N
```

The external runner treats missing reports, timeouts, Lua errors, and failed assertions as nonzero exits.

The benchmark scenario writes `script-output/scv-control/pathfinding-benchmark.json` and `SCV_BENCH_COMPLETE passed=N failed=N`. See [pathfinding benchmark](pathfinding-benchmark.md) for fixtures, metrics, current results, and interactive commands.

The integration suite does not use a fixed tick count as a success condition. It exits when every task reaches its terminal assertion. `TEST_TIMEOUT_TICKS` is only a failure guard for deadlocks and regressions.

## Adding a regression

1. Put reusable behavior in a production module under `scripts/`.
2. Add the smallest deterministic fixture to `devmods/scv-control-testkit/scenarios/automated/runner.lua`.
3. Assert bounded outcomes such as path length, detour ratio, arrival error, selected candidate, or failure status.
4. Run `-Suite integration`, then `-Suite all`.

The corridor regression uses exact coordinates captured by the planner logger. Factorio 2.0.77 returns a 47.10-tile baseline for a target only 9.09 tiles away. The regression evaluates lateral fractions 0.50 and 0.75 in strict sequence, requires the nearer probe to beat the overshooting fallback, bounds the selected route below 34 tiles, and then waits for the character to arrive. The accepted fixture currently selects a 28.81-tile route and completes movement in 137 ticks.

Alternate probes are deliberately sequential. Engine-backed experiments showed that unrelated simultaneous path requests can change Factorio's non-optimal pathfinder result. The two segments belonging to one probe may run together, but the next probe starts only after both previous segment requests terminate. This costs up to four additional engine requests only when the baseline path exceeds twice the direct distance.

The open-area regression reproduces a captured 18-waypoint zigzag and requires collision-mask-aware smoothing to reduce it to a direct two-point path with no reversal. Planner JSONL records engine and smoothed paths, per-candidate fractions, vias and distances, the selected candidate, corner counts, maximum turn angle, and reversal count.

The trajectory suite first calibrates all 16 direction enum values against actual character displacement. Factorio characters expose 16 values but produce 8 unique movement vectors. Three paths halfway between native vectors must then complete with bounded cross-track error, no large direction jumps, no distance regressions, and a low switch rate.

## Reload behavior

- Runtime files (`control.lua` and `scripts/*.lua`): reload the save or call `game.reload_mods()` in singleplayer.
- Test-lab control code: same behavior, because only a marker is embedded; behavior runs from `scv-control-testkit`.
- Prototype, settings, custom-input, or locale changes: restart Factorio.
- Enabled Mod set changes: regenerate the interactive test save with `tools/create-test-save.ps1 -Force`.
