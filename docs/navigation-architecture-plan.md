# SC2-like Navigation Architecture Plan

This plan turns SCV Control from a collection of named planner variants into a composable navigation system that can be evaluated headlessly against real Factorio behavior. The target is SC2-like responsiveness for one commanded character, not a claim to reproduce StarCraft II internals.

## Goals

1. Production and evaluation execute the same planning state machine in the same request order.
2. World model, candidate providers, post-processing, validation, cost, selection, trajectory, and replan policy can be combined through static profiles.
3. Static planning quality and complete movement episodes are separate, machine-readable evals.
4. Walls, buildings, gates, belts, and tiles update navigation state without rebuilding the whole world.
5. The default test command stays fully headless and finishes on semantic terminal conditions.
6. Module boundaries and file ownership allow several agents to work in parallel after the shared contracts land.

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
  -> NavigationWorld view + revision set
  -> candidate providers (async or sync)
  -> route post-processors
  -> validators
  -> cost model
  -> selector
  -> accepted Route/Corridor
  -> route action executor
  -> trajectory + follower
  -> invalidation / local avoidance / replan policy
```

The current `path = {positions...}` value becomes a richer route while retaining positions for rendering and legacy callers:

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

### World revisions

World changes are not one undifferentiated dirty flag:

| Revision | Examples | Default response |
| --- | --- | --- |
| `topology` | Wall/building/gate placement or removal, collision-changing tiles | Invalidate a route only if its corridor depends on the dirty region. |
| `motion` | Belt placement, removal, rotation or upgrade; walking-speed tile changes | Existing route remains valid; re-optimize only when predicted benefit justifies it. |
| `transient` | Friendly gate opening/closing, temporary nearby unit | Route stays valid; route actions or local steering respond. |

Moving units do not continuously mutate the static navigation world. They belong to local steering unless they remain blocking long enough for replan policy to promote the obstruction.

## Composable profiles

Profiles store serializable IDs and values, not functions. Factorio storage keeps the profile ID; a static registry resolves implementations after load.

```lua
{
  id = "production-v1",
  world_model = "regional-grid-v1",
  candidate_providers = {
    "engine-normal",
    "engine-inflated",
    "grid-a-star"
  },
  postprocessors = {"safe-string-pull"},
  validators = {"actor-collision", "trajectory-envelope"},
  cost_model = "travel-time-v1",
  selector = "least-cost-safe",
  trajectory = "vector16-v1",
  replan_policy = "revision-aware-v1"
}
```

Registry families should be separate files so adding a cost model does not conflict with adding a follower. A profile must declare capability requirements such as directed edge costs, gate actions, or corridor dependencies. Invalid combinations fail before an eval starts.

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

A new headless suite executes the accepted route with the real character and follower. Episode actions are triggered by state conditions, never by assuming success after a fixed tick count.

```text
setup fixture
  -> issue command through production NavigationSession
  -> wait for actor/route condition
  -> apply world action
  -> observe revision/invalidation/action/replan
  -> finish at arrived/no-path/failed terminal state
```

Target command:

```powershell
pwsh -NoProfile -File .\tools\test.ps1 -Suite episodes
```

`-Suite all` will run smoke, integration, planning benchmark, and episodes. Tick limits remain deadlock guards only.

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
- Add travel-time cost and predicted-versus-actual metrics.
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

- Compare cached regional grid, clearance-aware portals, and navigation-mesh representations.
- Preserve explicit portal width for different actor envelopes.
- Add local moving-unit steering and deadlock episodes.
- Promote a new production profile only after episode and planning regressions pass.

This phase replaces the current candidate portfolio as the primary topology solution; the engine candidates remain baselines and fallbacks.

## Parallel development contract

Phase 0 is the merge barrier. After its schemas land, work can split into three specialist lanes plus one integration owner:

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

1. Phase 0: define schemas and extract the production-equivalent `PlanningRun`.
2. Phase 1: add the episode protocol with a mid-route wall as its first dynamic fixture.
3. In parallel after the contract merge: build gate calibration episodes and belt displacement calibration.
4. Implement semantic gates before switching the custom grid into production for gate-heavy maps.
5. Implement issue #2 on top of directed edge cost, not as a special-case route bonus.

Do not add more named hybrid algorithms to the current benchmark state machine unless needed to preserve a historical baseline. New experiments belong in profiles executed by the shared runner.
