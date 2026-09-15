# Project progress — 2026-09-15

Target: SC2-like command responsiveness and reliable native-character movement
in a changing Factorio world. This is not a reproduction of SC2's closed-source
implementation. Issue counts are bookkeeping, not a percentage of functionality.

Review boundary: [PR #18](https://github.com/guajun/factorio-scv-control/pull/18)
contains the external framework;
[PR #19](https://github.com/guajun/factorio-scv-control/pull/19) contains native
calibration and source-polygon replay, stacked on #18's branch. The new
execution wave is [PR #20](https://github.com/guajun/factorio-scv-control/pull/20)
on `codex/domain-execution-wave`, following #19. The saved-map follow-up is on
`codex/save-backed-testbench`, based on execution commit `0f07a87`. The preceding
three PRs remain unmerged as of this checkpoint; review the foundation first.

## Delivery state

| Layer | Proven state | Still missing |
| --- | --- | --- |
| Mod interaction and movement | Right-click/queue baseline, planner visualization/logging, native trajectory/follower; historical twitch issue #1 closed. | New experimental solvers have not replaced the normal-save default. |
| Composable production/eval core | Issues #4/#5 merged as PRs #13/#15: shared contracts, registries and PlanningRun. | Broader domain profiles must still compose through those contracts. |
| Execution eval and world facts | #6/#7 merged as PRs #12/#14: condition-driven headless episodes and regional revisions. | World events/caches are not fully wired into production. Inserted-wall episode still records the known recovery failure. |
| External interchange | PR #18: exact snapshot/query/result identity, reference Dijkstra/A*, native replay and live headless loop; all validated on its branch. | PR #18 is not merged. Static distance-only domain; not a general live-world solver. |
| Local transport | Default bulk file plus short RCON messages. Same-input receive/decode/check is about 0.36 s versus 18.85 s legacy chunks. | Diagnostic cold begin-to-admission remains about 10 s. Cache/incremental updates and GUI lifecycle stay in #16. |
| Real gates | Six calibration cases, then ten action/follower cases: safe normal/fast opening, close-start waiting, eligibility rejection and changing preconditions. | Current static validator still rejects an opened gate. Shared semantic admission, gate-versus-detour cost and production profile integration remain in #9; broader force/circuit calibration remains in #8. |
| Belts | 56 native calibration cases; measured discrete velocity hull, directed cost prototype and 30 native controller arrivals plus four model cases. Saved replay binds its goal/width independently of current defaults. Express crossing drift 5.0625 → 0.2461 tiles, time 142 → 70 ticks. | Uniform unobstructed fields only. No time-aware route search, swept-wall validation, field boundaries, equipment, dynamic controller refresh or stationary holding; #2/#10 stay open. |
| Topology quality | #17 first source-polygon backend: all 11 cases retained, ten complete routes pass native replay; tight distance 23.2191 → 20.0661 versus captured grid. | Only static wall/tile geometry. Update/memory/larger-domain and live/GUI integration remain; no default promotion. |
| Dynamic movement | New shared PlanningRun/Follower wrapper stops on-route construction in its event and requests replan one tick later; native off-route/behind/removal/forward-belt controls and pure policy cases. Historical failure stays as a control. | Test adapter only. Motion/transient notifications lack a control/avoidance consumer; production event coverage, external committed generations and aggregate frame-time budgets remain in #11. |
| Native source maps | 45 directly openable gate/dynamic/belt saves, source ZIP/facts/mod hashes, fresh-process replay with zero geometry builders; each case records actual native outcomes and script-hook timing. | Current corpus covers this domain execution wave. Derived grids/state tables still need their own equivalence tests; larger factory performance remains unproven. |
| External debug clock | Saved long-wall map, real capture/solver/admission while frozen, native exact stepping to arrival; 16 checks plus retained seven-check realtime loop. | Stepping proves correctness, not realtime speed. Cold capture and solver remain expensive. |

GitHub milestone `SC2-like navigation foundation` currently has four closed
and eight open issues, including tracking #3. Closed: #4, #5, #6, #7. Open:
#3, #8, #9, #10, #2, #11, #16, #17. This does not mean the end-user feature is
one-third complete: foundational work and feature work have different sizes.

## Current wave and ownership

The current saved-map branch starts from execution commit `0f07a87`, not the
older dirty user checkout. Native source maps are retained outside the checkout
at `F:\factorio-scv-testbench\corpora`. No ordinary save or GUI mod junction is
changed. Three parallel lanes own source-map runtime, observed-facts contracts,
and native solver stepping; the integration owner owns the host runner, common
validation and final evidence. The [saved-map guide](save-backed-testbench.md)
documents opening maps and replaying the same corpus with a different checkout.

The preceding execution wave used these bounded ownership lanes:

| Lane | Branch / ownership | Bounded delivery |
| --- | --- | --- |
| Gate actions | `codex/gate-actions`, gate specialist | Same-force automatic semantics and proactive action; real shared-Follower crossing and rejection/invalidation cases. |
| Corridor response | `codex/corridor-invalidation`, execution specialist | Inflated remaining-route checks, event-time stops, shared replan, bounded/coalesced dirty work and native/policy regressions. |
| Belt control | `codex/belt-controller`, motion specialist | Calibrated native velocity model, feasibility and directed cost, drift compensation with an unchanged-Follower control. |
| Integration | `codex/domain-execution-wave`, integration owner | Shared replan hook, repeated execution runner, independent review, complete validation and concrete design/experiment log. |

Only the integration owner changes central runners, common report validation,
registry indexes, AGENTS and the default profile. The default profile is not
changed by this wave. Do not close an issue merely because its first slice runs.

Next promotion gates: gate semantic collision admission; directed travel-time
search with motion boundaries; production corridor/event integration and
safe holding on belts. The [concrete design](navigation-domain-execution-plan.md)
spells out representation, planning, execution and the combined-domain test.
#16 can optimize warm-query latency independently. No GitHub Actions or automatic
GUI launch is introduced; GUI preview/join capability remains explicit/manual.

## Execution wave validation

The integrated `pwsh -NoProfile -File .\tools\test.ps1 -Suite all -KeepArtifacts`
passes on Factorio 2.0.77. It includes smoke, 109 engine integration assertions,
the unchanged 11 x 10 static benchmark, three historical episodes, the previous
6 gate / 56 belt calibrations twice, the new domains below twice, 11 interchange
assertions, 46 host tests and seven live headless checks.

| New domain | Cases / assertions per repetition | What the denominator includes |
| --- | --- | --- |
| Gate actions | 10 / 68 | Three native arrivals, three eligibility rejections, four changed-precondition stops |
| Corridor response | 18 / 89 | Five native arrivals, thirteen policy checks |
| Belt controller | 33 / 188 | Thirty native arrivals including unchanged-Follower controls, three model checks |

All 61 cases / 345 assertions pass in each repetition with exact case records.
There are 38 actual arrivals, not 61. The existing follower's belt control cases
arrive after leaving the requested corridor, and assert that limitation; their
pass does not claim corridor safety. The old inserted-wall episode still expects
failure and remains separate from the new proactive-recovery episode.

Retained artifacts in local temp:
`factorio-scv-agent-test-db530da3a8264745abd38bec42619f04` (main suite),
`scv-calibration-dl3fhajz` (new repeated domains),
`scv-calibration-q3eavom3` (original domain calibration), and
`factorio-scv-live-cm8h337s` (live loop). No graphical client was launched.

Independent review caught and fixed scan starvation from repeated duplicate
events during bounded work; the native removal case also caught a false safety
pause despite zero replans. Both now have exact regressions. The newest
[experiment entry](pathfinding-experiments.md) preserves these failures.

## Prior calibration/topology wave validation

`pwsh -NoProfile -File .\tools\test.ps1 -Suite all -KeepArtifacts` passes on
Factorio 2.0.77: smoke, 109 engine integration assertions, the unchanged 11 × 10
static benchmark, three episode baselines, six gate and 56 belt/ground cases
each repeated twice, 11 interchange assertions, 46 standard-library host tests,
and seven live external/native-follower checks. The optional backend's seven
dependency-backed tests also pass in its pinned environment.

The new `replay_bundle.py` independently passes 33 Factorio assertions for the
third-party solver bundle. Tight's native movement arrives in 89 ticks with
0.304813-tile endpoint error under the unchanged 0.3375-tile follower bound;
planned length and actual traveled distance remain separate measurements.

Integrated test artifacts: local temp
`factorio-scv-agent-test-359209192404490599e7fe85efee4a3e` and
`factorio-scv-live-izmkapwu`. New-backend replay manifest:
`scv-bundle-replay-yy0qxgtz`, pointing to
`factorio-scv-agent-test-461d06a5f33242a098c5094b63eee605`.
No graphical client or GUI peer was launched by these tests.
The integrated repeated domain reports are retained in local temp
`scv-calibration-jzzv31f5/calibration-summary.json`.
