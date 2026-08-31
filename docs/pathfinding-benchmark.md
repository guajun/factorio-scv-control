# Pathfinding Benchmark

The local TestKit owns a deterministic pathfinding test set shared by headless and interactive runs. Production movement does not use the experimental grid planners.

## Run headlessly

```powershell
pwsh -NoProfile -File .\tools\test.ps1 -Suite benchmark
```

`-Suite all` also runs the benchmark after smoke and integration. Use `-KeepArtifacts` to retain:

```text
<test-root>/write-data/script-output/scv-control/pathfinding-benchmark.json
```

The scenario completes only after every engine request and algorithm result reaches a terminal state. It writes `SCV_BENCH_COMPLETE passed=N failed=N`; the tick limit is a deadlock guard.

## Test set

Fixture version 3 contains:

| Fixture | Concern |
| --- | --- |
| `open-diagonal` | Unobstructed any-angle movement. |
| `long-wall-return` | Captured regression where the engine takes the far wall end and a forced alternate via creates a triangle. |
| `long-wall-enter` | Captured regression entering the narrow corridor from above. |
| `narrow-corridor` | Clearance and straight travel between parallel walls. |
| `tight-clearance-corridor` | A physically safe narrow channel that conservative cell inflation may route around. |
| `u-trap` | A cul-de-sac that initially points away from the goal. |
| `slalom` | Multiple alternating topology decisions. |
| `captured-slalom-return` | Exact normal-click regression where the engine switches from the north route to a late south portal. |
| `gate-open` | Dynamic-static snapshot before a gate closes. |
| `gate-closed` | Same world after the blocking wall is inserted. |
| `unreachable-box` | Complete enclosure and no-path termination. |

Definitions live in `devmods/scv-control-testkit/pathfinding/fixtures.lua`. Do not recreate these geometries in another runner.

## Algorithms

| Algorithm | Description |
| --- | --- |
| `engine` | One Factorio `request_path`, followed by production smoothing. |
| `production-local` | Current production comparison: validated engine path versus conservative local A* inside a baseline-length ellipse. |
| `engine-inflated` | Factorio `request_path` with the subject box expanded by the complete trajectory envelope. |
| `engine-alternate` | Current sequential 0.50/0.75 via strategy. |
| `engine-alternate-global` | Evaluates alternate candidates regardless of the production `2x` gate, then applies a full-path collision-safe string pull. |
| `grid-a-star` | Unweighted 8-neighbor A* on a 0.5-tile inflated collision snapshot. |
| `grid-weighted-a-star-2` | The same search with heuristic weight 2. |
| `grid-theta-star` | Any-angle parent relaxation using the fast in-memory snapshot. |
| `grid-theta-star-exact` | Theta* with every accepted visibility edge confirmed by Factorio collision queries. |
| `safe-hybrid` | Shortest validated result from production-local, engine, inflated engine, and conservative A*, with Exact Theta only as a failure fallback. |

All paths are checked twice:

- `actor_collision_safe` uses the character's normal collision box and is a hard assertion.
- `trajectory_clearance_safe` includes the follower's cross-track envelope and is a reported risk metric.

Node expansions and snapshot/Factorio line checks are deterministic work metrics. Engine request and completion ticks are reported separately. Path quality ratios compare each successful result with the shortest actor-safe result observed for that fixture; they are not proofs of global optimality.

## Factorio 2.0.77 baseline

The current eleven-fixture run passes all reachability, collision, dynamic-state, and captured-quality assertions across ten algorithms. The exact totals are emitted in the JSON report.

| Algorithm | Mean / actor-best | Max / actor-best | Expanded | Snapshot lines | Factorio lines | Requests | Clearance misses |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `engine` | 1.190 | 2.008 | 0 | 0 | 0 | 11 | 6 |
| `production-local` | 1.031 | 1.087 | 8342 | 33932 | 0 | 11 | 0 |
| `engine-inflated` | 1.205 | 2.056 | 0 | 0 | 0 | 11 | 0 |
| `engine-alternate` | 1.026 | 1.085 | 0 | 0 | 0 | 35 | 6 |
| `engine-alternate-global` | 1.000 | 1.000 | 0 | 0 | 0 | 35 | 6 |
| `grid-a-star` | 1.041 | 1.101 | 10556 | 41755 | 0 | 0 | 0 |
| `grid-weighted-a-star-2` | 1.043 | 1.101 | 7514 | 25868 | 0 | 0 | 0 |
| `grid-theta-star` | 1.050 | 1.121 | 9307 | 48207 | 0 | 0 | 0 |
| `grid-theta-star-exact` | 1.050 | 1.121 | 9307 | 48207 | 47760 | 0 | 0 |
| `safe-hybrid` | 1.031 | 1.087 | 8342 | 33932 | 0 | 22 | 0 |

On `long-wall-return`, the measured lengths are:

```text
engine                    49.53
production-local          26.81
engine-alternate          26.23
engine-alternate-global   24.66
grid-theta-star           25.49
grid-theta-star-exact     25.79
```

On `captured-slalom-return`, the measured lengths are:

```text
engine                    39.05
production-local          36.68
engine-alternate          39.05
engine-alternate-global   35.99
grid-a-star               35.25
grid-theta-star           35.38
grid-theta-star-exact     35.28
```

The production threshold skips this case because `39.05 / 32.49 = 1.202`, even though the engine result is 10.8% longer than the shortest observed result.

The current production-local planner has no such threshold; it selects the validated 36.68-tile conservative-grid path.

On `tight-clearance-corridor`, conservative grid inflation routes outside the narrow channel (`22.34`), while production-local keeps the fully validated engine corridor (`20.29`).

The experiment establishes four boundaries:

1. The engine pathfinder's performance-biased search can be roughly twice the shortest observed route.
2. Alternate vias can discover the other wall end, but a via must remain a search hint; full-path smoothing removes measurable forced-via overhead.
3. Weight 2 reduces work but produces a 46.96-tile slalom path versus about 42.06 for unweighted/Theta search.
4. Node-center inflation alone did not prove continuous trajectory clearance. Adding half a cell diagonal removed all observed fast-grid misses; Exact Theta then added 47,760 Factorio line checks without improving safety on the current fixture set.

The conservative snapshot experiment subsequently added half a cell diagonal to obstacle inflation. Fast grid planners now have zero observed clearance misses; see the reverse-chronological [experiment log](pathfinding-experiments.md) for the safety/quality tradeoff and failed hypotheses.

The next planner experiment should therefore cache/invalidate navigation regions and portals on static world changes, then use a small number of exact checks on the final corridor. It should not run exact surface geometry queries throughout a full local search.

## Interactive use

The existing developer save loads the same fixture catalog:

```text
/scv-test-bench list
/scv-test-bench long-wall-return
/scv-test-bench long-wall-return grid-theta-star
/scv-test-bench long-wall-return all
```

Omitting the algorithm runs `engine-alternate-global`. The command creates or refreshes the `scv-pathfinding-bench` surface, moves the player to the fixture start, and renders selected paths with a color legend. `all` is intentionally explicit because exact Theta can pause the GUI while it performs continuous geometry queries.

After a result is drawn, right-click the red goal marker to compare the production planner on the same geometry. `/scv-test-home` returns to the normal test lab.

Normal accepted move plans in the interactive TestKit also trigger a live comparison on the current surface. Every enabled algorithm is drawn with its own color/dash style and listed in a checkbox panel. Checkboxes control current visibility and whether an algorithm runs on the next plan. Exact Theta is available but marked high-cost.

```text
/scv-test-preview on
/scv-test-preview off
/scv-test-preview show
/scv-test-preview clear
```

Each completed comparison is appended to `%APPDATA%\Factorio\script-output\scv-control\live-preview.jsonl`.
