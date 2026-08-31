# Navigation Policy Inventory

All production navigation constants are defined in `scripts/navigation_policy.lua`. This inventory distinguishes behavior policy from numeric tolerances and test-only acceptance bounds.

## Production constants

There are 28 scalar numeric values in the production policy:

| Group | Count | Values |
| --- | ---: | --- |
| Path requests | 2 | Arrival radius and busy retry delay. |
| Optimization | 9 | Detour trigger, selection epsilon, two alternate fractions, minimum direct distance/excursion, via snap radius/precision, and via dedup distance. |
| Smoothing | 2 | Segment sampling distance and waypoint lookahead. |
| Grid experiments | 2 | Grid resolution and line samples per cell. |
| Follower/recovery | 6 | Waypoint tolerance, speed multiplier, recovery limit, stuck interval/distance/retry limit. |
| Trajectory | 4 | Cross-track floor/speed multiplier and clearance speed/padding. |
| Diagnostics | 3 | Position epsilon and corner/reversal reporting angles. |

Fourteen of these values can change path selection or geometry, eleven change execution/recovery behavior, and three only change numeric/diagnostic classification.

The highest-risk policy values are:

```text
optimization.detour_ratio = 2
optimization.alternate_lateral_fractions = {0.5, 0.75}
optimization.alternate_min_excursion = 2
```

They do not describe the world or a proven optimality bound. They are heuristics around Factorio's performance-biased engine pathfinder. The captured reverse-slalom fixture demonstrates the limitation: its engine path is 10.8% longer than the shortest observed path, but its direct-distance detour ratio is only 1.202, so the production `2x` gate does not run alternate planning.

The benchmark now separates two variants:

- `engine-alternate` preserves the production `2x` policy.
- `engine-alternate-global` evaluates alternate candidates regardless of that gate and globally tightens each candidate.

This makes the threshold measurable rather than silently defining which cases the testbench can observe. It does not yet change production movement.

## Test-only constants

Fixture coordinates are test data, not tuning values. The benchmark has four non-geometry control/acceptance bounds:

- terminal failure guard: 3600 ticks;
- live preview grid budget: 12000 nodes;
- dynamic gate must add more than 2 tiles;
- captured regressions require 1.5x and 1.05x engine gaps respectively.

Integration and trajectory tests contain additional acceptance bounds for observed movement quality. They intentionally fail when behavior changes and do not affect runtime decisions.

## Reduction direction

The target architecture should remove the optimization heuristics as decision makers:

1. Maintain a collision/navigation world model.
2. Search explicit regions or portals with a bounded work budget.
3. Tighten the complete corridor with exact checks only near the selected route.
4. Keep follower and trajectory tolerances derived from speed and collision clearance.

At that point the alternate fractions, minimum excursion, and `2x` trigger can be deleted rather than tuned further.
