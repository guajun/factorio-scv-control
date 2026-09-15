# Agent Development Contract

This repository is designed for unattended local development against Factorio.

## Required validation

Run this after changing runtime code, test fixtures, or tooling:

```powershell
pwsh -NoProfile -File .\tools\test.ps1 -Suite all
```

The default suite must remain fully headless. Never launch the graphical Factorio client from automated tests. In particular, do not add LuaSimulation or main-menu simulation runs to the default runner: the Steam build displays launch confirmation UI and can interrupt the user. Tests must succeed on terminal conditions, not because an arbitrary number of ticks elapsed; tick limits are failure guards only.

Use `-Suite smoke` for mod loading and lifecycle checks, `-Suite integration` for behavior assertions, and `-KeepArtifacts` when investigating a passing run. Failed runs retain their artifacts automatically.

## Architecture

- `scripts/navigation/planning_run.lua` is the shared production/eval acceptance state machine. Keep `production-v1` provider order and route selection reproducible.
- `scripts/navigation/solver_boundary.lua` validates the versioned external query/result envelope and per-provider query capabilities. Import outcomes remain distinct from episode arrival.
- `scripts/navigation/navigation_data.lua` manages committed captured-input generations and staged deltas; it is not a navmesh baker. Store only serializable values and release pinned generations.
- `scripts/navigation/canonical.lua` defines shared Lua/Python input identity. Change encoding or bounds only with cross-language conformance assertions.
- `devmods/scv-control-testkit/interchange` owns bounded fixture/live capture and shared-planner/native-follower replay. External routes never bypass the production validators.
- `tools/navigation` owns external host tooling; normal mod loading must not depend on Python or a running service.
- `control.lua` is the production event adapter and orchestrator.
- `scripts/planner.lua` adapts asynchronous engine requests and delegates safe local comparison.
- `scripts/local_planner.lua` compares validated engine paths with conservative local A* inside a baseline-length ellipse.
- `scripts/path_math.lua` contains deterministic path metrics and legacy alternate-route calculations used by benchmarks.
- `scripts/path_smoothing.lua` removes collision-safe grid corners and reports exact final paths.
- `scripts/navigation_grid.lua` captures an inflated local collision snapshot for planner experiments.
- `scripts/grid_search.lua` owns reusable A*, weighted A*, and Theta* graph search.
- `scripts/navigation_policy.lua` is the single inventory of production navigation behavior constants.
- `scripts/trajectory.lua` decomposes continuous segments into hysteresis-controlled native movement primitives.
- `scripts/follower.lua` advances a LuaControl along an accepted path and is shared with headless tests.
- `scripts/input.lua` translates cursor data into commands and validates live player input.
- `scripts/queue.lua`, `scripts/state.lua`, `scripts/path_render.lua`, and `scripts/planner_logger.lua` own their respective narrow concerns.
- `devmods/scv-control-testkit` is a local-only companion mod. It must never become a production dependency.
- `devmods/scv-control-testkit/scenarios/automated` owns engine-backed integration tests and writes the machine-readable report.
- `devmods/scv-control-testkit/pathfinding` owns the shared fixture catalog, benchmark adapters, reports, and GUI renderer.

Keep pure or actor-agnostic behavior in modules under `scripts/` so the automated scenario can execute the same code as production. Avoid copying planner or follower algorithms into tests.

## Test protocol

The automated scenario writes `script-output/scv-control/test-results.json` and logs `SCV_TESTKIT_COMPLETE passed=N failed=N`. The PowerShell runner watches this protocol, terminates only Factorio processes it started, returns a nonzero exit code on failure, and preserves the isolated test root when diagnostics are needed.

The pathfinding benchmark writes `script-output/scv-control/pathfinding-benchmark.json` and logs `SCV_BENCH_COMPLETE passed=N failed=N`. `-Suite all` must run it after integration. Keep its fixture definitions shared with `/scv-test-bench`; never maintain a second GUI-only geometry.

`-Suite interchange` runs bounded capture and imported-route execution in its own headless scenario so export work does not perturb the production benchmark's engine request order. Its report is `script-output/scv-control/navigation/interchange-results.json` and its terminal marker is `SCV_INTERCHANGE_COMPLETE passed=N failed=N`. The default `all` suite includes it. `tools/navigation/eval.ps1` performs the full offline export -> external solve -> Factorio replay comparison using an isolated project copy; never overwrite the user's imported catalog from automated evaluation.

`-Suite live` (also in `all`) launches `tools/navigation/live.py --test`: an isolated loopback headless server plus Python solver, with actual native arrival and protocol lifecycle checks. The host retains its own artifact root and emits `SCV_LIVE_COMPLETE passed=N failed=N`. It must never run its generated manual GUI launcher automatically. Keep multiplayer session state synchronized; `on_load` also runs on a newly joining client and cannot invent a local cancellation.

`-Suite calibration` (also in `all`) runs isolated real gate/belt measurement scenarios twice with fixed seed 424242 and compares all case metrics/timelines. Its versioned reports are `script-output/scv-control/calibration/gates.json` and `belts.json`; completion is `SCV_CALIBRATION_COMPLETE domain=... passed=N failed=N`. Native-motion calibration is not planner/follower feature validation. Keep unsupported circuit, equipment, entry/exit and dynamic-world cases explicit. The calibration host uses a fixed base + SCV + TestKit mod set with DLC disabled and retains artifacts.

`-Suite execution` (also in `all`) repeats the isolated gate-action, remaining-corridor invalidation and measured belt-controller scenarios. Their domains are `gate-actions`, `dynamic`, and `belt-controller`, using the same report/terminal protocol as calibration. Read `docs/navigation-domain-execution-plan.md` before composing them. Gate action and belt controller probes use authored movement segments and do not prove production planner support; the dynamic wrapper uses the shared PlanningRun/Follower. Preserve historical controls and distinguish blocked/unsupported domains, proactive stop metrics, model feasibility, actual drift and arrival. Do not bypass the static gate validator or promote these experiments into the default profile without shared semantic admission and combined-domain episodes.

Record pathfinding experiments in `docs/pathfinding-experiments.md` with newest entries at the top. Preserve failed hypotheses, exact fixtures/metrics, and the decision they motivated; do not rewrite the log into a success-only narrative.

Before implementing composable planners, dynamic-world handling, gates, belts, or navigation episodes, read `docs/navigation-architecture-plan.md`. Phase 0 in that plan is the merge barrier: production and evaluation must share `PlanningRun` contracts before domain features branch out. During parallel work, assign `control.lua`, `tools/test.ps1`, registry indexes, the default profile, common report schemas, and this file to one integration owner; specialist agents should add isolated modules and domain fixture files without editing those central hot files.

Every regression fix should add or tighten an assertion in the automated scenario. Prefer exact fixture coordinates and bounded metrics over screenshots.

## Interactive test save

Create or refresh the developer save only when its enabled mod set changes:

```powershell
pwsh -NoProfile -File .\tools\create-test-save.ps1 -Force
```

The save uses a minimal marker scenario plus `scv-control-testkit`; test-lab code is loaded from the repository rather than embedded in the save. The marker prevents TestKit from mutating ordinary saves. Runtime code changes are picked up by reloading the save or calling `game.reload_mods()` in singleplayer. Prototype-stage changes still require a Factorio restart.
