# Comparing planners on saved native maps

`tools/test.ps1 -Suite compare` loads eleven persistent source ZIPs with four
configurations each. The default `all` suite includes this 44-row matrix in
addition to the 45 gate/dynamic/belt save replays. Tests never launch a GUI.

Each row starts a fresh headless Factorio process on the exact same case ZIP,
verifies its native facts and actor origin, captures the bounded map, plans,
passes shared admission, then runs the real character to a terminal condition.
Neither fixture builders nor replay geometry constructors run after loading.
The saved world stays paused during external solver work; movement runs at
normal game speed. Tick and host wall limits are failure guards.

## Configurations and interpretation

| Configuration | Representation and planning | Execution |
| --- | --- | --- |
| `production-v1` | Existing engine/local-grid comparison and safe string pulling; cold and repeat requests before movement | Shared PlanningRun and native Follower, executing the repeat result |
| `grid-astar` | Captured conservative grid; existing external A* | Imported exact route through shared validators and native Follower |
| `grid-dijkstra` | The identical captured directed graph, with zero heuristic | Identical imported admission and native Follower |
| `source-polygons` | Native tile/wall facts compiled by the pinned extremitypathfinder adapter | Derived identity and graph admitted against the original source; shared validators and Follower |

This compares complete configurations. Production postprocessing is part of
its result; imported routes deliberately remain exact. A* and Dijkstra compare
search on the same graph. Polygon versus grid compares representations and
their construction as well. Same-graph Dijkstra references, repeat consistency,
and native execution are separate checks. A Dijkstra optimum on a conservative
grid does not establish shortest possible movement in Factorio.

All eleven fixture-v4 cases are retained, including `unreachable-box`. The
historical `gate-open` and `gate-closed` names describe wall-gap geometry; they
do not test real automatic gates. Real gates belong to the 45-case source
corpus. Static source maps have native `out-of-map` tiles outside their query
bounds, so the engine and external solver share the same navigable domain.
This added boundary policy is recorded in source facts and does not rewrite
the historical benchmark or domain maps.

## Reproduce

The host uses ordinary Python; the optional polygon worker requires the pinned
Python 3.12 environment described in [the backend guide](../tools/navigation/backends/README.md).
On this machine it is installed at
`F:\factorio-scv-testbench\runtime-static\Scripts\python.exe`. To provision the
default sibling environment on another Windows checkout:

```powershell
py -3.12 -m venv ..\factorio-scv-testbench\runtime-static
..\factorio-scv-testbench\runtime-static\Scripts\python.exe -m pip install --require-hashes --only-binary=:all: -r .\tools\navigation\backends\requirements-win-py312.lock
pwsh -NoProfile -File .\tools\test.ps1 -Suite compare
```

Missing dependencies fail their rows; they are never silently omitted. Use
`-TopologyPython C:\path\to\python.exe` to select another pinned environment.
Standalone diagnostic commands:

```powershell
# Author a new complete corpus and compare it; previous sources are retained.
python tools/navigation/compare_saved.py --build

# Reuse a specific immutable source corpus with current code.
python tools/navigation/compare_saved.py --corpus F:\factorio-scv-testbench\static-corpora\VERSION

# Explicit partial investigation, keeping every selected algorithm/outcome.
python tools/navigation/compare_saved.py --case tight-clearance-corridor --algorithm production-v1 --algorithm source-polygons
```

`factorio-scv-testbench/latest-static.json` identifies the latest complete static
corpus. A partial diagnostic build never replaces that pointer. The original
domain corpus uses its separate `latest.json`. Archived source mods, source ZIP
SHA-256 and observed facts are verified before evaluation; evaluation uses
current mod copies. Source artifacts are not rewritten to make a new algorithm
pass. Native version, implementation hashes and dependency versions accompany
the report.

The first complete local static corpus is
`F:\factorio-scv-testbench\static-corpora\v1-20260915-230807-161ad4`.
The earlier three-map diagnostic corpus `v1-20260915-230243-084335` is also
retained; it passed twelve native comparison rows before the full matrix.

## Reports and timing

Durable reports live under `factorio-scv-testbench/comparisons/VERSION`:
`comparison.md` is the compact table; `comparison.json` contains all rows.
Detailed capture/solver/native reports and logs remain in the printed temporary
artifact directory. Every matrix member appears even when capture, planning,
admission or movement fails. Native arrival cannot hide reference disagreement;
unsupported, budget exhaustion and watchdogs cannot count as `no-path`.

The final initial-wave report is
`F:\factorio-scv-testbench\comparisons\v1-20260915-232708-989d05\comparison.json`
and its sibling `comparison.md`. All 44 rows pass and reproduce the first full
run's accepted paths and native travel ticks after the direction-counter fix.

The host correlates ZIP/facts hashes, captured snapshot/query identity, derived
compiler binding, raw/accepted paths, actual travel distance/ticks, arrival
error, direction changes, assertions and timings. `command_direction_changes`
counts consecutive issued directions across waypoint transitions, with
`issued_direction_samples` as its denominator. The legacy `direction_switches`
field counts only hysteresis switches within a single trajectory segment.
Production sometimes does
not retain a pre-smoothing local-grid path; those raw values are explicitly
unavailable rather than copied from the accepted path.

Performance scopes are deliberately separate:

- Native `source_check`, capture, planning callbacks, admission and movement
  hooks use LuaProfiler. Hook samples, aggregates, p95 and peaks are reported;
  they are not full engine CPU measurements.
  Common source verification/capture is comparison overhead for production,
  not work required by an ordinary production right-click.
- Host capture, solver process, upload/admission and native execution have wall
  timings. Solver process time includes the experiment's repeated queries and
  references, so it is not single-query latency.
- Grid cold/repeated end-to-end solve includes validation and graph indexing;
  repeated calls do not claim a prepared cache.
- Polygon geometry compilation, prepared-map construction, first query and a
  genuine repeated query on that prepared map are measured separately. Full
  backend time also includes independent references and validation.
- Frozen solver waits prove correctness, not realtime capability. Native
  movement is measured on the loaded source map at game speed one.

## Manual game inspection

Each corpus contains `open-save.ps1`, `OPEN-MAPS.txt`, an isolated client config
and archived mods. Run the launcher manually with `-Save saves/<filename>.zip`.
It opens that exact ZIP paused, with a spectator and start/goal labels in daylight.
`/scv-compare plan` draws the production result; `/scv-compare run` executes it.
Use `/scv-compare pause` or `status`, and reload the source ZIP to repeat. Save
manual edits under a new name.

External algorithms are exercised and drawn by the host protocol; this command
does not yet expose a GUI algorithm selector. Existing developer-lab benchmark
and imported-plan preview remain available. No automated test opens a graphical
client or changes the normal Factorio mod junction.
