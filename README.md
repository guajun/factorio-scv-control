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
- Each player has an independent, configurable command queue.

This is an early prototype. Save before testing it in an important factory.

## Known limitations

- The mod load and lifecycle are tested locally on Factorio 2.0.77; interactive movement still needs broader gameplay testing.
- Vehicle driving is not supported in this prototype because movement controls remain consumed while the mod is enabled.
- Commands currently target empty ground only; context actions are planned for later versions.

## Installation

For development, place or link this directory into the Factorio `mods` directory. For a release, package the directory as `factorio-scv-control_0.1.0.zip`.

## Local testing

Run the local test harness from PowerShell 7:

```powershell
pwsh -File .\tools\test.ps1
```

The script locates a Factorio installation matching `info.json`, copies the mod into an isolated temporary directory, creates a map, runs 120 simulation ticks, and removes the artifacts. Use `-FactorioExe <path>` to select an installation or `-KeepArtifacts` to retain the test files.

## Roadmap

- Improve path following and recovery around dynamic obstacles.
- Add persistent numbered queue markers.
- Add context commands for mining, repairing, attacking, and entering vehicles.
- Add an optional RTS/direct-control mode switch.
- Add an SCV-style character prototype and original visual assets.
- Add automated packaging and broader local integration checks.

## License

[MIT](LICENSE)
