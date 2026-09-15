# Real gate calibration, fixture version 1

This local-only scenario measures real `gate` entities and native character
`walking_state` in Factorio. It does not invoke a planner, copy the follower,
install production gate policy, or rename historical static wall-gap fixtures.

Entry: `scenarios/gate-calibration/control.lua`. The shared host runner selects
domain `gates`, writes `script-output/scv-control/calibration/gates.json`, and
waits for `SCV_CALIBRATION_COMPLETE domain=gates passed=N failed=N`.

## Frozen geometry and probe matrix

Every case uses a fresh surface with grass-1 from `[-24,-20]` to `[24,20]`, one
gate at `(0.5,0.5)`, walls at `(0.5,y+0.5)` for integer `y=-6..6` except zero,
and a native character walking east from `(-12.5,0.5)` to `x>=12.5`.

- Same-force passive and explicit approaches at speed modifiers 0 and 4 (5x).
- Enemy-force passive and explicit approaches at modifier 0.
- Explicit request: actor force `player`, issued before the first movement
  tick, `extra_time=120`. This is a declared calibration intervention, not a
  recommended production constant.

Reported metrics distinguish first opening/opened/closing states, native
movement constraints, the actor collision box clearing the gate plane,
reaching the far-side endpoint, and closed after crossing. The unoccupied gate
center collision probe is skipped when the actor is within one tile so the
character itself cannot be mistaken for closed-gate collision.

Same-force probes end only after the real character crosses and the gate is
closed. Enemy-force probes require contact, a distant friendly gate's complete
explicit opening/closing positive-control cycle while the enemy gate remains
closed, and crossing after removing only the enemy gate. Thus a blocked result
means a demonstrated local force-dependent blocker, not a global no-path
proof. Every case has a 1,800-tick failure guard; elapsed time never passes it.

## Measurements on Factorio 2.0.77

Two fresh seeded headless runs produced identical case assertions, metrics and
timelines. Runner map seed `424242`; each fixture surface seed `82451`.
Times below are simulation ticks relative to the first native movement command.

| Case | Fully open | Collision box cleared gate | Far-side endpoint | Reclosed | Slowed / stationary commanded ticks |
| --- | ---: | ---: | ---: | ---: | ---: |
| Same force, normal passive | 61 | 91 | 169 | 126 | 0 / 0 |
| Same force, normal explicit | 16 | 91 | 169 | 126 | 0 / 0 |
| Same force, 5x passive | 21 | 23 | 38 | 46 | 5 / 3 |
| Same force, 5x explicit | 16 | 18 | 34 | 39 | 0 / 0 |

All four physically traverse without lateral detour. The 5x passive actor
first contacts the still-opening gate at tick 17, `x=-0.03125`; the proactive
request avoids that contact. This establishes sufficiency of this **13-tile
lead** at **0.75 tiles/tick**, not a globally minimal lead-distance policy.

Both enemy-force cases contact at tick 85 (`x=0`), remain near `x=0.0078125`
during the distant friendly positive-control open/close cycle, then cross by
tick 221 after the sole blocking gate is removed at tick 136. The explicit
enemy-force request raises `player force can't open gate with enemy force`;
that rejection is caught and asserted, not treated as a harmless no-op.

## Failed hypotheses retained

1. The first implementation assumed a force-incompatible explicit request
   could simply be observed staying closed. Factorio throws a Lua error
   instead. The probe now captures and asserts the specific rejection;
   future route actions must test eligibility and handle this failure.
2. Initially only geometry was fixed. Two fresh random-seeded processes
   differed in passive opening by 2-3 ticks and in closing times, while both
   individually passed. Deterministic comparison correctly failed. Pinning
   the runner seed and per-case surface seed makes the tested timelines
   reproducible; do not silently discard timing fields from comparison.
3. Do not interpret `extra_time=120` as a guaranteed 120-tick minimum hold
   through an approach. The explicit 5x gate starts closing at tick 24 and is
   closed at 39. A subsequent automatic interaction appears to replace the
   requested hold, but the internal cause is **not established** by this
   matrix. The independent no-nearby-character control with `extra_time=30`
   opens at +16 and recloses at +51. Policy must not rely on the stronger
   hold-time assumption without another dedicated experiment.

## Scope still open

No circuit-controlled, allied-but-distinct force, enemy fast-actor, player-bound
character, diagonal approach, trains, or multiplayer gate probes are claimed.
The first matrix uses an unassociated native character (`actor.player == nil`),
the same actor category used by existing headless follower episodes. GUI
player equivalence must be checked separately. No stuck/replan count is
reported: this calibration has no planning or replanning loop.

Issue #8 remains incomplete until its circuit matrix and historical-fixture
migration are covered. Issue #9 must consume evidence through shared world,
validation, and route-action contracts; these probes are not that integration.

## Primary documentation checked

The installed 2.0.77 runtime docs expose `LuaEntity.is_opened`, `is_opening`,
`is_closed`, `is_closing`, and `request_to_open(force, extra_time)`.
`LuaControl.character_running_speed_modifier=4` means 400% extra speed.
Installed base gate data specifies opening speed `0.0666666`, activation
distance `3`, close timeout `5`, and collision box `[-0.29,-0.29]..[0.29,0.29]`.
These describe the tested input, not a substitute for measured timing.

- [LuaEntity gate API](https://lua-api.factorio.com/latest/classes/LuaEntity.html#request_to_open)
- [LuaControl movement](https://lua-api.factorio.com/latest/classes/LuaControl.html#character_running_speed_modifier)
- [Gate prototype](https://lua-api.factorio.com/latest/prototypes/GatePrototype.html)

The online pages may describe a newer release; measurements are versioned by
the report's actual `factorio_version` and fixture version.
