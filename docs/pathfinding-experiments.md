# Pathfinding Experiment Log

New entries go at the top. Keep failed hypotheses and operational mistakes: the purpose of this log is to prevent the same plausible shortcut from being rediscovered without its failure context.

Each entry should state the question, exact fixture/version, measured result, falsified assumption, and decision. Generated JSON remains the source of exact per-path data; this document records why the result changed the design.

## 2026-08-31 - Shared PlanningRun makes benchmark order production-equivalent

**Question:** Can production and the static benchmark share candidate algorithms without also sharing the asynchronous request state machine?

**Fixture version:** 4, eleven fixtures and ten reported algorithms on Factorio 2.0.77.

**Measured result:** The shared `production-v1` run issued `engine-normal`, then `engine-inflated`, then synchronous `grid-a-star` for every reachable fixture. The unreachable fixture terminated after `engine-normal` reported no-path; the standalone inflated-engine benchmark then ran through its isolated legacy adapter. `production-local` solved 10/10 reachable fixtures with zero trajectory-clearance violations, 21 production engine requests, 8,310 expanded local nodes, and 33,733 in-memory line checks. Representative selected distances remained `20.17` for `tight-clearance-corridor`, `26.81` for `long-wall-return`, and `36.68` for `captured-slalom-return`.

**Falsified assumption:** Sharing only `LocalPlanner.compare` does not make an evaluation production-equivalent. The previous benchmark requested the inflated path first, duplicated busy/no-path control flow, and could perturb Factorio's scheduling-sensitive normal result.

**Decision:** `PlanningRun` owns provider order, request correlation, terminal states, post-processing, validation, scoring, selection, and deterministic traces. Production, engine-backed integration, `production-local`, and live preview use that run. Historical alternate, standalone engine, and experimental grid algorithms remain benchmark-only adapters and cannot alter the production provider sequence.

## 2026-08-31 - Tight corridor needs the inflated-engine candidate in production

**Question:** Why did live plans near the `tight` marker increasingly route around the wall columns even though the corridor was physically traversable?

**Fixture version:** 4 captures the logged non-grid-aligned command at local start `(9.9296875, -9.87890625)` and goal `(9.9296875, 9.8671875)`.

**Measured result:**

```text
normal engine             19.97  trajectory-unsafe
inflated engine           20.17  trajectory-safe, through corridor
conservative grid A*      22.14  trajectory-safe, outside detour
new production-local      20.17  selected engine-inflated
```

The normal engine centerline was shortest but violated the follower's complete trajectory envelope. The conservative 0.5-tile snapshot correctly remained safe, but its cell inflation erased the usable channel and forced the outside route. Factorio could still plan through the channel when its request bounding box was expanded by the exact trajectory margin.

**Falsified assumption:** Normal engine plus conservative local A* did not span the useful safety/quality frontier. Validating the normal route can reject a corridor that an inflated engine request can represent more precisely than the sampled grid.

**Decision:** Production now requests normal and inflated engine paths sequentially, then compares both with conservative local A*. It selects the shortest trajectory-safe candidate with no detour-ratio trigger. The extra request is an explicit latency/work tradeoff and is recorded by the benchmark. The fixture now asserts that production retains the safe narrow channel rather than silently accepting the grid detour.

## 2026-08-31 - Same-version reload does not run configuration migration

The first strict-zone migration only rebuilt the test lab from `on_configuration_changed`. `game.reload_mods()` loaded the new control checksums but did not raise that migration path because both development mods still reported version `0.1.0`; the visible map therefore remained unchanged.

**Decision:** The interactive TestKit checks its fixture schema version on the first tick and rebuilds when stale. `/scv-test-reset` remains the explicit immediate rebuild command. Do not assume source checksum reload is equivalent to a Mod version configuration change.

## 2026-08-31 - Production removes alternate via and uses safe local comparison

Production now makes one Factorio baseline request, validates the complete smoothed path against the trajectory envelope, and compares it with conservative local A* inside the baseline-length ellipse. It chooses the shorter safe result; there is no detour-ratio gate, lateral fraction, or forced intermediate point.

**Fixture version:** 3, eleven fixtures, ten planner variants.

**Production-local results:**

- Reachable fixtures solved: 10/10.
- Trajectory clearance misses: 0.
- Mean distance / best trajectory-safe distance: 1.001.
- Maximum distance / best trajectory-safe distance: 1.007.
- `long-wall-return`: 26.81 instead of engine 49.53.
- `captured-slalom-return`: 36.68 instead of engine 39.05.
- `tight-clearance-corridor`: preserves the safe engine route at 20.29 instead of conservative-grid detour 22.34.

**Cost risk:** Local snapshot capture and A* currently run synchronously after the engine result. The benchmark reports 8,342 expanded nodes and 33,932 in-memory line checks across the fixture set, but wall-clock/UI latency still needs interactive profiling before this is considered production-ready for long commands.

**Decision:** Remove alternate state from production and retain it only as a legacy benchmark family. Next optimize navigation snapshot caching/invalidation rather than reintroducing trigger heuristics.

## 2026-08-31 - Baseline-mirror bounds were another hidden heuristic

**Question:** Can production local A* search only a bounding box containing the engine path and its reflection across the start-goal line?

**Failure:** On `long-wall-return`, the first production-local implementation selected a 51.74-tile safe path, worse than the 49.53 engine path and far worse than the 26.81 conservative grid result using fixture bounds. The reflected polyline did not define the complete opposite homotopy region.

**Falsified assumption:** Moving the mirror operation from via placement to search-window construction does not remove the heuristic; it merely hides it in a different layer.

**Replacement:** Any point on a path shorter than a known baseline of length `L` lies inside the ellipse whose foci are start/goal and whose major axis is `L`. Production now searches the axis-aligned bounds of that ellipse, plus derived clearance padding and an adaptive node budget.

**Result:** `long-wall-return` production-local changed from 51.74 to 26.81. Across ten reachable fixtures it has zero clearance misses, mean safe ratio 1.001, and maximum safe ratio 1.007.

**Decision:** Search bounds must follow a geometric guarantee or explicit resource budget, never a guessed obstacle side.

## 2026-08-31 - Tight-clearance fixture exposes conservative-grid detours

Two wall columns form a narrow corridor that the trajectory envelope can traverse. Results:

```text
engine / inflated engine     20.29
conservative grid A*         22.34
conservative Theta*          22.74
production-local             20.29
```

The half-cell-diagonal inflation did not return no-path, but it rejected the direct narrow channel and routed around the wall columns.

**Falsified assumption:** A conservative sampled grid can be both universally safe and geometrically neutral at clearance boundaries.

**Decision:** Production compares the fully validated engine path with conservative local A*. If the engine centerline already satisfies the trajectory envelope, it preserves the shorter exact-engine corridor.

## 2026-08-31 - Fixture rendering must be surface-scoped

The first shared fixture builder used `rendering.clear()`. Running a benchmark surface could erase strict-zone labels and live overlays on the main test surface.

**Decision:** Fixture cleanup destroys only render objects whose `surface` matches the fixture surface. Test utilities must not mutate unrelated surfaces or ordinary saves.

## 2026-08-31 - Conservative snapshot inflation makes fast grid paths safe

**Question:** Can a cached 0.5-tile collision snapshot provide trajectory-safe paths without running tens of thousands of Factorio geometry queries?

**Change:** Inflate every sampled blocked position by the trajectory envelope plus half the grid-cell diagonal. The half-diagonal term is derived from grid resolution and covers the space between a node center and any point in its cell.

**Fixture set:** Version 2, ten fixtures, Factorio 2.0.77.

**Results:**

| Algorithm | Mean / actor-best | Clearance misses | Expanded | Factorio line checks |
| --- | ---: | ---: | ---: | ---: |
| `grid-a-star` | 1.034 | 0 | 10287 | 0 |
| `grid-weighted-a-star-2` | 1.037 | 0 | 7456 | 0 |
| `grid-theta-star` | 1.042 | 0 | 9004 | 0 |
| `grid-theta-star-exact` | 1.042 | 0 | 9004 | 46306 |
| `safe-hybrid` | 1.034 | 0 | 6653 | 0 |

The original narrow corridor remains reachable at 30.00 tiles. The later tight-clearance fixture shows the conservative grid may choose a longer outside route even when an exact safe corridor exists.

**Falsified assumption:** Exact any-angle visibility checks are not automatically worth their cost. Once the snapshot is conservatively inflated, Exact Theta produced no safety improvement on this fixture set and did not improve path length enough to justify 46k surface queries.

**Tradeoff:** Conservative inflation removes corner leakage but costs roughly 3%-4% against the shortest actor-safe result, which is often an unsafe legacy route. Reports must therefore show both actor-safe and trajectory-safe baselines.

**Decision:** Continue toward cached inflated navigation regions plus a small number of final exact checks. Compare against a fully validated engine path before replacing it. Do not use Exact Theta throughout every search expansion.

## 2026-08-31 - Inflating the engine subject solves safety, not topology

**Question:** Is passing an expanded character bounding box to Factorio sufficient to replace alternate vias?

**Change:** Add `engine-inflated`, using the normal character collision box plus the complete speed-dependent trajectory clearance margin.

**Results:**

- Clearance misses: 6 -> 0.
- Narrow corridor: still reachable, 30.00 tiles.
- `long-wall-return`: 49.53 -> 50.70, while safe local grid search is 26.81.
- `captured-slalom-return`: 39.05 -> 39.06, while safe local grid search is 36.68.

**Falsified assumption:** A correct configuration-space footprint does not repair Factorio's weighted topology choice. It can make the same wrong wall end slightly longer while remaining collision-safe.

**Decision:** Keep inflated engine as a cheap safe baseline/fallback. Do not treat it as the topology planner.

## 2026-08-31 - Forced via creates the visible wall-end cone

**Observation:** Live command 28 selected this production path:

```text
start -> (-45.19,-4.15) -> (-42.5,-5.5) -> (-41.5,-6.5) -> goal
```

The real wall portals are near `(-42.5,-4.5)` and `(-42.5,-6.5)`. The via overshoots the wall end by about 2.7 tiles and creates a 144.5-degree turn. Multiple algorithm overlays converge at the wall end and fan toward different approach points, producing the visible cone.

**Falsified assumption:** Full-path string pulling cannot reliably repair an arbitrary via. It can delete points but cannot move a bad point onto a missing obstacle tangent/portal.

**Decision:** Via placement is a legacy comparison only. The target planner must generate topology/portal information from the collision world model.

## 2026-08-31 - Direct-distance detour ratio misses meaningful portal mistakes

**Fixture:** `captured-slalom-return`.

```text
direct distance             32.49
engine / production         39.05
unconditional global via    35.99
grid A* actor-safe           35.25
```

The engine path is 10.8% longer than the shortest observed result, but `39.05 / 32.49 = 1.202`, so production's `detour_ratio > 2` gate does nothing.

**Falsified assumption:** Direct distance is too weak a lower bound in multi-obstacle scenes to decide whether a path deserves optimization.

**Decision:** Benchmark alternate-global unconditionally. Production remains unchanged until a bounded non-via planner is ready.

## 2026-08-30 - Parallel path requests perturb engine results

Issuing many alternate probes concurrently changed Factorio's returned routes for identical coordinates. Serial evaluation produced stable candidate lengths.

**Decision:** Engine candidate families remain strictly serial. Parallel requests are not used as a cheap k-path API.

## 2026-08-30 - Character directions expose 16 values but 8 motions

Engine-backed calibration showed `walking_state` has eight unique physical movement vectors. Nearest-direction control caused rapid switching and missed corners.

**Decision:** Keep geometric planning separate from the hysteresis-controlled 8-vector trajectory follower. Collision planning must include the follower's cross-track envelope.
