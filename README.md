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
- Arbitrary path segments are followed through hysteresis-controlled decomposition into native movement directions.
- Each player has an independent, configurable command queue.

This is an early prototype. Save before testing it in an important factory.

## Known limitations

- The mod load and lifecycle are tested locally on Factorio 2.0.77; interactive movement still needs broader gameplay testing.
- Vehicle driving is not supported in this prototype because movement controls remain consumed while the mod is enabled.
- Commands currently target empty ground only; context actions are planned for later versions.

## Installation

For development, place or link this directory into the Factorio `mods` directory. For a release, package the directory as `factorio-scv-control_0.1.0.zip`.

## Local testing

Run the fully headless agent test harness from PowerShell 7:

```powershell
pwsh -File .\tools\test.ps1
```

The default command runs smoke and engine-backed integration suites in an isolated temporary directory. It validates loading, path optimization, completed character movement, completed command queues, cursor-to-command translation, and unreachable targets. Integration exits when all tasks reach terminal assertions; fixed ticks are used only as failure timeouts. See [testing](docs/testing.md) and [trajectory planning](docs/trajectory.md).

Create or refresh the interactive test save with:

```powershell
pwsh -File .\tools\create-test-save.ps1 -Force
```

This installs a development junction in the normal Factorio mods directory, enables the mod, and creates `SCV Control Test.zip` in the normal saves directory. The save contains labelled zones for straight movement, slalom pathfinding, a narrow corridor, queued waypoints, an unreachable target, and future context actions. Use `/scv-test-home` or `/scv-test-reset` inside the save.

The test scenario automatically records every movement click, path request, path result, waypoint, path length, detour ratio, alternate probe, selected candidate, and replan reason to `%APPDATA%\Factorio\script-output\scv-control\planner.jsonl`. Use `/scv-test-clear-log` to start a fresh capture.

## Roadmap

- Improve path following and recovery around dynamic obstacles.
- Add persistent numbered queue markers.
- Add context commands for mining, repairing, attacking, and entering vehicles.
- Add an optional RTS/direct-control mode switch.
- Add an SCV-style character prototype and original visual assets.
- Add automated packaging and broader local integration checks.

## License

[MIT](LICENSE)
