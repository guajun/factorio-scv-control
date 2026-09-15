# Saved maps are the native testbench's source

The prior suites created real Factorio entities in headless scenarios and ran
native movement. They did not retain a common, directly openable pre-command
save corpus. This layer closes that gap. A fixture definition authors a map;
the resulting Factorio ZIP is the source for evaluation and human inspection.
Passing an independent simulation or a derived graph cannot replace final
execution on that source map.

## Source, derived data and execution

1. A fresh headless authoring process prepares one native case, without starting
   its command or asynchronous planner. The engine is paused before publishing
   its entities, observed facts and `.zip` save.
2. A corpus manifest binds the case, fixture/action schedule, ZIP SHA-256,
   observed-facts file SHA-256 and canonical facts hash. Source mod copies and
   their fingerprint are retained alongside the maps. Every source case is
   built in a fresh process, so unrelated previous test surfaces do not accumulate.
3. Evaluation starts another headless process with `--start-server <source.zip>`.
   It verifies actual loaded facts and the original actor, with zero calls to
   geometry setup in this process. It does not call `Probe.start`, `World.setup`
   or redraw walls/belts when replaying a save.
4. Current code recompiles derived action/controller/planning state from the
   saved entities and configuration. This is allowed: a saved map must not pin
   an obsolete algorithm implementation. The native surface, entities and action
   schedule remain the factual input.
5. The real character runs to an assertion-backed terminal. The correlated
   report names the source ZIP and hashes, measured movement and live script
   performance. The source ZIP is checked unchanged after replay.

The v1 corpus contains all 45 native cases introduced by the execution wave:
10 gate/action cases, five changing-world episodes and 30 belt-controller/control
cases. There are 38 expected arrivals, three eligibility rejections and four
changed-precondition stops. The 17 pure policy/model cases remain fast tests;
they are not reported as native-map arrivals. Existing calibration, static
benchmark and historical failure controls also remain in the full suite.

The first saved-map external-solver test independently saves a real long-wall
fixture and loads the same ZIP before capturing it. It uses `Capture.live` on
the persisted actor and surface; the source build identity is retained rather
than rebuilding the fixture before solving.

## Commands and artifacts

The validated local v1 corpus is
`F:\factorio-scv-testbench\corpora\v1-20260915-174358-8e2cde`.
`F:\factorio-scv-testbench\README.md` provides a short Chinese opening guide.
Its default `open-save.ps1` selects `same-force-normal-follower`; use `-Save`
with another manifest filename to choose a different case.

```powershell
# Run native source-save replay; author a full corpus only if none exists.
pwsh -NoProfile -File .\tools\test.ps1 -Suite savebench

# Deliberately author a NEW version, retaining earlier corpora.
python .\tools\navigation\savebench.py --build --test

# Evaluate the same immutable maps with the current checkout's algorithms.
python .\tools\navigation\savebench.py --test --corpus F:\factorio-scv-testbench\corpora\VERSION

# Exact native clock stepping around an external solver wait.
pwsh -NoProfile -File .\tools\test.ps1 -Suite stepped
```

On this machine source corpora live under `F:\factorio-scv-testbench\corpora`.
`latest.json` selects the latest complete corpus. A new partial diagnostic build
does not replace it. `--case <id>` selects a stored case explicitly; the default
full run rejects a partial corpus or a missing case denominator. Existing
corpora are never regenerated implicitly during replay. A changed fixture
catalog requires an explicit new version and review of its matrix.

Each corpus contains `manifest.json`, `saves/`, `facts/`, exact source `mods/`,
`client-config.ini`, `open-save.ps1` and `OPEN-MAPS.txt`. The generated launcher
is for a human to run, and is never executed by automation. It opens a selected
save with the corpus mod set and a separate write-data directory. Ordinary
Factorio saves/mod links remain untouched. The exact save can also be selected
from that isolated client's Load Game screen.

The map opens paused, with start/goal labels and a spectator at the test actor.
Use `/scv-savebench run`, `/scv-savebench pause` and `/scv-savebench status`.
Reload the ZIP to repeat the original case; use a separate Save As for manual
edits. A manual inspection uses the source mod copies; automated evaluation
uses current code against the same saved world and records its mod fingerprint.

The runtime marker only enables the service on this dedicated scenario.
`on_load` changes no synchronized state or game clock. A loaded-source diagnostic
is observational and cannot govern multiplayer simulation behavior.

## Derived grids, meshes and precomputed change tables

`savebench/facts.lua` observes native tiles, collision bounds/masks, gate states
and adjacent-wall controls, belt parameters, actor profile and active mod set.
It does not manufacture those facts from a fixture's requested coordinates.
The [fact contract](../devmods/scv-control-testkit/savebench/FACTS.md) documents
coverage and unknown fields. A canonical semantic hash is separate from the
ZIP's complete-engine-state SHA-256; neither is substituted for the other.

`tools/navigation/save_facts.py` binds a derived artifact to its source ZIP,
facts hash, state key, fixture version, compiler identity/version and settings.
A grid, polygon map or a table of known gate/edit states may use that binding.
Changing gate state, belt direction/tier, collision tiles, actor speed or the
action schedule invalidates the corresponding binding. Unlisted combinations
must be rejected or rebuilt, rather than borrowing an unrelated table entry.

This wave implements source binding and validation, not a new map compiler or
an assertion that arbitrary precomputed states are equivalent. Equivalence
still requires paired results and final native execution on the bound map.
Source semantics omit incarnation IDs and unavailable gate opening progress;
the original ZIP plus live execution retain those engine details. Entity
replacement also needs the execution layer's identity checks.

## Clock control and performance interpretation

Factorio 2.0.77 supports `game.tick_paused` and `game.ticks_to_run`. The latter
runs an exact number of native updates while paused; it does not simulate
movement in another language. RCON remains responsive while entity time is
frozen. The debug wrapper rejects invalid/overlapping step budgets and can
pause, resume or step 1–3600 ticks. The test observes both `game.tick` and actor
position, rather than treating a counter command as evidence of physical steps.
Installed API references: [game clock](https://lua-api.factorio.com/latest/classes/LuaGameScript.html#ticks_to_run),
[profiler constraints](https://lua-api.factorio.com/latest/classes/LuaProfiler.html).

The stepped external run keeps the saved world frozen through capture, solver
work and result admission, then steps the real follower to arrival. Host wall
watchdogs remain independent of paused simulation ticks. A slow or disconnected
solver cannot acquire an infinite deadline by freezing the game. Reports expose
capture time, actual solver time, transport/admission, artificial test delay,
total frozen wall time and native travel ticks. They explicitly set
`real_time_performance_evidence=false`.

The 45 source-map cases run at game speed 1 without solver-wait stepping.
Their reports separately include:

- Native travel ticks, arrival/error, stops, replans, drift and original assertions.
- Host time from source checking/run RPC through terminal observation, with
  source-check/RPC and terminal-wait components; server startup is excluded.
- Per-hook native LuaProfiler samples, counts, mean, maximum and p95 durations.
  Synchronous mutation callbacks are nested in `on_tick`; their time must not
  be added a second time. Lua cannot read profiler numeric values, so localized
  measurements are written server-side and parsed by the host.
- An explicit flag for a single measured hook exceeding a 60-UPS reference
  budget of 16.667 ms. Functional arrival can pass while this performance flag
  fails. Instrumentation and native pacing remain included in host wall time.

These are measurements on the loaded real map. Per-hook timing is not a full
engine update/GUI render CPU profile or proof of factory-scale performance.
Likewise, a paused correctness run cannot establish realtime responsiveness.
The first measured map already exposes expensive planning callbacks; those
costs remain visible rather than being hidden behind solver waits.

## Regression findings

The first saved-map gate replay issued a command from a paused RPC and sampled
it again in `on_tick` at the same game tick, before physical movement. That
produced a false slowed tick and an intermediate gate-state rejection. The
runtime now applies each native tick once, with a stored last-update tick.
The original ZIPs then pass unchanged; no collision threshold or gate policy
was loosened. This demonstrates why restarting from the real artifact belongs
in the testbench instead of relying only on an in-process generated scenario.

A second review found that recomputing a belt command from current fixture
defaults could silently change the saved task's goal or allowed corridor width.
Replay now takes the goal and constraint from the saved descriptor (or the
original saved probe's width for the first corpus). A model regression changes
current defaults and verifies that the stored command remains unchanged; an
actor that moved away from its recorded start is rejected. Recompiling an
algorithm must not redefine its test input.

Independent review also caught stored probe assertions and provenance surviving
reload. Gate and belt probes now share an `arm` operation that creates fresh
assertions, timelines, metrics and algorithm state from the persisted native
objects. Regression checks deliberately change the current validator answer
and model/calibration identity: a saved passing verdict cannot override a new
failure or describe the new run with the old model's identity.
