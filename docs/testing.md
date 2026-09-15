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
| `episodes` | Shared PlanningRun and follower in condition-driven episodes, including the known inserted-wall failure baseline. |
| `calibration` | Twice-repeated, fixed-seed real gate/belt native-motion probes; full metrics/timelines must agree. Not planner capability validation. |
| `interchange` | Bounded fixture capture, query/hash conformance, import rejection, and actual follower replay. |
| `live` | Starts the isolated loopback headless/RCON lab and asserts external result delivery, native arrival and lifecycle rejection. |
| `all` | Runs smoke, integration, benchmark, episodes, calibration, interchange, Python conformance and the live headless loop. This is the required pre-commit command. |

Use `-Verbose` for Factorio stdout. Successful regular suites clean their temporary directory. Failures retain it and print its path; `-KeepArtifacts` retains successful artifacts as well. The separate live host retains its own report/work artifacts and prints that additional root.

Host conformance needs Python 3.10+ (`-PythonExe` selects the executable). The normal mod has no Python dependency. The full offline comparison is:

```powershell
pwsh -NoProfile -File .\tools\navigation\eval.ps1 -KeepArtifacts
```

This captures the shared fixture-v4 catalog, runs Dijkstra and A* against identical exported graphs, and executes both result sets in fresh headless Factorio instances. Generated import modules are written only into a temporary project copy. The manifest identifies every capture, solver, and replay artifact. Runtime and lifecycle failures retain diagnostics. No command above launches a graphical client.

For an already generated `solver-bundle.json`, use
`python tools/navigation/replay_bundle.py --bundle PATH`. This validates the
host contract, imports only into an isolated project copy, and uses the same
headless acceptance/follower replay. The optional pinned source-polygon backend
has separate dependency-backed tests and comparison commands in
[its guide](../tools/navigation/backends/README.md); default `all` never installs
third-party packages and does not substitute for that backend's explicit eval.

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

The benchmark scenario writes `script-output/scv-control/pathfinding-benchmark.json` and `SCV_BENCH_COMPLETE passed=N failed=N`. See [pathfinding benchmark](pathfinding-benchmark.md) for fixtures, metrics, current results, and interactive commands. See [navigation policy](navigation-policy.md) for the complete hardcoded-parameter inventory.

Interchange writes `script-output/scv-control/navigation/interchange-results.json` and `SCV_INTERCHANGE_COMPLETE passed=N failed=N`. Source captures and raw/final replay routes live beside that report. GUI commands `/scv-nav-capture` and `/scv-nav-replay` consume the same code; see [capture and replay](../devmods/scv-control-testkit/interchange/README.md).

`-Suite live` runs an isolated loopback RCON server plus the Python solver and
waits for native arrival, duplicate rejection, cancellation and session replacement.
It is also part of `-Suite all`. Its independent retained artifact root contains
`live-report.json`, exact work/result values and `rpc-trace.jsonl`. The default
uses server-only bulk-file snapshot transfer; RCON carries control/result data.
Run `python tools/navigation/live.py --test --compare-transports` separately for
an identical-input comparison with the slow legacy chunked download. It is not
part of default testing. The default
suite never launches the generated manual GUI client script. See the
[live host guide](../tools/navigation/LIVE.md) for connecting a client with matching
mod copies. A manual two-peer connection/desync test is not implied by a passing
headless transport test.

Pathfinding experiments and failures are recorded newest-first in [the experiment log](pathfinding-experiments.md). Add an entry whenever an experiment changes a planner assumption, even if no production code is selected.

Calibration runs retain a separate `scv-calibration-*` root, including both native
runs and a combined `calibration-summary.json`. Each run writes
`script-output/scv-control/calibration/gates.json` or `belts.json`. Direct focused
commands are `python tools/navigation/calibrate.py --domain gates` and
`python tools/navigation/calibrate.py --domain belts`; `--project-root` selects a
specialist worktree without editing its central runner. The default two runs
compare complete case records, excluding only host-level wall-clock time. A
single `--repeat 1` diagnostic is explicitly not a determinism check. These
scenarios use only base + SCV + TestKit, with DLC disabled and fixed seed 424242.
The first gate slice does not cover circuits; the first belt slice does not
cover immunity, entry/exit, follower compensation or changing belts. Domain
READMEs state exact geometry, interventions, terminal conditions and limitations.

The integration suite does not use a fixed tick count as a success condition. It exits when every task reaches its terminal assertion. `TEST_TIMEOUT_TICKS` is only a failure guard for deadlocks and regressions.

## Adding a regression

1. Put reusable behavior in a production module under `scripts/`.
2. Add the smallest deterministic fixture to `devmods/scv-control-testkit/scenarios/automated/runner.lua`.
3. Assert bounded outcomes such as path length, detour ratio, arrival error, selected candidate, or failure status.
4. Run `-Suite integration`, then `-Suite all`.

The corridor integration regression uses exact coordinates captured by the planner logger. It calls the same `LocalPlanner.compare` used by production, requires a trajectory-safe local route substantially shorter than the 47.10-tile engine baseline, and then waits for the real follower to arrive. Legacy alternate probes remain only in the separate benchmark for historical comparison.

The open-area regression reproduces a captured 18-waypoint zigzag and requires collision-mask-aware smoothing to reduce it to a direct two-point path with no reversal. Planner JSONL records engine and smoothed paths, per-candidate fractions, vias and distances, the selected candidate, corner counts, maximum turn angle, and reversal count.

The trajectory suite first calibrates all 16 direction enum values against actual character displacement. Factorio characters expose 16 values but produce 8 unique movement vectors. Three paths halfway between native vectors must then complete with bounded cross-track error, no large direction jumps, no distance regressions, and a low switch rate.

## Reload behavior

- Runtime files (`control.lua` and `scripts/*.lua`): reload the save or call `game.reload_mods()` in singleplayer.
- Test-lab control code: same behavior, because only a marker is embedded; behavior runs from `scv-control-testkit`.
- Prototype, settings, custom-input, or locale changes: restart Factorio.
- Enabled Mod set changes: regenerate the interactive test save with `tools/create-test-save.ps1 -Force`.
