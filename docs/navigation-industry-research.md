# Game Navigation Research and Design Decisions

Research date: 2026-09-15. Repository baseline: `852349a` (`origin/main`). This is a source review and design record; no new solver, transport, or performance experiment was run for this entry. The implementation roadmap is in [the architecture plan](navigation-architecture-plan.md); the proposed process boundary is in [the external solver design](navigation-solver-boundary.md).

## Evidence from game systems

These sources describe public APIs, source code, or the explicitly identified presentation abstract. They do not establish StarCraft II's private implementation or a universal wire protocol.

| System and primary source | What is documented | Decision for SCV Control |
| --- | --- | --- |
| [Recast / Detour](https://github.com/recastnavigation/recastnavigation) | Separate mesh construction, navigation queries, tile-cache updates, and crowd movement components. | Give derived navigation data its own lifecycle, independently of world observation and solver queries. |
| [Detour query interface](https://github.com/recastnavigation/recastnavigation/blob/main/Detour/Include/DetourNavMeshQuery.h) | Query filters participate in traversability and traversal cost. Polygon-path search and straight-path extraction are separate operations. Sliced queries expose bounded search iterations. | Pass filter and objective into search; retain corridor metadata; expose work budgets. |
| [Unity obstacle carving](https://docs.unity3d.com/6000.0/Documentation/ScriptReference/AI.NavMeshObstacle-carving.html) | Stationary obstacles can carve the navigation mesh; moving obstacles can use avoidance, with configurable movement/stationarity criteria. | Distinguish persistent geometry changes from transient occupancy. Calibrate promotion policy instead of copying engine thresholds. |
| [Godot navigation synchronization](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_using_navigationservers.html) | Navigation changes are queued and synchronized; queries can observe the previous synchronized state before updates take effect. | A received world delta and query-ready navigation data need distinct acknowledgements. |
| [Godot path query objects](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_using_navigationpathqueryobjects.html) | Parameters and result objects expose path-query configuration and metadata. Links can identify transitions requiring custom movement handling. | Define explicit query/result values and preserve gate transition IDs through route processing. |
| [Unreal avoidance](https://dev.epicgames.com/documentation/en-us/unreal-engine/using-avoidance-with-the-navigation-system-in-unreal-engine) | RVO and Detour Crowd are alternative avoidance integrations. RVO does not constrain motion to a navigation mesh and can move agents outside its bounds. | Validate the executable motion envelope even when a local avoidance algorithm proposes a collision-free velocity. |
| [Age of Empires IV, GDC 2022 abstract](https://www.gdcvault.com/play/1027659/Pathing-in-Age-of-Empires) | Describes hierarchical A*, flow fields, steering, differently sized units, and changing buildings/walls. Only the abstract was reviewed. | Keep hierarchical topology and steering as separate experiments; flow fields become relevant when commands share goals at scale. |

The surveyed systems expose engine or library interfaces rather than one shared cross-process solver protocol. Our thin interchange contract is a project decision. Using an external process follows from Factorio's sandbox and our experiment workflow; this review does not establish that sidecars are the usual shipping architecture in games.

## NavigationData is a missing boundary

`NavigationWorld` observes Factorio facts, classifies entities, and tracks regional revisions. A grid, portal graph, or Recast mesh is a derived representation with its own approximation and rebuild cost. Treating all of these as one world model obscures both stale data and lost clearance.

The proposed backend owns build/update, committed revision, actor-envelope configuration, cache identity, and disposal. A solver queries an immutable committed view. A backend may be local Lua, an external library, or an opaque engine adapter with explicitly limited capabilities. Engine request results must not claim access to engine polygon references or internal revision acknowledgements.

An export should preserve the observed bounded geometry and semantic facts, with derived grids as optional artifacts. Exporting only the current inflated grid would make every external solver inherit its erased narrow passages. Unknown or unsupported geometry must be represented explicitly. A failed search over a conservative representation is not proof that the character cannot physically pass.

## Search objectives affect more than scoring

Current `PlanningRun` invokes the cost model after providers and post-processing. `grid-a-star` calls the baseline-dependent distance search in `LocalPlanner`. A future travel-time scorer can compare candidates already generated, but cannot cause that search to discover a missing favorable belt detour.

Three additional boundaries matter:

1. **Search bounds.** The current ellipse follows from the triangle inequality for a route shorter than baseline length `L`. A faster route can be longer than `L`. For a positive time objective, a verified upper bound on achievable speed `v_max` and feasible incumbent time `T` imply `length <= v_max * T` for any improving route; this can justify a different domain. Without such a bound, use explicit bounded-domain search or widening and report the coverage limitation. Teleports or unmodelled movement invalidate this derivation.
2. **Heuristic.** `distance / v_max` is a possible time lower bound only when the speed bound covers every permitted transition and movement effect. `h = 0` is the graph-search reference where that proof is unavailable. The [Detour implementation](https://github.com/recastnavigation/recastnavigation/blob/main/Detour/Source/DetourNavMeshQuery.cpp) uses a distance-based heuristic and warns about costs below its distance scale. A custom `getCost` callback alone does not prove suitability for arbitrary belt costs.
3. **Post-processing.** A geometric shortcut can leave a fast belt, remove a gate action, or alter a cost-boundary crossing. Preserve mandatory transitions, then recompute the same objective and validation on the final geometry. Reject a proposed optimization that worsens that objective, unless the profile explicitly budgets an approximation and reports it.

For heterogeneous or directional travel costs, a polygon corridor plus ordinary geometric funnel is not an automatic continuous-time optimum. Compare graph-search correctness against Dijkstra on the identical graph, and measure final travel in Factorio separately. Neither comparison proves a global continuous optimum.

The current `process_candidate` also assigns the scalar score to `route.predicted.distance`. The new contract must carry objective ID, units, distance, predicted ticks, and individual components explicitly; adding a time scorer without adapting that assignment would mislabel time as distance.

## Corridors and actions survive execution

A corridor provides traversable geometry and dependency information beyond a rendered polyline. Portable region/entity dependencies should survive alongside backend-specific polygon or portal references, which are valid only for their backend generation. Repair or regeneration must produce corresponding new dependencies.

A friendly gate is a conditional passage through real geometry. Its transition carries actor-force eligibility, expected delay, entry/exit, and an allowed action. The adapter may use an off-mesh link or a normal conditional edge, but must not create a bypass around collision validation. Test against a real gate; historical `gate-open` and `gate-closed` wall-gap fixtures are insufficient.

Factorio remains the movement authority. The [Detour Crowd documentation](https://github.com/recastnavigation/recastnavigation/blob/main/DetourCrowd/Include/DetourCrowd.h) describes ownership of agent position and velocity as an integration constraint. Our character is moved by native commands and engine effects such as belts. Therefore test a steering/controller adapter against observed displacement before adopting a crowd subsystem. Do not copy crowd positions into the character to make an episode pass.

## Factorio process boundary

The [Factorio Lua library restrictions](https://lua-api.factorio.com/latest/auxiliary/libraries.html) exclude ordinary OS/file-library access and arbitrary native-module loading. A registry's Lua module can nevertheless implement a transport-backed candidate provider. The registry does not need to load Python, C++, or Rust directly.

Recommended rollout:

| Stage | Transport and scope | Evidence required |
| --- | --- | --- |
| Offline interchange | Export snapshot/query JSON, run external solvers, validate results, and import a generated data-only companion module on the next isolated load. | Identical input hashes, exact replay through shared validation/follower, no runtime file-read assumption. |
| Live headless experiment | Host runner owns solver plus Factorio server; use [RCON](https://wiki.factorio.com/Command_line_parameters) to exchange bounded structured messages through a fixed adapter. | Correlation, cancellation, stale-world handling, lost-process recovery, and deterministic recorded replay. |
| Optional GUI-connected experiment | GUI joins the isolated server, or replays the same captured offline artifacts locally. | Same profiles, fixtures, validators, and report IDs as headless; GUI never starts from the default test command. |
| Optional UDP transport | [LuaHelpers](https://lua-api.factorio.com/latest/classes/LuaHelpers.html) documents localhost send/receive enabled per instance. | Probe the exact installed binary in headless mode, then test message loss/order/size and synchronized acceptance before adoption. |

The linked Factorio `latest` documentation is rolling; this repository's previous engine evidence used 2.0.77. Documentation availability is not a successful local transport probe. Transport choice remains conditional on that probe. Keep the distributable mod's local profile usable without an external service.

## Experiments and decision gates

All entries below are **planned**, with no new measured result. Freeze exact geometry, actor parameters, solver versions, configurations, and acceptance bounds in the fixture commit before running a comparison.

| Experiment | Comparison | Required evidence / failure exposed |
| --- | --- | --- |
| Clearance representation | Existing fixture-v4 `tight-clearance-corridor`, normal/inflated engine, grid, then portal/navmesh | Replay local start `(9.9296875, -9.87890625)` to goal `(9.9296875, 9.8671875)`. Retain historical safe-distance baselines 20.17 / 22.14 as recorded evidence, not new measurements. Check actual arrival and clearance. |
| Search objective | Same directed graph with Dijkstra, admissible A*, and a geometry-only control | Longer favorable route wins on predicted graph time and measured belt episode time. Log distinct graph-optimal and physical prediction errors. |
| Post-processing | Raw route versus geometric and objective-preserving smoothing | Belt benefit and mandatory gate transitions survive. Record both costs and validation after every geometry change. |
| World synchronization | Full rebuild versus staged local deltas | A query sees one committed generation. Duplicate, missing, and out-of-order deltas never produce mixed-generation routes. |
| Dynamic execution | Existing `wall-inserted-ahead` baseline versus dependency-aware profile | Preserve historical expected failure; new profile replans before contact and arrives. Off-corridor insertion does not replan. |
| External lifecycle | Recorded answers versus delayed, reordered, truncated, cancelled, and crashed solver | Every request reaches an explicit terminal outcome; stale/partial/malformed answers cannot become accepted full routes. |
| Local steering | Bounded transient actors with native movement and belt drift | Clearance, arrival, direction changes, cross-track error, and deadlock termination. No teleport-based success. |
| Amortized work | Repeated local requests, longer commands, and construction bursts | Separate export, bake/update, search, validation, transport, and execution time; measure cold/warm cache and rebuild area. |

Promote an external or new topology profile only after it passes the shared static and movement suites on its declared capabilities. Report unsupported cases alongside failures, include setup/update cost, and retain the current production profile as the versioned comparison baseline.
