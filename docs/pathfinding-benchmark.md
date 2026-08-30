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

Fixture version 1 contains:

| Fixture | Concern |
| --- | --- |
| `open-diagonal` | Unobstructed any-angle movement. |
| `long-wall-return` | Captured regression where the engine takes the far wall end and a forced alternate via creates a triangle. |
| `long-wall-enter` | Captured regression entering the narrow corridor from above. |
| `narrow-corridor` | Clearance and straight travel between parallel walls. |
| `u-trap` | A cul-de-sac that initially points away from the goal. |
| `slalom` | Multiple alternating topology decisions. |
| `gate-open` | Dynamic-static snapshot before a gate closes. |
| `gate-closed` | Same world after the blocking wall is inserted. |
| `unreachable-box` | Complete enclosure and no-path termination. |

Definitions live in `devmods/scv-control-testkit/pathfinding/fixtures.lua`. Do not recreate these geometries in another runner.

## Algorithms

| Algorithm | Description |
| --- | --- |
| `engine` | One Factorio `request_path`, followed by production smoothing. |
| `engine-alternate` | Current sequential 0.50/0.75 via strategy. |
| `engine-alternate-global` | Same candidates, then one full-path collision-safe string pull to measure forced-via overhead. |
| `grid-a-star` | Unweighted 8-neighbor A* on a 0.5-tile inflated collision snapshot. |
| `grid-weighted-a-star-2` | The same search with heuristic weight 2. |
| `grid-theta-star` | Any-angle parent relaxation using the fast in-memory snapshot. |
| `grid-theta-star-exact` | Theta* with every accepted visibility edge confirmed by Factorio collision queries. |

All paths are checked twice:

- `actor_collision_safe` uses the character's normal collision box and is a hard assertion.
- `trajectory_clearance_safe` includes the follower's cross-track envelope and is a reported risk metric.

Node expansions and snapshot/Factorio line checks are deterministic work metrics. Engine request and completion ticks are reported separately. Path quality ratios compare each successful result with the shortest actor-safe result observed for that fixture; they are not proofs of global optimality.

## Factorio 2.0.77 baseline

The current nine-fixture run passes 72 assertions across seven algorithms:

| Algorithm | Mean / best | Max / best | Expanded | Snapshot lines | Factorio lines | Requests | Clearance misses |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `engine` | 1.225 | 2.008 | 0 | 0 | 0 | 9 | 5 |
| `engine-alternate` | 1.019 | 1.063 | 0 | 0 | 0 | 21 | 5 |
| `engine-alternate-global` | 1.008 | 1.041 | 0 | 0 | 0 | 21 | 5 |
| `grid-a-star` | 1.012 | 1.034 | 9385 | 37412 | 0 | 0 | 5 |
| `grid-weighted-a-star-2` | 1.026 | 1.117 | 7443 | 25325 | 0 | 0 | 5 |
| `grid-theta-star` | 1.011 | 1.034 | 8235 | 42631 | 0 | 0 | 5 |
| `grid-theta-star-exact` | 1.016 | 1.046 | 8179 | 42300 | 42225 | 0 | 0 |

On `long-wall-return`, the measured lengths are:

```text
engine                    49.53
engine-alternate          26.23
engine-alternate-global   24.66
grid-theta-star           25.49
grid-theta-star-exact     25.79
```

The experiment establishes four boundaries:

1. The engine pathfinder's performance-biased search can be roughly twice the shortest observed route.
2. Alternate vias can discover the other wall end, but a via must remain a search hint; full-path smoothing removes measurable forced-via overhead.
3. Weight 2 reduces work but produces a 46.96-tile slalom path versus about 42.06 for unweighted/Theta search.
4. A fast sampled snapshot does not prove continuous trajectory clearance. Exact Theta removes all observed clearance misses, but 42,225 Factorio line queries are too costly for a per-command production planner.

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
