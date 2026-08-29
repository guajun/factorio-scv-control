# Local Agent TestKit

SCV Control uses a repository-local development Mod and a PowerShell process runner. No GitHub Actions workflow is required.

## Agent loop

```text
edit production modules
  -> tools/test.ps1 creates an isolated mod directory
  -> Factorio smoke-loads and benchmarks the mod
  -> a headless automated scenario builds deterministic fixtures
  -> production path/follower/input modules run against real Factorio objects
  -> JSON assertions and a completion marker are emitted
  -> the runner returns success/failure and cleans up
```

Run everything:

```powershell
pwsh -NoProfile -File .\tools\test.ps1 -Suite all
```

Available suites:

| Suite | Purpose |
| --- | --- |
| `smoke` | Loads settings/data/control stages and exits after Factorio successfully creates a map. |
| `integration` | Runs deterministic engine-backed tasks until planning, character movement, queue execution, and failure cases actually complete. |
| `all` | Runs both suites. This is the required pre-commit command. |

Use `-Verbose` for Factorio stdout. Successful runs clean their temporary directory. Failures retain it and print its path; `-KeepArtifacts` retains successful artifacts as well.

## Reports

The integration scenario writes:

```text
<test-root>/write-data/script-output/scv-control/test-results.json
```

The schema includes Factorio and Mod versions, actual duration ticks, pass/fail totals, and per-assertion completion details. The engine log also contains:

```text
SCV_TESTKIT_REPORT {...}
SCV_TESTKIT_COMPLETE passed=N failed=N
```

The external runner treats missing reports, timeouts, Lua errors, and failed assertions as nonzero exits.

The integration suite does not use a fixed tick count as a success condition. It exits when every task reaches its terminal assertion. `TEST_TIMEOUT_TICKS` is only a failure guard for deadlocks and regressions.

## Adding a regression

1. Put reusable behavior in a production module under `scripts/`.
2. Add the smallest deterministic fixture to `devmods/scv-control-testkit/scenarios/automated/runner.lua`.
3. Assert bounded outcomes such as path length, detour ratio, arrival error, selected candidate, or failure status.
4. Run `-Suite integration`, then `-Suite all`.

The corridor regression uses the exact coordinates captured by the planner logger. Factorio's baseline path is about 46.09 tiles; the shared alternate-via calculation produces a path near 35.35 tiles and must stay below 38.

## Reload behavior

- Runtime files (`control.lua` and `scripts/*.lua`): reload the save or call `game.reload_mods()` in singleplayer.
- Test-lab control code: same behavior, because only a marker is embedded; behavior runs from `scv-control-testkit`.
- Prototype, settings, custom-input, or locale changes: restart Factorio.
- Enabled Mod set changes: regenerate the interactive test save with `tools/create-test-save.ps1 -Force`.
