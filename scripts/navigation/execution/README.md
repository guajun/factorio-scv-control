# Remaining corridor invalidation

`corridor.lua` is an actor-agnostic, serializable policy module. It neither subscribes to game events nor performs planning or movement. The experimental TestKit adapter composes it with `NavigationWorld`, the existing episode `PlanningRun` adapter, and the production `Follower`.

## Contract

1. `new(surface_index, actor_box, trajectory_margin, budgets)` stores an asymmetric actor collision box expanded by the existing trajectory clearance margin. Budgets are explicit work limits, not route quality thresholds.
2. `attach(state, route, start, world)` records the accepted polyline envelope, regional revision dependencies, and world revisions; existing dependencies are retained. It does not query every entity along the route or invent engine polygon references.
3. `enqueue(state, normalized_mutation, tick, revisions)` groups edits by effect and region, retaining exact member boxes. The group union is diagnostic metadata, not a replacement collision obstacle. Only explicit entity removals relax topology; unknown replacements/teleports conservatively require validation.
4. `immediate_check(...)` intersects an edit with the remaining actor/trajectory envelope under an event budget. It excludes traversed segments and uses the actor's current position for the active segment. `blocked` requires stopping immediately; `budget-hold` requires a precautionary stop until bounded scanning completes.
5. `advance(...)` checks pending edits under group and segment/box budgets. Blocking topology returns `replan`; untouched corridors continue. Only unexamined potentially blocking work returns `hold`. Removal, motion, and transient notifications do not cause topology replanning or pause movement by themselves.

The intersection is a segment against the Minkowski-expanded rectangle, not a path-segment bounding-box test. Duplicate edits do not reset an active scan; updates to another group do not reset its cursor. Queue/member overflow fails closed with an explicit `dirty-budget-overflow` replan instead of silently discarding edits.

The adapter stops within the synchronized `script_raised_built` event and calls the shared `Adapter.replan` on the next update. That hook cancels any outstanding shared run before starting a replacement. Events during planning remain queued; a newly accepted route is checked before the follower advances. Replanning validates the current live world, allowing a same-burst batch to produce a single replacement plan.

## Bounded evidence and remaining scope

The isolated `corridor-execution` scenario has five native episodes and thirteen policy assertions; each report marks `metrics.native_execution`. It emits `SCV_CALIBRATION_COMPLETE domain=dynamic` and `script-output/scv-control/calibration/dynamic.json`. The calibration host repeats the complete report and compares all case fields.

This is not production event wiring, asynchronous external-map rebuilding, gate action handling, moving-unit steering, belt compensation, or a travel-time optimization policy. The forward-belt episode is deliberately aligned with movement and demonstrates only motion-event routing plus successful native execution in that fixture. Motion feasibility and transient-response consumers must be composed before enabling the policy in a general dynamic world. An event flood is bounded per event and update; it is not a factory-scale total frame-time guarantee.

See [the experiment record](../../../docs/experiments/dynamic-corridor-2026-09-15.md) for measurements and failed intermediate assumptions.
