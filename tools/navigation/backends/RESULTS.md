# First source-topology comparison — 2026-09-15

This is a bounded offline experiment, not a production backend switch or a claim
of optimal Factorio movement. The initial standalone comparison did not execute
Factorio (`replay_status: not-run`). The integration follow-up below now supplies
separate native collision/trajectory/follower evidence for the same results.

## Reproducible input and environment

- Base checkout: `a770ae4`; fixture catalog: `fixture-v4`; Factorio: `2.0.77`.
- Existing capture reused, with no geometry recapture or fixture changes:
  `C:\Users\MSI-NB\AppData\Local\Temp\scv-navigation-eval-1c60eea8eb574482be790771e5c5dd97\capture.json`.
- Capture SHA-256:
  `47fe1246b7417465cff4606a8f1ce75531aa19a3fcb53ef82951b183564514f2`.
- Windows AMD64, Python `3.12.14`, extremitypathfinder `2.7.2`, Shapely `2.1.2`,
  GEOS `3.13.1`, NumPy `1.26.4`, NetworkX `3.5`; exact wheel pins are in
  `requirements-win-py312.lock`. All dependencies are in an ignored local venv.
- Initial Python `3.14.5` attempt failed dependency resolution because the chosen
  library requires NumPy `<2`. Switched interpreter instead of overriding that
  constraint. No global install or GUI launch occurred.

Backend `extremity-source-polygons-v1` derives polygon topology from captured
source walls/tiles. Its configuration keeps the exported trajectory clearance
(`0.44375` tile in these fixtures) and adds a separately recorded `1/256`-tile
contact guard. It does **not** use the captured grid cells or their extra
half-cell-diagonal inflation. There is a 512-vertex preflight bound. These are
explicit, hashed modeling choices, not claims of exact engine collision.

## Outcome and distances

All 11 cases remain in the denominator: **10 complete, 1 no-path, 0 errors,
0 unsupported, 0 dropped** for this static wall-only catalog. Separate tests
verify that actual gates, unknown tile facts, and travel-time objectives remain
explicitly unsupported. The historical `gate-*` cases below are wall gaps, not
real gate behavior.

Distances are tiles. The control is the raw **captured-grid Dijkstra** result,
not the current production planner or a smoothed-grid route. Thus the difference
includes representation and conservative inflation, not just search choice.

| Fixture | Captured grid | Source polygons | Polygon vertices |
| --- | ---: | ---: | ---: |
| open-diagonal | 27.784888 | 27.784888 | 4 |
| long-wall-return | 28.253505 | 25.553298 | 12 |
| long-wall-enter | 32.747889 | 29.044823 | 12 |
| narrow-corridor | 30.000000 | 30.000000 | 12 |
| tight-clearance-corridor | 23.219122 | 20.066104 | 12 |
| u-trap | 37.556349 | 34.346558 | 16 |
| slalom | 44.627417 | 42.031363 | 20 |
| captured-slalom-return | 38.358487 | 35.103094 | 24 |
| gate-open | 20.000000 | 20.000000 | 12 |
| gate-closed | 28.041631 | 26.645927 | 8 |
| unreachable-box | no-path | no-path | — |

For every complete result, the real library path length matches the existing
Python Dijkstra on the **same exported polygon query graph**. Every exported
library edge passes independent GEOS free-space containment. A repeated query on
the same prepared environment returns identical points and length. These checks
verify the offline representation/search boundary; they do not replace native
collision validation and arrival measurements.

The tight fixture retains exact endpoints `(9.9296875, -9.87890625)` and
`(9.9296875, 9.8671875)`, source snapshot hash
`scv-c14n1-adler32:38589952:160673`, and source query hash
`scv-c14n1-adler32:9a1181d6:1098`.

## Timing scope

Single measured pass; milliseconds below are descriptive, not performance
thresholds or statistical benchmarks. Build includes the library's visibility
graph preparation; warm search uses the same prepared geometry.

| Fixture | Geometry | Build | Search | Warm search |
| --- | ---: | ---: | ---: | ---: |
| open-diagonal | 1.404 | 0.431 | 0.367 | 0.240 |
| long-wall-return | 5.850 | 2.682 | 1.204 | 1.043 |
| long-wall-enter | 5.094 | 3.080 | 1.217 | 1.173 |
| narrow-corridor | 7.004 | 2.735 | 0.472 | 0.491 |
| tight-clearance-corridor | 1.918 | 2.346 | 0.765 | 0.757 |
| u-trap | 4.759 | 4.345 | 1.184 | 1.095 |
| slalom | 4.086 | 5.076 | 1.031 | 1.066 |
| captured-slalom-return | 3.005 | 15.046 | 2.585 | 2.499 |
| gate-open | 2.279 | 3.409 | 0.758 | 0.708 |
| gate-closed | 1.601 | 0.980 | 0.560 | 0.547 |
| unreachable-box | 4.046 | 0 | 0 | — |

The sum of full per-case adapter times is **17,732.378 ms**, including repeated
input validation, canonical hashing, copies and captured-grid reference solves;
JSON reading and report/Lua output writing are outside that sum. Small geometry
and search timings must not be presented as total end-to-end cost. The source
capture itself was reused and is not timed here. A future reusable world cache
would need its own measured build/update/query lifecycle.

## Validation and next boundary

- Optional backend unit suite: **7 tests passed**.
- Required `tools/test.ps1 -Suite all`: **passed**, entirely headless on Factorio
  `2.0.77`: smoke; 107 integration assertions; 11 fixtures × 10 existing benchmark
  algorithms; 3 episodes; 11 interchange assertions; 36 host tests; 7 live checks.
  This existing suite does not automatically install or evaluate the optional
  topology backend, and its replay result is not evidence for the new paths.
- Measured local artifacts are under
  `tools/navigation/backends/artifacts/measured/`: `comparison.json`,
  `solver-bundle.json`, and `imported_plans.lua` (ignored, not vendored).

The integration owner added **offline-only** backend admission and two engine
conformance checks: imported topology retains shared validators, and it cannot
silently enable the live backend. `replay_bundle.py` validated the exact solver
bundle and ran all 11 cases in an isolated project copy: **33 assertions passed**,
all ten complete routes arrived; the bounded no-path remains rejected rather
than being treated as arrival. Neither `production-v1` nor its validators or
follower were changed.

Native manifest: local temp `scv-bundle-replay-yy0qxgtz/manifest.json`.
Replay reports/raw and accepted routes: local temp
`factorio-scv-agent-test-461d06a5f33242a098c5094b63eee605/write-data/script-output/scv-control/navigation/`.
These are machine-local diagnostic locations, not portable checked-in fixtures.
Reproduce using the README's compare and replay commands. The full-wave test
counts are documented in `docs/project-progress.md`, separately from the
specialist's pre-integration validation above.

Decision from this first pass: the source-geometry boundary is executable and
can compare a real third-party topology builder without grid retuning or via
heuristics. The bounded native replay now passes, but keep it optional pending
broader evaluation. Dynamic updates, actual gates, belts, temporal costs, native search
cancellation, and larger-world watchdog/cache behavior are still unsupported.
