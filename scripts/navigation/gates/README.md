# Conditional gate action slice

`semantics.lua` is the single eligibility rule for this experiment. It accepts
one same-force automatic gate, with no configured control on adjacent walls.
Different forces are blocked; configured wall control, connected gate chains,
unknown neighbours, removed gates and unsupported actors are explicit outcomes.
Sensor-only control is conservatively unsupported too. This is not a claim
that those gates can never be crossed. Gate opening/closing is a transient
condition and leaves the semantic dependency on the gate entity intact.

`action.lua` executes one authored cardinal segment through that gate. Its
entry and exit planes come from the gate's observed bounding box inflated by
the actual character collision box. It has no hand-placed detour/via points.
The caller supplies an opening calibration with engine/prototype identity.
For the measured base 2.0.77 `gate`, full opening takes 16 simulation ticks.
This parameter is measured input, not a universal assertion about modded gates.
Runtime 2.0.77 lacks `LuaEntityPrototype.opening_speed` and
`opened_collision_mask`; current online docs expose these as newer additions.

The caller invokes `Action.step(actor, state)` before `Follower.advance` every
tick. Opening is requested when contact distance is at most
`running_speed * (opening_ticks + 1) + 1/256` tiles. The extra tick is the next
movement step; 1/256 is the native position quantum. If one more step could
reach the unopened gate, the action stops native walking until the gate is
actually open. Requests are renewed through the crossing with a hold derived
from remaining exit distance/speed plus the opening bound. This avoids relying
on one early request preserving its original hold duration, which the earlier
calibration disproved. Failure to open by the supplied bound requests replanning;
time passing is never success. The first expected delay is reported separately
from actual waiting ticks and is zero for an already opened gate.

Every step rechecks eligibility, entity identity and observed gate bounds.
Force/control/geometry changes or removal stop movement and return `replan`.
The integration owner must discard that action and obtain a fresh admitted
route. Completing the crossing only completes this action; the shared Follower
still owns arrival at the command goal. This action does not implement
replanning, whole-world revisions, a new search backend, or route admission.

## Important admission boundary

The existing production collision validator uses the gate **prototype's
closed collision mask even when the entity is open**. It currently rejects
these routes. This experiment preserves that validator and asserts its rejection
in both states; it never imports or accepts a route through an alternative
PlanningRun path. Its authored straight segments are native follower/action
tests, not planner support and not a production profile.

The next integration step must make capture, smoothing, final collision and
trajectory validation consume this one semantic rule and explicit conditional
transitions. Only the eligible gate collision may use calibrated opened
geometry; neighbouring walls, tiles and unknown entities must still collide.
Validators must verify the waiting/approach envelope and retained action,
and delay-aware route scoring must compare the gate with detours. Full issue
#9 remains open until both engine/custom planners pass those admission tests.

Tested domain: base 2.0.77, native unassociated characters at modifiers 0 and 4,
single vertical gate with eastward cardinal crossing, one gate per authored
segment. Diagonal/multi-gate/player-bound/circuit/allied-force/modded-prototype
support remains unproved; the generic cardinal geometry helpers do not expand
this tested domain. See the TestKit gate action README for cases and failures.

Primary API references, cross-checked against installed 2.0.77 docs:

- [Gate state, neighbours and opening requests](https://lua-api.factorio.com/latest/classes/LuaEntity.html)
- [Wall circuit gate control](https://lua-api.factorio.com/latest/classes/LuaWallControlBehavior.html)
- [Runtime prototype API](https://lua-api.factorio.com/latest/classes/LuaEntityPrototype.html)
