# Trajectory Planning

SCV Control separates geometric path planning from executable character motion.

```text
LuaSurface.request_path
  -> collision-safe path smoothing
  -> polyline waypoints
  -> trajectory planner
  -> one native walking direction per tick
  -> waypoint capture and arrival
```

## Engine constraints

[`LuaControl.walking_state`](https://lua-api.factorio.com/2.0.77/classes/LuaControl.html#walking_state) accepts a `defines.direction`, not a continuous velocity vector. Although [`defines.direction`](https://lua-api.factorio.com/2.0.77/defines.html#defines.direction) exposes 16 values, engine-backed calibration on Factorio 2.0.77 shows only 8 unique character displacements:

```text
0/15=N, 1/2=NE, 3/4=E, 5/6=SE,
7/8=S, 9/10=SW, 11/12=W, 13/14=NW
```

The production controller therefore uses the canonical even values `0, 2, ..., 14` as its physical movement primitives. Tests recalibrate all 16 values so an engine behavior change fails explicitly.

## Vector decomposition

For each polyline segment, the trajectory planner finds the two adjacent 45-degree movement primitives that bracket the desired continuous vector. It does not choose the nearest primitive every tick.

Instead, it holds the current primitive until the predicted cross-track error leaves a speed-dependent hysteresis band. It then switches to the other primitive, whose lateral component returns the character toward the centerline. The different lateral components naturally produce the required time ratio between the two vectors.

This is a quantized feedback controller: over several ticks, the average movement vector approximates the desired segment. The separation between geometric paths and feedback path following follows the same architectural motivation as guiding-vector-field path-following work, while the implementation here is deliberately small and deterministic: [A guiding vector field algorithm for path following control of nonholonomic mobile robots](https://arxiv.org/abs/1610.04391).

## Hysteresis and clearance

The cross-track band scales with `character_running_speed`, which already includes tile, equipment, sticker, and shooting modifiers. Larger bands reduce direction-switch frequency but require more free space around a segment.

`Trajectory.clearance_margin(speed)` exports the complete movement envelope:

```text
hysteresis band + partial tick displacement + safety padding
```

Path smoothing inflates the character collision box by this margin before removing any waypoint. A shortcut is accepted only when the whole trajectory envelope is clear of colliding entities and tiles. Faster characters therefore retain more engine waypoints near obstacles.

## Waypoint capture

Passing a waypoint plane is not sufficient at a corner. If the character crosses the plane outside the normal cross-track tolerance, the follower creates one short recovery segment from the actual position back to the same waypoint. Only after capture does it start the next segment.

Each waypoint allows at most one recovery. A second miss returns `replan`, preventing infinite local oscillation. At the final waypoint, crossing the target plane within tolerance counts as arrival; crossing outside tolerance follows the same single-recovery rule.

## Diagnostics

The interactive TestKit writes per-tick traces to:

```text
%APPDATA%\Factorio\script-output\scv-control\follower.jsonl
```

Each row includes desired orientation, bracketing primitives, selected direction, switch state, position, waypoint, cross-track error, error band, run length, and recovery attempt.

The headless trajectory regression currently executes three non-native angles on refined concrete. The accepted baseline on Factorio 2.0.77 is:

- 169 movement ticks across three completed segments;
- 21 direction switches, a 12.4% switch rate;
- minimum direction hold of 2 ticks;
- maximum cross-track error of 0.277 tiles;
- zero large direction jumps;
- zero distance regressions;
- zero waypoint recoveries.

These metrics are behavioral bounds, not targets. Changes should be judged by actual completion, collision safety, and visible movement quality together.
