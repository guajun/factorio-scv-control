# SCV Control

[简体中文](README.zh-CN.md)

SCV Control is an experimental Factorio 2.0 mod that replaces direct character movement with RTS-style commands.

## Current behavior

- Right-click empty ground to replace the current command and move there.
- Shift + right-click empty ground to append a movement command.
- Press the key bound to **Move down** (`S` by default) to stop and clear the queue.
- The normal movement controls are consumed by the mod.
- Right-clicks over GUI elements, entities, or while holding an item pass through to Factorio.
- Pathfinding uses the current character's collision box and collision mask.
- Production compares the fully validated engine route with a conservative local A* route; legacy alternate vias are benchmark-only.
- Arbitrary path segments are followed through hysteresis-controlled decomposition into native movement directions.
- Each player has an independent, configurable command queue.

This is an early prototype. Save before testing it in an important factory.

## Known limitations

- The mod load and lifecycle are tested locally on Factorio 2.0.77; interactive movement still needs broader gameplay testing.
- Vehicle driving is not supported in this prototype because movement controls remain consumed while the mod is enabled.
- Commands currently target empty ground only; context actions are planned for later versions.
- Local navigation snapshots are rebuilt synchronously per plan; caching and world-change invalidation are not implemented yet.

## Installation

For development, place or link this directory into the Factorio `mods` directory. For a release, package the directory as `factorio-scv-control_0.1.0.zip`.

## Local testing

Run the fully headless agent test harness from PowerShell 7:

```powershell
pwsh -File .\tools\test.ps1
```

The default command runs smoke, engine-backed integration, and pathfinding benchmark suites in an isolated temporary directory. It validates loading, path optimization, completed character movement, completed command queues, cursor-to-command translation, unreachable targets, and comparative planner behavior. Suites exit on terminal assertions; fixed ticks are used only as failure timeouts. See [testing](docs/testing.md), [pathfinding benchmark](docs/pathfinding-benchmark.md), and [trajectory planning](docs/trajectory.md).

The next architecture stages, including composable planner profiles, headless navigation episodes, automatic gates, dynamic-world invalidation, and belt-aware travel-time costs, are defined in the [SC2-like navigation architecture plan](docs/navigation-architecture-plan.md).

Navigation profile schemas, registry ownership, capability validation, and storage boundaries are documented in the [navigation extension contract](docs/navigation-extension-contract.md).

Create or refresh the interactive test save with:

```powershell
pwsh -File .\tools\create-test-save.ps1 -Force
```

This installs a development junction in the normal Factorio mods directory, enables the mod, and creates `SCV Control Test.zip` in the normal saves directory. The save contains labelled zones for straight movement, slalom pathfinding, a narrow corridor, queued waypoints, an unreachable target, and future context actions. Use `/scv-test-home` or `/scv-test-reset` inside the save.

The test scenario automatically records every movement click, path request, path result, waypoint, path length, detour ratio, alternate probe, selected candidate, and replan reason to `%APPDATA%\Factorio\script-output\scv-control\planner.jsonl`. Use `/scv-test-clear-log` to start a fresh capture.

Use `/scv-test-bench list` in the developer save to list shared pathfinding fixtures. `/scv-test-bench <fixture-id> [algorithm|all]` loads the same geometry used headlessly and draws comparison paths; `/scv-test-home` returns to the main lab.

In the developer save, every normal completed move plan is also compared against enabled benchmark algorithms and drawn with a checkbox legend. Use `/scv-test-preview off` to disable this or `/scv-test-preview show` to reopen the panel. See the [navigation policy inventory](docs/navigation-policy.md) for all runtime tuning constants.

Zone 7 contains stricter shared detour fixtures for long-wall, reverse-slalom, and U-trap behavior. The lab and benchmark surfaces use permanent daylight. Experimental conclusions and failed approaches are recorded newest-first in the [pathfinding experiment log](docs/pathfinding-experiments.md).

## Roadmap

- Improve path following and recovery around dynamic obstacles.
- Add persistent numbered queue markers.
- Add context commands for mining, repairing, attacking, and entering vehicles.
- Add [belt-aware navigation velocity and route costs](https://github.com/guajun/factorio-scv-control/issues/2).
- Add an optional RTS/direct-control mode switch.
- Add an SCV-style character prototype and original visual assets.
- Add automated packaging and broader local integration checks.

## License

[MIT](LICENSE)
