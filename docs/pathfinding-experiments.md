# Pathfinding Experiment Log

New entries go at the top. Keep failed hypotheses and operational mistakes: the purpose of this log is to prevent the same plausible shortcut from being rediscovered without its failure context.

Each entry should state the question, exact fixture/version, measured result, falsified assumption, and decision. Generated JSON remains the source of exact per-path data; this document records why the result changed the design.

## 2026-09-15 - External solver boundary reaches native execution; transport remains expensive

**Question:** Can an external solver consume the same exact captured problem, return through production validation, and finish real character movement without launching a GUI?

**Scope:** Factorio 2.0.77, fixture version 4, `scv-navigation/1`, `factorio-captured-grid-v1` at 0.5 tiles, Python standard-library Dijkstra/A*. These are reference graph implementations, not a Recast/Detour experiment. Production stays `production-v1`. Actual gates/belts/moving actors are explicitly unsupported by static capture; the historical `gate-open`/`gate-closed` fixtures remain wall-gap geometry.

**Measured results:** Both external algorithms solved the identical 11-case capture with 10 `complete` and one graph-scoped `no-path`. All ten complete results passed the shared collision/trajectory validators and arrived under the native Follower in separate Factorio replays. Every per-case distance matched within `1e-8` tiles. Representative raw graph paths:

| Fixture | Distance (tiles) | Dijkstra expansions | A* expansions |
| --- | ---: | ---: | ---: |
| `open-diagonal` | 27.784888 | 3,733 | 2 |
| `long-wall-return` | 28.253505 | 1,659 | 429 |
| `tight-clearance-corridor` | 23.219122 | 236 | 195 |
| `captured-slalom-return` | 38.358487 | 1,702 | 1,134 |
| `unreachable-box` | no-path | 2,369 | 2,369 |

The raw imported paths are intentionally not geometrically smoothed. `tight` still takes the conservative-grid detour: 23.2191 is worse than the historical production inflated-engine result around 20.17. The Python language boundary does not recover clearance erased by the graph representation. Original source geometry is retained for a genuinely different topology backend.

The loopback headless/RCON probe admitted one result, rejected duplicate/cancelled/prior-session replies, and moved `open-diagonal` to arrival in **133 movement ticks**, error **0.311326 tiles**, actual travel **29.463282 tiles**. Its existing speed-dependent follower bound is **0.3375 tiles**; the solver endpoint eligibility radius remains **0.25 tiles**. These are separate contracts. The first host assertion incorrectly conflated them; capture now pins both before search, and replay rejects any imported execution bound that differs from `Follower.tolerance(actor)`. Neither controller tuning nor endpoint assertion was adjusted to the observed error.

The live fixture snapshot needed **1,128 RCON chunks** at 3,000 payload bytes each. Transfer took **18.225 seconds**, while the measured solver call (including graph validation/hash/setup) took **1.452 seconds**. This establishes a functional live loop, not low-latency RTS interaction. Capture remains synchronous. Cached committed generations, bounded capture work and avoiding repeated whole-world transfer are the next priorities, not another search heuristic.

**Failed hypotheses retained:**

- A 200k-value canonical limit rejected four real fixture graphs; export preserved all failures instead of silently dropping cases. The bounded canonical limit is now one million values/8 MiB per value, while multi-case JSON has a separate limit.
- Publishing fixture metadata through a second generation, encoding the full bundle twice and retaining every graph caused an `on_init` watchdog failure at 180 seconds. Single publication, per-fixture encode/check and bounded retained working data reduced a diagnostic run to 46.4 seconds. The default 90-second per-suite watchdog was not enlarged; success still requires semantic completion.
- Factorio's JSON writer and patched `string.format("%.17g")` can round `0.15 * 1.5` from `0.22499999999999998` to `0.225`. Even `%.0f` rounded a large canonical mantissa. Local Lua tests alone missed the engine-specific formatting behavior. Integer-digit canonical encoding and exact decimal expansion now preserve the binary64 value, with fixed Python vectors and actual Factorio round-trip tests. Old broken captures must be re-exported.
- A Lua-local `needs handshake` flag reset by `on_load` would let a newly joining client cancel a request the host still executes. Session state is now synchronized storage; only the host command rotates it. The headless contract test exercises load-hook invariance. A real second-client/desync test remains unrun.

**Reproduction:** `pwsh -NoProfile -File .\tools\test.ps1 -Suite all` includes smoke, 104 integration assertions, the existing static benchmark, three production-equivalent episodes, capture/replay conformance, 29 Python tests, and six live headless assertions. `tools/navigation/eval.ps1 -KeepArtifacts` separately captures once and imports both solver bundles through isolated Factorio replays. The dynamic `wall-inserted-ahead` episode still expects the known `failed/no-safe-candidate` outcome; passing that baseline is not dynamic recovery.

The first full comparison artifacts are under local `scv-navigation-eval-861abda7e5414edd947603809de2ff66`; the final explicit-execution-contract rerun also passes at `scv-navigation-eval-1c60eea8eb574482be790771e5c5dd97` (33 replay assertions per algorithm). The measured live transport run is `factorio-scv-live-sv1b9q07`; final `all` artifacts are `factorio-scv-agent-test-665c098a4e07404a97d3da1780c5159c` plus `factorio-scv-live-jnt2lm91`. All are under the runner's printed temporary directory. Generated manifests include source/query identity and full replay paths; these machine-specific locations are diagnostic evidence, not checked-in inputs.

**Decision and follow-up:** Keep the implemented boundary and native execution loop, preserve production behavior, and prioritize [live caching/GUI lifecycle #16](https://github.com/guajun/factorio-scv-control/issues/16). Compare a real source-geometry topology backend in [#17](https://github.com/guajun/factorio-scv-control/issues/17). GUI launch remains manual with an isolated matching-mod profile. No ordinary save, existing GUI mod junction, or graphical process was changed by these tests. Real domains remain the existing gate/belt/invalidation issues.

## 2026-09-15 - Industry research exposes objective and backend boundaries

**Question:** Can external game-navigation libraries fit the composable pipeline, and is a serialized polyline plus final cost scoring a sufficient contract?

**Evidence scope:** Source/documentation review against main `852349a`, using the primary references in [game navigation research](navigation-industry-research.md). This entry records a design investigation, not a new runtime experiment. No solver timings, transport probe, or improved arrival results were measured.

**Finding:** The merged pipeline shares request order, validation, and follower behavior, but providers receive no explicit committed NavigationData/query-objective contract. Cost runs after candidate generation; `PlanningRun` currently writes the scalar score into `predicted.distance`. The local search domain is justified for distance improvement, and geometric smoothing has no directed-time preservation contract.

**Rejected assumption:** Replacing the final scorer with travel time, or wrapping an external `findPath`, is sufficient to discover a longer favorable belt route. The distance ellipse can exclude that route; an incompatible search heuristic can distort the objective; smoothing can remove the useful belt section. Exporting only the already-inflated grid would additionally preserve the known narrow-channel loss in every external solver.

**Decision:** Separate observed world facts, committed derived navigation data, and query policy. Pass filter/directed objective into search, retain objective units and transition metadata, and validate the final executable geometry in Factorio. Keep the current production profile as a comparison baseline. Use offline capture/replay before adding live transport; design explicit partial/budget/stale/cancel outcomes rather than treating every missing answer as no-path.

**Next evidence:** [Planned comparisons](navigation-industry-research.md#experiments-and-decision-gates) cover fixture-v4 tight clearance, a longer-faster directed route against a same-graph Dijkstra reference, objective-preserving smoothing, committed world updates, the known inserted-wall failure, and external lifecycle faults. Exact new fixture definitions and acceptance bounds must land before collecting their measurements. [Boundary packages A-E](navigation-solver-boundary.md#evaluation-and-implementation-packages) define dependencies and ownership; real gate and belt calibration remain independently actionable.

## 2026-09-01 - Late wall replanning cannot recover a safe production route

**Question:** Does the current stuck-triggered replan recover after a wall is inserted ahead of a moving character when the episode uses the shared `production-v1` `PlanningRun`?

**Fixture version:** NavigationEpisode fixture version 1, `wall-inserted-ahead`, start `(-12, 0)`, goal `(12, 0)`, and a wall from `(0, -8)` through `(0, 8)` on Factorio 2.0.77.

**Measured result:** The initial run selected the 24-tile `engine-normal` route and predicted 107 travel ticks. The wall action fired 20 episode ticks after planning began. The character reached `(0.0078125, 0)`, detected stuck, and began its first replan 71 ticks after the action at an obstacle distance of `0.0078125`. On that production-equivalent replan, `engine-normal` returned a route that passed actor collision but failed trajectory-envelope validation; `engine-inflated` and `grid-a-star` both returned no-path. The selector terminated with `failed/no-safe-candidate`. Two isolated runs produced the same action, assertion, provider, and terminal ordering.

**Falsified assumption:** The temporary single-engine episode adapter appeared to recover and arrive, but it bypassed the production candidate validation contract and accepted a route from a start already pressed against the new wall. That result was not production-equivalent evidence of dynamic-world recovery.

**Decision:** Phase 1 records `failed/no-safe-candidate` as the semantic baseline and preserves its route, action, position, provider traces, and 71-tick replan latency. Corridor invalidation work in issue #11 must trigger replanning before contact; the episode runner must not add an eval-only proactive replan policy to manufacture an arrival.

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
