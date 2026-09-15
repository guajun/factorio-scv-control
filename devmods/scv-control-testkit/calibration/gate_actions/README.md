# Gate action and native follower experiments, fixture version 1

Entry: `scenarios/gate-actions/control.lua`; host domain `gate-actions`.
The report is `script-output/scv-control/calibration/gate-actions.json`, schema
version 1, with terminal marker
`SCV_CALIBRATION_COMPLETE domain=gate-actions passed=N failed=N`.

Ten cases cover three native arrivals (normal, 5x, 5x starting near the gate),
three explicit eligibility rejections (enemy force, configured adjacent-wall
circuit control, connected gate chain), and four changes during an approach
(force, control, rotation, removal). All movement uses the shared production
Follower. These are authored-route action tests, **not PlanningRun admission**.
Both closed and fully opened gate rejection by the unchanged production
collision validator is an explicit assertion and a remaining integration gate.

Geometry is grass-1 on `[-24,-20]..[24,20]`, a real gate at `(0.5,0.5)`, walls
at `x=0.5, y=-5.5..6.5` excluding the gate cell, character start `(-12.5,0.5)`
or `(-1.5,0.5)`, goal `(12.5,0.5)`. The chain case replaces the adjacent south
wall with another gate. Seed is 82451 on fresh per-case surfaces; host map seed
424242. Mutation cases change the world after observed native movement, then
assert same-tick invalidation before contact and zero displacement on the next
native movement tick. The 1,800-tick guard only produces failure.

The gate's observed inflated entry plane is `x=0.01171875`; exit plane is
`x=0.98828125`. The 16-tick supplied opening calibration comes from the earlier
real-gate probe. No temporary gate deletion, teleport crossing, enlarged goal
radius, or altered collision mask is used to produce arrivals.

Measured terminal outcomes on base 2.0.77 (relative ticks include the first
command at tick 1; native movement begins at tick 2):

| Arrival case | Arrival tick | Opening first seen | Waiting ticks | Slowed commanded ticks | First request contact distance | Maximum requested extra time |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Normal | 168 | 61 | 0 | 0 | 2.41796875 | 40 |
| 5x | 33 | 17 | 0 | 0 | 12.51171875 | 35 |
| Near 5x | 33 | 17 | 14 | 0 | 1.51171875 | 21 |

All three have zero lateral detour and zero follower replans. Near-5x's 14-tick
wait equals the predicted opening delay. Arrival errors use the unchanged
Follower tolerance: normal 0.2109375/0.3 tile; far-5x 1/1.125 tile; near-5x
0.5/1.125 tile. Those loose speed-dependent endpoint bounds are existing
Follower behavior, not a gate-specific accuracy improvement.

Changes are applied at tick 2 and rejected at tick 2, while still 11.75 tiles
left of the gate center; the actor remains stationary at tick 3. Rejected
starting cases produce no native movement or opening requests. Configured
circuit rejection proves conservative classification only, not successful
signal-driven circuit traversal.

## Failed hypotheses kept

1. Assuming every gate-valued `gate.neighbours` entry referred to a different
   gate rejected all single-gate arrivals. In 2.0.77, a north-facing gate lists
   itself for east and west. Reports retain the actual neighbour identities;
   the classifier ignores only exact self references and still rejects a
   distinct connected gate.
2. Reading `actor.walking_state.walking` immediately after `Follower.stop`
   did not prove that the issued stop took effect: the getter still reported
   walking in the mutation callback. The test now observes actual displacement
   on the next tick, which is the native-motion consequence being claimed.
   Invalidation latency still must be zero ticks.
3. A fully opened gate remained rejected by `PathSmoothing.path_is_clear`.
   Inspection confirmed its prototype-mask query cannot see the runtime opened
   mask. This is preserved as a failing capability, not silently bypassed or
   described as completed semantic planner support.

Remaining cases include circuit true/false signal dynamics, sensor-only versus
restrictive control, allied force, gate chains, diagonal entry, changes while
already inside the gate envelope, player association and multiplayer. A narrow
safe action slice does not settle those cases or choose a gate over a detour.
