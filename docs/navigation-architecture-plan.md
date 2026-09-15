# SC2-like Navigation Architecture Plan

This plan turns SCV Control from a collection of named planner variants into a composable navigation system that can be evaluated headlessly against real Factorio behavior. The target is SC2-like responsiveness for one commanded character, not a claim to reproduce StarCraft II internals.

Updated 2026-09-15: base main `852349a`, plus the `codex/navigation-framework` implementation. The [game navigation research](navigation-industry-research.md) records primary sources and design implications. The [external solver boundary](navigation-solver-boundary.md) distinguishes the implemented bounded subset from remaining target capabilities. Test evidence is recorded in the experiment log; unimplemented domain features are not implied by the new transport.

## Implementation checkpoint

| Work | Implementation status | Remaining boundary |
| --- | --- | --- |
| Phase 0 contracts and registries ([#4](https://github.com/guajun/factorio-scv-control/issues/4)) | Merged in PR #13. | Version 1 describes the local Lua pipeline; it is not an external problem/response protocol. |
| Shared PlanningRun ([#5](https://github.com/guajun/factorio-scv-control/issues/5)) | Merged in PR #15; framework adds separate external completion tokens, pinned queries, and per-provider capability checks. | Production retains its original profile. External profiles currently execute only static distance objectives. |
| Headless episodes ([#6](https://github.com/guajun/factorio-scv-control/issues/6)) | Merged in PR #12; included in `-Suite all`. Shared PlanningRun and production Follower execute through an episode adapter. | Session orchestration is still adapter glue, not a fully extracted production NavigationSession. The inserted-wall case expects `failed/no-safe-candidate`; a passing suite does not demonstrate dynamic recovery. |
| Incremental world ([#7](https://github.com/guajun/factorio-scv-control/issues/7)) | Module and engine-backed assertions merged in PR #14. | Regional cache/event handling is not wired into production planning. Derived-backend commit synchronization is a separate extension. |
| Gates, belts, corridor invalidation | [#8](https://github.com/guajun/factorio-scv-control/issues/8), [#9](https://github.com/guajun/factorio-scv-control/issues/9), [#10](https://github.com/guajun/factorio-scv-control/issues/10), [#2](https://github.com/guajun/factorio-scv-control/issues/2), [#11](https://github.com/guajun/factorio-scv-control/issues/11) remain open. | Real-domain calibration and production composition remain required. |
| External solver boundary | Framework adds `scv-navigation/1`, committed captured-input generations, exact JSON export, imported/external providers, and shared validation/follower replay. | NavigationData is not a mesh builder; its staged delta tests do not prove production-world cache integration. |
| Solver comparison | Python Dijkstra/A* consume the same captured graph. The domain follow-up adds an optional extremitypathfinder/GEOS source-polygon backend; its ten complete routes pass native replay across the 11-case catalog. | Static stone-wall/tile domain only. Dynamic update, memory, larger worlds and live production integration remain follow-up work. |
| Live test lab | Isolated headless host, server-only bulk snapshot file, short RCON control/result messages, fixture commands and GUI spectator adapter. | Test-map-only. Capture is still synchronous and cold per request. Not ordinary-save right-click replacement, arbitrary dynamic-world solving, or production deployment. |

The original Phase 0 merge barrier is satisfied. The framework implements the additional boundary prerequisite for interchangeable search backends; broader domain and lifecycle gates remain explicit. Consult the newest experiment-log entry for executed tests and unresolved failures rather than interpreting a source module's presence as validation.

The native calibration/topology wave is PR #19, stacked on the unmerged PR #18 framework. Its next execution wave develops conditional gate actions, remaining-corridor invalidation, and calibrated belt control in parallel. The [domain execution design](navigation-domain-execution-plan.md) specifies each scheme and its promotion barriers. The user accepted the faster bulk transport as sufficient to unblock these experiments; remaining #16 latency work is not their prerequisite. #16 still owns cached queries, test-map input and GUI lifecycle. Keep live transport and topology implementations isolated; the integration owner alone changes common registries/reports/default profiles. See [project progress](project-progress.md) for branch/validation boundaries.

## Goals

1. Production and evaluation execute the same planning state machine in the same request order.
2. World model, candidate providers, post-processing, validation, cost, selection, trajectory, and replan policy can be combined through static profiles.
3. Static planning quality and complete movement episodes are separate, machine-readable evals.
4. Walls, buildings, gates, belts, and tiles update navigation state without rebuilding the whole world.
5. The default test command stays fully headless and finishes on semantic terminal conditions.
6. Module boundaries and file ownership allow several agents to work in parallel after the shared contracts land.
7. Navigation data, search filters/objectives, and execution have explicit contracts that work for local and external solvers.
8. Comparisons include representation loss, update/setup cost, incomplete results, and real movement outcomes.

## Verified Factorio constraints

- `LuaSurface.request_path` is asynchronous. Its `force` determines which gates can be opened, and `can_open_gates=true` permits such routes. Production already sets this flag.
- A gate has separate closed and opened collision behavior. Runtime code can inspect its state and call `request_to_open(force, extra_time)`.
- Normal gates automatically react to nearby characters, but automatic timing may be insufficient for fast characters. The follower should be able to request opening before contact.
- Entity/tile build, mine, death, rotation, clone, script-raised, and surface lifecycle events provide the inputs for incremental world invalidation.
- Pathfinder request caching can miss environment changes. Production requests currently use `cache=false`; keep this until our invalidation contract is proven.

References:

- [LuaSurface.request_path](https://lua-api.factorio.com/2.0.77/classes/LuaSurface.html#request_path)
- [LuaEntity gate state and request_to_open](https://lua-api.factorio.com/2.0.77/classes/LuaEntity.html#request_to_open)
- [Gate opened collision mask](https://lua-api.factorio.com/2.0.77/prototypes/GatePrototype.html#opened_collision_mask)
- [Factorio gate behavior](https://wiki.factorio.com/Gate)
- [Runtime events](https://lua-api.factorio.com/2.0.77/events.html)

Circuit-controlled, enemy-force, and unusually fast gate behavior must be calibrated in headless episodes before becoming policy. Do not infer those cases only from the normal gate.

The existing fixtures named `gate-open` and `gate-closed` contain only a wall gap and a wall filling that gap. They do not create a Factorio `gate` entity and provide no evidence about automatic gate behavior. Preserve them as historical dynamic-static geometry baselines, but rename/deprecate them when true gate episodes are added.

## Target pipeline

```text
Move command
  -> NavigationWorld facts + coverage + revision set
  -> NavigationData backend build/update -> committed generation
  -> NavigationQuery (actor, filter, directed objective, budget)
  -> candidate providers (local or external, async or sync)
  -> correlated result admission (identity, coverage, status, freshness)
  -> route post-processors (preserve objective and transitions)
  -> live collision / trajectory / conditional-transition validators
  -> final cost under the query objective
  -> selector
  -> accepted Route/Corridor
  -> route action executor
  -> trajectory + follower
  -> invalidation / local avoidance / replan policy
```

The richer route contract already retains positions for rendering and legacy callers. This abbreviated target shape illustrates the additional data to populate; versioned implementation rules live in the extension contract:

```lua
{
  status = "success",
  points = {},
  corridor = {},
  actions = {},
  dependencies = {},
  predicted = {distance = 0, travel_ticks = 0},
  world_revisions = {topology = 0, motion = 0},
  source = "engine-inflated",
  metrics = {}
}
```

### NavigationData and committed queries

`NavigationWorld` owns observed geometry and semantics; a `NavigationData` backend owns the derived grid, portals, mesh, or opaque engine query representation. Its identity includes source snapshot/revisions, actor envelope, build settings, and generation. A received world update becomes queryable only when its derived generation is committed. Do not join cells or polygons from partially updated generations.

Export observed facts with explicit bounds and unknown geometry. Preserve the original facts alongside optional derived grids so a portal/navmesh experiment does not inherit the current grid's lost clearance. Backend-specific references remain scoped to their generation; routes also carry portable region/entity dependencies. An opaque Factorio engine backend declares unavailable information instead of manufacturing mesh references or revision guarantees.

### QueryPolicy and objective consistency

Search receives traversability filters, conditional actions, objective ID/units, directed cost data, coverage, and resource limits. Final route scoring uses the same objective after all geometry changes. A geometry-only provider can remain a labelled control, but cannot claim directed travel-time search because another provider in its profile supplies that capability.

The current distance-based search ellipse cannot bound a longer-but-faster belt route. Travel-time profiles must use a justified time/speed bound or explicit bounded coverage, with incomplete coverage reported. Heuristic admissibility, budget/approximation, and post-processing must be declared per profile. A zero-heuristic search is the reference when a lower bound is unproven. Geometric smoothing must not discard a favorable belt or mandatory gate transition.

Keep objective value, units, distance, predicted ticks, and measured ticks separate. The framework now recomputes geometric `predicted.distance` independently and records query score/units in `route.values.scored_objective`. A live time scorer and calibrated motion model are still required before enabling a travel-time execution profile.

### External solver and authoritative execution

Implement external libraries behind a Lua provider adapter. Start with bounded snapshot/query export and offline result replay, then prove a headless RCON completion path. UDP and live GUI connectivity require their own exact-version probes. The default local profile remains self-contained, and the default test command remains GUI-free.

The [boundary design](navigation-solver-boundary.md) defines request/session identity, committed generations, partial/budget/no-path distinctions, cancellation, save/load, provider capability checks, live validation, and recorded replay. External answers use the same acceptance and follower pipeline. A solver's success means a complete candidate was produced; only Factorio movement can establish episode arrival.

### World revisions

World changes are not one undifferentiated dirty flag:

| Revision | Examples | Default response |
| --- | --- | --- |
| `topology` | Wall/building/gate placement or removal, collision-changing tiles | Invalidate a route only if its corridor depends on the dirty region. |
| `motion` | Belt placement, removal, rotation or upgrade; walking-speed tile changes | Refresh motion prediction and controller feasibility. Geometric connectivity may remain valid; optional cost optimization is distinct from a required response to unsafe drift. |
| `transient` | Friendly gate opening/closing, temporary nearby unit | Route stays valid; route actions or local steering respond. |

Moving units do not continuously mutate the static navigation world. They belong to local steering unless they remain blocking long enough for replan policy to promote the obstruction.

## Composable profiles

Profiles store serializable IDs and values, not functions. Factorio storage keeps the profile ID; a static registry resolves implementations after load.

```lua
{
  id = "production-v1",
  world_model = "live-surface-local-grid-v1",
  candidate_providers = {
    "engine-normal",
    "engine-inflated",
    "grid-a-star"
  },
  postprocessors = {"safe-string-pull"},
  validators = {"actor-collision", "trajectory-envelope"},
  cost_model = "polyline-distance-v1",
  selector = "least-cost-safe",
  trajectory = "vector16-v1",
  replan_policy = "stuck-retry-v1"
}
```

Registry families should be separate files so adding a cost model does not conflict with adding a follower. A profile must declare capability requirements such as directed edge costs, gate actions, or corridor dependencies. Invalid combinations fail before an eval starts.

The example above abbreviates the implemented `production-v1` profile. Future backend/query-policy composition and travel-time behavior use a new profile and explicitly versioned schema changes; do not silently redefine `production-v1`. See the [implemented extension contract](navigation-extension-contract.md) for current fields, and the [boundary draft](navigation-solver-boundary.md) for proposed per-provider capability checks.

## Gates are conditional transitions

A closed friendly automatic gate is not a wall. It is a conditional transition:

```lua
{
  traversable = true,
  condition = "gate-openable-by-force",
  expected_delay_ticks = opening_delay,
  action = {type = "request-gate-open", unit_number = gate.unit_number},
  dependency = {kind = "gate", unit_number = gate.unit_number}
}
```

Planning and validation must distinguish:

| Gate case | Topology | Execution |
| --- | --- | --- |
| Open/opening friendly gate | Passable | Continue; extend open request when useful. |
| Closed/closing friendly automatic gate | Conditionally passable | Request opening before arrival; include delay in cost. |
| Gate not openable by actor force | Blocked | Find another route or report no path. |
| Gate removed | Depends on replacement geometry | Increment topology revision in its region. |

The current engine candidate already supports gates, but the sampled grid and collision validator see only the closed collision state. Gate semantics must be implemented once in `NavigationWorld` and consumed by grid capture, smoothing validation, and route execution.

Gate open/close animation is transient state, not a topology revision. Otherwise every automatic close would cause pointless global replanning.

## Directed motion and belts

Belts create a directed motion field rather than binary traversability. The edge API must support asymmetric cost:

```text
cost(A -> B) != cost(B -> A)
```

The first cost model should predict travel ticks by combining commanded character motion with the belt vector along each edge. It must respect belt immunity and record its prediction separately from measured episode time.

The model must also check whether native controls can realize the directed edge under lateral drift. A vector projection giving favorable forward speed is insufficient if the actor cannot remain in the corridor. Use the calibrated motion model in search, trajectory validation, and episode prediction. Record geometry-only controls explicitly.

Required belt fixtures:

| Fixture | Expected property |
| --- | --- |
| Longer favorable belt detour | Travel-time profile chooses the longer but faster route. |
| Reverse belt | Planner accounts for delay or avoids it. |
| Cross belt | Follower compensates for lateral drift without leaving the corridor. |
| Diagonal entry/exit | No oscillation at motion-field boundaries. |
| Belt tiers | Predicted cost changes monotonically with belt speed. |
| Belt built/removed/rotated mid-route | Motion revision changes; route validity and optional optimization remain distinct. |

Actual Factorio movement is the oracle. A planner passes only when its prediction and the real follower outcome agree within an explicit fixture bound.

## Evaluation architecture

### Planning benchmark

The existing fixture benchmark remains responsible for static route generation:

- candidate success/no-path;
- collision and trajectory validation;
- predicted distance and travel ticks;
- engine requests, expanded nodes, geometry queries, and duration;
- selected source and world/profile versions.

It must call the same `PlanningRun` state machine used by production. In particular, provider request order cannot be recreated separately in TestKit.

### Navigation episodes

The merged headless episode suite executes the accepted route with the real character and follower. Episode actions are triggered by state conditions, never by assuming success after a fixed tick count. The sequence below describes the target shared session; current production and episode adapters still own some separate orchestration glue.

```text
setup fixture
  -> issue command through production NavigationSession
  -> wait for actor/route condition
  -> apply world action
  -> observe revision/invalidation/action/replan
  -> finish at arrived/no-path/failed terminal state
```

Available command:

```powershell
pwsh -NoProfile -File .\tools\test.ps1 -Suite episodes
```

`-Suite all` runs smoke, integration, planning benchmark, and episodes. Tick limits remain deadlock guards only. See the [episode module](../devmods/scv-control-testkit/episodes/README.md) for implemented fixture, service, and report contracts; the following metrics are the target catalog, not a claim that every domain metric is populated today.

Episode reports include:

- reached terminal state and arrival error;
- actual and predicted travel ticks;
- path distance and selected profile/source;
- world action tick and revision;
- invalidation-to-replan latency;
- distance from obstacle when replan began;
- replan, stuck, recovery, and route-action counts;
- maximum cross-track error and direction switching;
- deterministic request sequence and per-stage work metrics.

Reports use a versioned JSON schema and retain the isolated root on failure. Every fixture runs on a fresh/reset surface and asynchronous engine providers run serially unless a fixture explicitly tests scheduling.

### Cross-backend comparison

Keep static route quality and closed-loop execution as separate reports with common snapshot/query/profile identities. A captured GUI case exports the same fixture geometry used headlessly. Imported external results receive the same final validators, scorer, and follower; GUI preview adds no solver-specific acceptance path.

Report source geometry and derived representation settings, raw/final routes, objective and units, coverage, partial/budget/unsupported outcomes, input hashes and versions, cold/warm build/update/search work, transport delay, validation cost, and measured arrival. Dijkstra on the same graph is an objective reference; Factorio is the execution oracle. Comparing algorithms on different graph resolutions must expose that difference rather than attribute all gains to search.

The [research experiment matrix](navigation-industry-research.md#experiments-and-decision-gates) is planned work. Preserve known failures such as `wall-inserted-ahead` in the versioned baseline when adding a new profile that is expected to recover.

### Dynamic-world fixture catalog

| Fixture | Required assertion |
| --- | --- |
| Friendly closed gate | Planner chooses the gate; follower requests/causes opening and arrives without stuck replan. |
| Gate versus detour | Gate opening delay is compared with the detour's predicted time. |
| Non-openable gate | Planner treats it as blocked. |
| Wall built across active corridor | Route invalidates and replans before collision. |
| Wall built outside corridor | No replan. |
| Blocking wall removed | Route remains valid; optional optimization follows policy. |
| Belt shortcut added | Motion revision updates; optimization occurs only when benefit threshold is met. |
| Belt rotated under active route | Follower remains stable and cost prediction is refreshed. |
| Temporary actor blocks corridor | Local response precedes global replan. |

## Delivery phases

### Phase 0: Shared contracts and production-equivalent PlanningRun

Status: complete on main through issues #4 and #5. The following criteria describe the original merge barrier; the external boundary extension is separate.

- Define versioned profile, route, candidate, validator, metric, and terminal-result schemas.
- Extract engine request sequencing and candidate collection from `scripts/planner.lua` into a shared `PlanningRun`.
- Make production and TestKit invoke that exact state machine.
- Preserve current behavior and benchmark numbers before introducing new algorithms.

Exit criteria:

- existing `-Suite all` passes;
- production and benchmark use the same profile and provider order;
- a trace assertion proves identical candidate request/result sequencing;
- adding a synchronous planner requires a new module/profile, not new benchmark control-flow branches.

### Phase 1: Headless NavigationEpisode runner

Status: baseline suite complete through issue #6. It uses shared PlanningRun/Follower with adapter-owned session glue. A fully shared NavigationSession remains integration work; dynamic recovery is not part of this phase's proven behavior.

- Add condition-driven episode actions and terminal states.
- Add versioned episode JSON and console completion protocol.
- Run the current follower through the production NavigationSession.
- Add baseline static, unreachable, and mid-route wall episodes.

Exit criteria:

- `-Suite episodes` is GUI-free and repeatable;
- `-Suite all` includes it;
- failures retain exact action/route/follower traces;
- no episode passes because a fixed number of ticks elapsed.

### Phase 2: Incremental NavigationWorld and gate semantics

Status: issue #7's world module is merged; production event/cache integration and issues #8/#9 remain open.

- Introduce regional topology/motion/transient revisions and dirty bounds.
- Subscribe to player, robot, script-raised, death, rotation, tile, clone, and surface events.
- Represent gates as conditional transitions using opened collision geometry.
- Add proactive gate actions to route execution.
- Calibrate normal, fast, circuit-controlled, and force-incompatible gates headlessly.
- Replace the misleading historical gate fixture names with dynamic-gap names and add real gate entities in the episode catalog.

Exit criteria:

- all gate episodes pass for engine and custom-grid profiles where applicable;
- closing an automatic gate does not invalidate its route;
- a wall or non-openable gate does invalidate only intersecting corridors;
- no full-surface rescan occurs for a local entity event.

### Phase 3: Directed motion field and belt-aware cost

- Add directed `edge_cost`/motion queries to NavigationWorld.
- Calibrate character displacement on belt tiers and directions in headless Factorio.
- Pass the calibrated objective into provider search and final scoring with explicit units.
- Replace distance-only search bounds/heuristics where unjustified; preserve cost and actions through post-processing.
- Add travel-time prediction, drift feasibility, and predicted-versus-actual metrics.
- Implement the fixtures from [GitHub issue #2](https://github.com/guajun/factorio-scv-control/issues/2).

Exit criteria:

- favorable longer belt routes beat geometric shortest paths in measured arrival time;
- reverse/cross-belt fixtures remain stable;
- cost-changing belt events do not masquerade as topology invalidation;
- prediction error stays within fixture-specific measured bounds.

### Phase 4: Corridor invalidation and replan policy

- Store region/entity dependencies with accepted routes.
- Separate urgent invalidation from optional route optimization.
- Add debounce/budget policy for factory-scale event bursts.
- Promote persistent local blockage to global replan only after steering policy expires.

Exit criteria:

- on-route construction replans before impact;
- off-route construction causes no replan;
- opening a shortcut does not cause route churn;
- reports bound replan latency and work per world event.

### Phase 5: SC2-like topology and local steering experiments

- Compare cached regional grid, clearance-aware portals, and navigation-mesh backends on shared bounded source geometry.
- Start with offline external-library adapters and recorded replay; prove a headless live transport before interactive external planning.
- Compare graph-optimality, representation loss, and actual execution separately, including build/update cost.
- Preserve explicit portal width for different actor envelopes.
- Add local moving-unit steering and deadlock episodes.
- Promote a new production profile only after episode and planning regressions pass.

This phase replaces the current candidate portfolio as the primary topology solution; the engine candidates remain baselines and fallbacks.

### Boundary extension: NavigationData, QueryPolicy, and solver interchange

This work can start now; it does not require finishing every gate/belt feature. It establishes the additional contracts needed by Phase 3 and cross-backend Phase 5 experiments. Calibration in issues #8 and #10 can proceed independently.

Deliver packages A through E from the [boundary design](navigation-solver-boundary.md#evaluation-and-implementation-packages): shared contract/admission changes; bounded capture/replay; solver comparison; live transport; domain composition. A is the new merge barrier. After A/B, independent solver and transport adapters can proceed alongside domain work.

Exit criteria:

- existing `production-v1` behavior and trace baselines remain reproducible;
- provider-specific preflight rejects unsupported objective/backend combinations;
- every answer identifies a committed world generation and active request;
- timeout, partial output, malformed data, cancellation, and scoped no-path remain distinguishable;
- imported routes pass shared live validation and native follower episodes;
- default tests stay local/headless, with an explicit GUI replay/join path;
- experiment reports include end-to-end work and failed cases, not only successful solver timings.

## Parallel development contract

The original Phase 0 merge barrier has landed. Domain work can use the following lanes; extensions to backend/query/transport contracts first pass boundary package A. Package ownership in the boundary design refines these lanes for external experiments:

| Lane | Owns | Avoids |
| --- | --- | --- |
| Core orchestration and execution | profile schemas, registry composition, `PlanningRun`, route actions, follower adapter, production integration | domain-specific gate/belt algorithms |
| Eval infrastructure | episode runner, report protocol, artifact parser, generic assertions | production planner decisions |
| World/gates | regional revisions, event normalization, gate transition provider and gate episodes | belt cost and TestKit runner core |
| Motion/belts | belt calibration, directed cost model, belt profiles and belt episodes | gate semantics and production adapter |

Central hot files have a single integration owner:

- `control.lua`;
- `tools/test.ps1`;
- registry indexes and default production profile;
- common report schema;
- `AGENTS.md`.

Domain fixtures live in separate files such as `episodes/gates.lua`, `episodes/belts.lua`, and `episodes/dynamic_world.lua`. Agents add implementations and profiles without editing a single monolithic algorithm list. The integration owner wires completed modules into central indexes after their focused suites pass.

Each work package must contain:

1. one narrow module contract or implementation;
2. focused headless assertions and fixture ownership;
3. machine-readable metrics, not screenshot-only evidence;
4. an experiment-log entry when an assumption is confirmed or falsified;
5. `pwsh -NoProfile -File .\tools\test.ps1 -Suite all` before merge.

## Immediate backlog

1. Integration owner: review the already implemented A/B foundation in PR #18 and keep its existing production behavior and measured regression baselines intact. It remains unmerged; stacked experiments must state this dependency.
2. Calibration owners: finish real gates (#8) and belt displacement (#10) independently. First bounded native probes are in the domain-calibration wave, not production gate/belt policy; circuit/equipment/entry-exit/dynamic cases remain explicit.
3. Topology owner: implement one pinned third-party source-geometry backend (#17), compare every fixture-v4 case and replay through shared validation/follower. Do not attribute graph representation changes to a language change.
4. Live owner: continue #16 committed-map reuse, bounded capture, test-map input, pending-world changes and GUI lifecycle. Bulk-file transport already removes the 1,128-command transfer bottleneck; cold end-to-end latency remains roughly ten seconds in the diagnostic probe.
5. World/execution owners: wire regional revisions and corridor invalidation (#11), implement calibrated semantic gates (#9), and route actions. Test proactive recovery separately from the preserved failure baseline.
6. Motion owner: implement #2 using query-time directed cost, justified bounds, objective-preserving post-processing, and calibrated native controller feasibility; then exercise supported local/external profiles (E).

Do not add more named hybrid algorithms to the current benchmark state machine unless needed to preserve a historical baseline. New experiments belong in profiles executed by the shared runner.
