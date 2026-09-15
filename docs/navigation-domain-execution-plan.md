# Gates, changing worlds and belts: execution design

Updated 2026-09-15. This is the concrete follow-up to the
[architecture plan](navigation-architecture-plan.md), after native calibration
in PR #19. It separates experimental execution from admission by a production
planner. See [project progress](project-progress.md) and the newest
[experiment log](pathfinding-experiments.md) entry for executed evidence.

## Common boundary

A solver returns a candidate. The game admits that candidate against an actor,
an objective and a committed world generation; execution then monitors its
remaining corridor and performs any required actions. Gates, motion fields and
world edits must affect both admission and execution. Adding a permissive search
flag without changing the validator is insufficient, and weakening collision
validation to obtain a passing movement test is not a solution.

The three modules can be developed independently. Their first combined profile
must retain the same PlanningRun, route identity, cancellation, collision checks
and measured completion protocol. Isolated straight-route experiments establish
control behavior; they are not substitutes for planner-to-arrival episodes.

| Domain | World facts | Planning decision | Execution responsibility |
| --- | --- | --- | --- |
| Gate | Entity identity, force, orientation, bounds, automatic/circuit policy and calibration provenance | Conditional transition with an opening action, eligibility and expected delay | Request early enough, observe opening, cross only when physically clear; stop if the precondition changes |
| World edit | Bounded topology/motion/transient changes and regional revisions | Replan when the remaining corridor becomes invalid; reject stale pending results | Stop immediately for a relevant blocking edit, preserve safe movement for irrelevant changes |
| Belt | Directed belt vector plus measured actor movement primitives and support domain | Minimize feasible travel time with directed costs, retaining motion boundaries | Compensate drift with attainable native controls and monitor the motion model |

## Gates: conditional traversal, not an ignored obstacle

The initial supported domain is an automatic, single, same-force gate in a
calibrated base-game configuration. An adjacent wall's circuit control can
change gate behavior. Distinct allied forces, connected gate chains and
configured wall control are rejected as unsupported until separately measured.
An enemy gate is blocked. Eligibility is checked before requesting and again
during execution; removal/replacement must not silently inherit the old action.

The action has an approach boundary, the gate collision extent and a far-side
clearance boundary. Its states are prepare, request, wait/open-check, traverse,
and complete, with explicit rejection/failure terminals. The opening lead comes
from the actor's approach speed, distance to first contact and the calibrated
opening duration. It is not a fixed number of tiles for every actor. A request
can overlap the approach; if opening cannot finish before contact, the actor
waits on the near side. The measured state and physical clearance decide when
to proceed, not the mere fact that request_to_open returned successfully.

Factorio 2.0.77 exposes request/state methods, but its runtime prototype API does
not expose all gate prototype properties available in newer documentation.
Opening duration therefore needs an explicit version/prototype-scoped measured
input in this slice. The prior 16-tick base-gate measurement is not a universal
constant. Nor is extra_time a demonstrated minimum open-time guarantee: the
calibration already falsified that assumption. API references:
[gate request/state](https://lua-api.factorio.com/2.0.77/classes/LuaEntity.html#request_to_open),
[wall control](https://lua-api.factorio.com/2.0.77/classes/LuaWallControlBehavior.html).

Planner integration requires a semantic collision query shared by grid capture,
route validation and trajectory validation. It must identify the exact eligible
gate transition, retain every neighboring obstacle and actor-clearance margin,
and attach the necessary action. The current prototype-mask check rejects even
an open gate, so a native action test deliberately retains an assertion showing
that limitation. No global gate ignore list or imported-route bypass is allowed.

A future time objective includes approach/crossing time and any opening delay
that cannot overlap approach. Distance remains a separate metric. Smoothing may
not delete a gate action or its approach/clearance boundaries. Acceptance tests
must include fast approaches, closing while approached, a revoked permission,
two gates in sequence, circuit variants and an ordinary-wall negative control.
The first action experiment does not complete issue #9.

## Dynamic changes: invalidate the remaining corridor

The route footprint is the swept actor/trajectory envelope around the remaining
segments, not just the whole-map dirty flag or an uninflated centerline. Each
world update provides bounded facts and a revision. Intersecting those facts
with the remaining route identifies what actually needs a response. Once a
section has been traversed, changes there do not invalidate the future route.

| Observed change | Immediate response | Planning follow-up |
| --- | --- | --- |
| New collidable entity/tile intersects the remaining envelope | Stop walking in the synchronized event callback | Cancel obsolete work and replan once the relevant update is committed |
| Change away from the remaining corridor | Continue | Refresh dependency bookkeeping; no safety replan |
| Removal of a blocker | Continue on the still-valid route | Optional shorter-route optimization is separate from mandatory invalidation |
| Belt or speed-field change on the route | Re-evaluate motion feasibility | Reprice if safe; stop/replan if new drift makes the route uncontrollable |
| Moving actor or gate animation | Local action/avoidance layer | Escalate sustained blocking by an explicit policy; do not rebuild static topology every tick |

Stopping and rebuilding have different timing requirements. A burst of edits
may be coalesced into one replan, but the stop must not wait for that batching
window. An asynchronous answer belongs to its request sequence and world
dependencies; cancelling a request and rejecting stale results are separate
checks. A replacement result must be admitted against a committed generation,
never a mixture of partially updated cells/polygons.

The first execution slice wraps the existing episode PlanningRun/Follower
adapter and retains the original inserted-wall failure as a control. It tests
on-route insertion, off-route insertion, removal, motion-only changes and
bursts with exact event/stop/replan ticks and a real arrival terminal. Those
scripted, normalized edits do not establish full production event coverage,
moving-crowd avoidance, external-solver generation synchronization or arbitrary
mod-created mutations. Each of those remains an explicit integration task.
The initial callback scan budget is per event, while queued work has a per-update
budget. A burst of N callbacks can still perform N times the immediate-check
budget; this is not a proven aggregate frame-time cap. Route revision stamps in
this wrapper record observed facts, not an external backend's committed
generation. Pending changes are checked before the next Follower step.

Metrics must report event-to-stop, event-to-new-request, request-to-acceptance,
arrival, contacts, replans and work. A test which arrives only after hitting the
wall does not prove proactive invalidation. A harmless motion update remaining
geometrically valid does not prove safety for a drift-sensitive controller.
In particular, clearing walking_state on a belt does not cancel passive belt
transport. The current stop evidence is on ordinary ground. A combined profile
needs a calibrated hold/counter-drift action or a reachable safe waiting area;
it must not reuse the ground-stop guarantee on belts.

## Belts: directed travel time and attainable control

Uniform base-game belt calibration measured eight unique ground control
vectors. Factorio quantization matters: measured cardinal ground displacement
was 0.1484375 tiles/tick while the speed property reported 0.15. Yellow/red/blue
belt drift was respectively 0.03125/0.0625/0.09375 tiles/tick. Scope those values
to their engine/prototype/actor calibration; do not extend them silently to
equipment, immunity, different tiles or modded belts.

Let measured ground controls be u_i and local belt drift be b. For desired unit
travel direction d, solve for nonnegative weights whose sum is one such that

    sum(weight_i * (u_i + b)) = progress * d, with progress > 0.

Maximizing progress within that convex hull gives the best attainable average
velocity for a uniform segment. Its directed time cost is length/progress. If
there is no positive solution, the segment is infeasible under the measured
controls. A continuous speed circle is incorrect for these discrete native
directions. The average model also needs a finite cross-track envelope: mixing
controls can still hit a nearby wall even when its mean lateral velocity is zero.

For example, an express eastbound belt plus an uncompensated south command
moves (0.09375, 0.1484375) per tick. The previous probe drifted 3.84375 tiles while
making six tiles of southward progress. A controller must choose and schedule
attainable controls to keep lateral error bounded. Switch count, error and
arrival are all reported so compensation cannot hide a return of the old
per-tick turning problem. Predicting a favorable mean speed alone is insufficient.

Search must use directed travel-time costs, and final scoring must recompute the
same objective after smoothing. The distance-based comparison ellipse cannot
exclude a longer but faster belt route; start with declared bounded coverage and
zero-heuristic Dijkstra as the reference. An admissible speed bound can support
A* later. Preserve belt entry/exit boundaries and evaluate turns, corners,
splitters, underground endpoints, immunity and equipment before admitting them.

The first controller experiment uses an explicit measured model and native
movement on supported uniform cardinal fields. It leaves the production
trajectory/follower unchanged. Planner selection of a faster belt route, entry
and exit, dynamic belt rotation, and mixed gate/belt corridors require subsequent
planner-to-arrival fixtures. Issue #2 remains open until that directed planning
and execution contract is demonstrated.

## Composition and promotion gates

The next combined fixture should place a gate on a belt-influenced approach and
insert a wall into the remaining route during travel. This forces agreement on
arrival-time estimates, opening lead, drift clearance, invalidation, cancellation
and replanning, including holding position while opening/planning. It must run through the shared profile in headless and explicit
GUI test-lab modes before becoming the normal-save default.

Specialists own isolated gates, execution and motion modules plus domain
fixtures. The integration owner alone changes shared contracts, registries,
default profiles, common report validation, central runners and documentation
checkpoints. Use `tools/test.ps1 -Suite execution` for the new repeated native
experiments; `-Suite all` includes them and the historical controls. Passing
depends on semantic terminals and assertions; time/tick limits only fail runs.
