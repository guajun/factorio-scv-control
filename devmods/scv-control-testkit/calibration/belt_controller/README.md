# Uniform belt motion and controller experiment v1

This adds a reusable motion model and an experimental controller. It does not
change the production planner, follower, trajectory, default profile or GUI
input. The baseline invokes the unmodified production `Follower.advance`.

Run the integration owner's headless host with `--domain belt-controller`.
The report is `scv-control/calibration/belt-controller.json`; completion is
`SCV_CALIBRATION_COMPLETE domain=belt-controller passed=N failed=N`. The host
runs twice with seed 424242 and compares every assertion, metric and per-tick
sample. The 33 cases comprise 3 pure model checks and 30 actual native arrivals;
model checks are never counted as native arrivals.

Validation on 2026-09-15: 33/33 cases and 188/188 assertions pass in each of
two identical seeded runs (`scv-calibration-yfonhvd8`). The worktree's required
`pwsh -NoProfile -File .\tools\test.ps1 -Suite all -KeepArtifacts` also passes:
109 integration assertions, 11 x 10 static benchmark, 3 baseline episodes,
repeated 6-gate/56-belt calibration, 11 interchange, 46 Python and 7 live checks.
Its artifact root is `factorio-scv-agent-test-f39a31cce445494880a54b61cd8d3194`.
This branch's default runner still uses the previous calibration domain list;
the integration owner adds this new domain to `all` separately.

## What is implemented

`scripts/navigation/motion/measured_uniform.lua` has three separate contracts:

1. `field(spec)` accepts only the measured Factorio 2.0.77, base unarmored
   character at runtime speed 0.15, no immunity, grass-1, uniform cardinal
   transport/fast/express belt domain. It returns explicit unsupported reasons
   for other engine, actor, field, belt kind or direction inputs. The spec is
   a caller-provided description, not a live-world detector.
2. `physical_velocity(field, direction)` returns a native one-tick vector.
   Ground cardinal displacement is 38/256 tiles, diagonal components are
   27/256, and measured belt vectors have magnitude 8/256, 16/256 or 24/256.
   These are the previous 56-case calibration's measurements, not prototype
   running-speed guesses. New tests compare every actual tick with that vector.
3. `directed_edge(field, from, to)` tests kinematic feasibility and returns
   `travel_ticks`, `cost`, `units="ticks"` and the realizing control mixture.
   Unsupported or impossible edges have infinite cost, not a favorable forward
   projection that ignores lateral drift. These results do not include actor
   collision, entry/exit, goal holding or a world snapshot freshness guarantee.

For a segment unit tangent `t` and normal `n`, each physical control velocity
`v_i` has forward speed `a_i = dot(v_i,t)` and lateral speed `l_i = dot(v_i,n)`.
The edge model maximizes `sum(w_i*a_i)` subject to nonnegative weights summing
to one and `sum(w_i*l_i)=0`. A vertex of this two-dimensional velocity-hull
slice uses one or two controls. Enumerating those intersections gives the best
mean forward speed; if none is positive, the directed edge is infeasible.
Cost is length divided by that speed. It is a uniform-field, mean-velocity
answer, not a guarantee that an arbitrarily thin finite corridor is executable.

`scripts/navigation/motion/uniform_controller.lua` consumes that mixture and
actual positions. It keeps the current native primitive while its predicted
next position remains within the declared centerline band, then selects the
opposite lateral primitive. The band is an explicit caller corridor constraint,
not a belt attraction bonus. The module conservatively requires a band at least
as large as the largest selected one-tick lateral displacement; this sufficient
bound is not claimed to be the smallest feasible band. Leaving the corridor
or finding no safe primitive returns a failure diagnostic. Shared
`Trajectory.cross_track_error`, `PathMath`, and follower arrival tolerance are
reused; no planner or production follower is copied into this experiment.

## Exact native comparison

Every case recreates 576 real belts at tile centers `(x+0.5,y+0.5)`, integer
`x,y=-12..11`, on grass-1. A new native character starts at `(0.5,0.5)`.
Measurement begins with the first command; any preceding passive displacement
is included in the reported command origin. The goal is eight tiles from that
origin. The centerline band is +/-0.25 tile and the shared follower arrival
tolerance is 0.3 tile for this actor. The guard is 1,200 ticks and cannot pass a
case. There are no corridor wall entities: this measures actual centerline
retention, not collision handling against adjacent walls.

Cross-belt cases compare both controllers for all three tiers and four cardinal
belt directions. Eastward-belt representative results (all four rotations agree):

| Tier | Existing follower ticks / max drift | Compensation ticks / max drift | Compensation switches |
| --- | --- | --- | ---: |
| Transport | 66 / 1.6875 tiles | 58 / 0.25 tile | 6 |
| Fast | 90 / 3.375 tiles | 63 / 0.25 tile | 7 |
| Express | 142 / 5.0625 tiles | 70 / 0.24609375 tile | 3 |

Both controllers eventually arrive in these unobstructed fields. The existing
follower drifts outside the band before recovering; its passing baseline
assertion explicitly records that failure of corridor retention. The experiment
does not silently redefine a baseline arrival as corridor safety.

Additional eastward-field cases travel with and against the belts:

| Tier | With: predicted full segment / actual arrival ticks | Against: predicted / actual ticks |
| --- | --- | --- |
| Transport | 44.521739 / 43 | 68.266667 / 66 |
| Fast | 37.925926 / 37 | 93.090909 / 90 |
| Express | 33.032258 / 32 | 146.285714 / 141 |

Arrival happens inside the declared tolerance, so it normally precedes the
prediction for the exact endpoint. Time-error assertions derive their bound
from that tolerance, the selected controls and the corridor; no fitted percent
allowance is used. For two controls let `beta=(a1-a2)/(l1-l2)` and mean speed
`a`. Then progress after `T` ticks is `a*T + beta*cross_track_error`. The bound
is `(arrival_tolerance + abs(beta)*band)/a + 1` ticks. Every native command's
observed velocity has zero residual against the measured field in these cases.

Three model-only cases check directed asymmetry, impossible lateral cancellation,
unsupported contexts, finite-corridor refusal, and a complete two-route cost
comparison. The synthetic example costs an eight-tile ground route at
53.894737 ticks and a twelve-tile favorable express detour at 49.548387 ticks;
the same detour in reverse costs 219.428571 ticks. These are cost-law assertions,
not a search implementation or a native detour arrival test.

## Boundaries and failed assumptions

The first instrumented run reported velocity residuals for the old follower.
Its input recorder immediately read `walking_state` after assigning it, which
still exposed the previously applied state during that event. Recording the
shared follower's `diagnostics.selected_direction` instead aligns the issued
command with the following tick's measured displacement. No motion constants
or acceptance thresholds changed to hide that instrumentation failure. The
per-tick vector assertion now protects this correlation.

No evidence here covers belt entry/exit or mixed fields, turning belts,
splitters, underground boundaries, equipment/immunity, armor, exoskeletons,
dynamic rotation/build/remove, adjacent collision geometry, GUI-player
equivalence, or stationary holding on a belt after arrival. Such inputs remain
unsupported or outside the explicit experiment scope. The finite corridor is
about the actor center; a world/trajectory validator must also account for the
actor footprint and swept collision geometry.

To complete issue #2, use directed costs during provider search, use a justified
time bound or explicit coverage rather than the current distance ellipse,
preserve motion transitions through smoothing, and compare native longer/faster
routes including entry/exit. Merely applying these costs to final candidate
scoring would not implement time-optimal route search. Mid-route belt changes
must refresh the motion revision and controller feasibility before they can be
treated as optional cost improvements.
