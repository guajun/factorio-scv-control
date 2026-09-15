# Project progress — 2026-09-15

Target: SC2-like command responsiveness and reliable native-character movement
in a changing Factorio world. This is not a reproduction of SC2's closed-source
implementation. Issue counts are bookkeeping, not a percentage of functionality.

## Delivery state

| Layer | Proven state | Still missing |
| --- | --- | --- |
| Mod interaction and movement | Right-click/queue baseline, planner visualization/logging, native trajectory/follower; historical twitch issue #1 closed. | New experimental solvers have not replaced the normal-save default. |
| Composable production/eval core | Issues #4/#5 merged as PRs #13/#15: shared contracts, registries and PlanningRun. | Broader domain profiles must still compose through those contracts. |
| Execution eval and world facts | #6/#7 merged as PRs #12/#14: condition-driven headless episodes and regional revisions. | World events/caches are not fully wired into production. Inserted-wall episode still records the known recovery failure. |
| External interchange | PR #18: exact snapshot/query/result identity, reference Dijkstra/A*, native replay and live headless loop; all validated on its branch. | PR #18 is not merged. Static distance-only domain; not a general live-world solver. |
| Local transport | Default bulk file plus short RCON messages. Same-input receive/decode/check is about 0.36 s versus 18.85 s legacy chunks. | Diagnostic cold begin-to-admission remains about 10 s. Cache/incremental updates and GUI lifecycle stay in #16. |
| Real gates and belts | Six real-gate cases and 56 belt/ground cases pass repeated native probes, with exact recorded timelines. | Calibration does not provide planner gate actions or a belt-aware cost model. #8/#10 remain open for their full matrices; #9/#2 remain domain integration. |
| Topology quality | #17 first source-polygon backend: all 11 cases retained, ten complete routes pass native replay; tight distance 23.2191 → 20.0661 versus captured grid. | Only static wall/tile geometry. Update/memory/larger-domain and live/GUI integration remain; no default promotion. |
| Dynamic movement | Exact failure baselines available for regression. | #11 corridor invalidation; moving-unit avoidance/deadlock response; production-scale latency and reliability. |

GitHub milestone `SC2-like navigation foundation` currently has four closed
and eight open issues, including tracking #3. Closed: #4, #5, #6, #7. Open:
#3, #8, #9, #10, #2, #11, #16, #17. This does not mean the end-user feature is
one-third complete: foundational work and feature work have different sizes.

## Current wave and ownership

All branches start from framework commit `a770ae4`, not the older dirty user
checkout. No ordinary save or GUI mod junction is changed.

| Lane | Branch / ownership | Bounded delivery |
| --- | --- | --- |
| Gate calibration | `codex/gate-calibration`, gate specialist | Real entities, passive/proactive and force/speed probes; isolated fixtures and timelines. |
| Belt calibration + integration | `codex/domain-calibration-wave`, integration owner | Native displacement matrix, fixed-seed repeated headless runner, common report validation and test integration. |
| Topology backend | `codex/topology-experiment`, solver specialist | Pinned external library built from original geometry, full fixture denominator, native replay evidence. |

Only the integration owner changes central runners, common report validation,
registry indexes, AGENTS and the default profile. The default profile is not
changed by this wave. Do not close an issue merely because its first slice runs.

Next domain-policy gates: #8 evidence → #9 gates/actions; #10 evidence → #2
directed travel-time search; #7 + shared episodes → #11 timely invalidation.
#16 can optimize warm-query latency independently. No GitHub Actions or automatic
GUI launch is introduced; GUI preview/join capability remains explicit/manual.

## Executed validation for the integrated wave

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
