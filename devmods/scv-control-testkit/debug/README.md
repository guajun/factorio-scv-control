# Native debug clock and saved-map external replay

`clock.lua` wraps Factorio's synchronized `game.tick_paused` and
`game.ticks_to_run`. It has no Lua countdown and needs no event registration.
The caller must already have verified the test-map marker: pausing changes the
whole game, so this API is never installed in the production mod.

```lua
local Clock = require("debug.clock")
Clock.dispatch({action = "pause"}, actor)
Clock.dispatch({action = "step", ticks = 30}, actor)
Clock.dispatch({action = "status"}, actor)
Clock.dispatch({action = "resume"}, actor)
```

The return value is `{ok=true, clock={tick, ticks_played, paused, ticks_to_run,
mode, actor_position?, actor_unit_number?}}`. Invalid requests return
`{ok=false, reason=...}` without changing the clock. Steps accept only integers
1 through 3600, require an already paused clock, and reject an outstanding step.
`pause` cancels any remaining step budget. `resume` clears it and restores normal
continuous updates. All changes run from synchronized console/RCON commands;
`on_load` never invents local clock state.

The live test-map service exposes `operation="clock"` with the same fields and
session correlation. Interactive test maps also expose `/scv-nav-clock status`,
`pause`, `resume`, or `step N`. These are optional debug commands, not a hotkey or
a required player workflow.

## Saved-map test

Run from the repository root:

```powershell
python tools/navigation/live.py --test --solver-clock stepped
```

The host starts only headless Factorio. It builds the real `long-wall-return`
map once, creates its character, pauses, and saves
`write-data/saves/scv-nav-debug-source.zip` in its isolated artifact directory.
It checks the ZIP structure and SHA-256, stops its server, and starts a new
server with `--start-server` pointing to that exact file. The save hash must
remain unchanged. The loaded map preserves the actor unit number, position,
surface, build tick and paused game tick. Capture then calls `Capture.live` on
those stored entities, never `Fixtures.build` or replay reconstruction.

The source save is a normal Factorio map that can be opened with the artifact's
copied mod set. A newly created GUI player becomes a spectator on the saved
source surface; `/scv-nav-clock resume` or `step N` controls its paused clock.
Automation never launches that GUI or changes ordinary saves/mod junctions.

The native test checks responsive RCON while simulation time is frozen, result
admission through the shared PlanningRun validators, exact three-tick character
movement, no further movement after the step completes, and real follower
arrival under bounded 30-tick batches. Fractional, zero, negative, boolean and
oversized steps are rejected. Resume is checked independently.

`live-report.json` labels this `clock_mode="debug-stepped"` and
`real_time_performance_evidence=false`. It records solver computation wall time,
an explicitly artificial 250 ms wait, pending-solver wall time, total frozen
wall time (capture through admission), zero frozen simulation ticks, native
travel ticks and end-to-end host wall time. Pausing is a correctness tool, not
evidence that the external solver meets a real-time deadline. The normal
`--test` still runs the continuously updating baseline separately.

## Exact-version findings

Verified in installed Factorio 2.0.77 and by a native headless run:

- RCON commands and server saving remain functional while entity updates pause.
- `game.tick` and entity positions freeze; `game.ticks_played` keeps increasing.
- `ticks_to_run=N` advances exactly N map/entity ticks and pauses again.
- A saved/reloaded paused map preserves the source tick and actor.
- This version stores `level.dat0`, `level.dat1`, `level.datmetadata` and
  `script.dat` in a ZIP. An initial host check for plain `level.dat` incorrectly
  waited for a valid save; the host parser and regression test now accept the
  split layout. This was a host validation failure, not a Factorio save failure.

Primary API: [tick_paused](https://lua-api.factorio.com/2.0.77/classes/LuaGameScript.html#tick_paused),
[ticks_to_run](https://lua-api.factorio.com/2.0.77/classes/LuaGameScript.html#ticks_to_run),
[ticks_played](https://lua-api.factorio.com/2.0.77/classes/LuaGameScript.html#ticks_played),
[server_save](https://lua-api.factorio.com/2.0.77/classes/LuaGameScript.html#server_save).
