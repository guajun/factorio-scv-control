# 2026-09-15 - Remaining-corridor event response

Issue #11, isolated `codex/corridor-invalidation` experiment on domain-wave base `765dad0`. The production profile and the historical `wall-inserted-ahead` expected-failure episode remain unchanged. The new adapter delegates all planning, route acceptance, trajectory generation and movement to the shared `PlanningRun`/`Follower` implementation.

## Native measurements

Factorio 2.0.77, base + SCV + TestKit, fixed seed 424242. Five native episodes and thirteen policy cases passed twice with identical complete case reports. Final focused artifact: `C:\Users\MSI-NB\AppData\Local\Temp\scv-calibration-51cqk6yh`.

| Native episode | Replans / immediate stops / safety holds | Travel ticks | Arrival error |
| --- | --- | --- | --- |
| Wall built across remaining route | 1 / 1 / 0 | 126 | 0.15625 |
| Wall built outside route | 0 / 0 / 0 | 108 | 0.17578125 |
| Wall built behind actor | 0 / 0 / 0 | 108 | 0.17578125 |
| Blocking wall removed during approach | 0 / 0 / 0 | 123 | 0.2720107869 |
| Forward belt built on active path | 0 / 0 / 0 | 106 | 0.12109375 |

Coordinates are shared fixture definitions in `episodes/fixtures/corridor.lua`. Ordinary cases start at `(-12, 0)`, target `(12, 0)`, and trigger the edit after projected progress reaches four tiles. The blocking line is requested at `x=0`, `y=-3..3`; Factorio centers the actual seven wall entities at `x=0.5`, `y=-2.5..3.5`. The behind-actor case triggers at eight tiles. The belt case uses `y=0.5` and four east-facing yellow belts.

The on-route callback stops at tick 20. Native position on tick 21 is unchanged, rather than inferring a stop from `walking_state`. The replacement plan starts one tick after the event, at center-to-center distance 8.5068941768 from the closest wall. It arrives with no stuck/recovery event. The seven edits coalesce into two regional groups; the first intersecting group needs three segment/box tests. Native assertions allow at most two completed groups and eight tests per update, and eight immediate tests per event. All cases report zero full-surface rescans.

The removal episode retains its original 25.3162303675-tile detour, one accepted route, and zero replans or pauses. Removing an obstruction can make a cheaper route available without making the current one unsafe; optional optimization is deliberately absent. The aligned belt episode reports four motion revisions, zero topology revisions and one motion-refresh notification. Its arrival does not prove arbitrary belt-drift control or travel-time prediction.

## Failed assumptions retained

1. **Destructible fixture walls are equivalent to the shared wall fixtures.** False. The first run (`scv-calibration-mf0h56n1`) stopped before impact and replanned promptly, but engine candidates attempted the breakable neutral obstruction and failed shared live validators (`no-safe-candidate`). The scenario had omitted the existing fixture convention `destructible=false`; matching that convention made replanning succeed. No planner tuning or validator relaxation was applied. Supporting demolition remains outside this experiment.
2. **World dependencies can be inserted directly into a Route.** False. Raw world dependency facts lacked `schema_version`; terminal route validation rejected them. The adapter now explicitly stamps the versioned dependency contract rather than weakening validation.
3. **Zero replans means uninterrupted execution.** False. Budgeted removal processing initially returned `hold` and paused the native removal case for one tick (`scv-calibration-kfyu1oo4`). Only pending blocking topology now requires a hold; notification-only work continues in the background. Both a native zero-hold assertion and a deferred-removal policy regression cover it.
4. **A regional union is a safe exact collision proxy.** False for two distinct off-route edits whose union crosses a diagonal route. Groups retain individual boxes for narrow-phase checks; a regression checks this geometry explicitly.
5. **Resetting scans for coalesced events is harmless.** False for repeated identical callbacks during a bounded scan: every update could restart the same prefix and hold indefinitely. Cursors reset only when new geometry enlarges the active group. Regressions inject duplicate active-group events, duplicate later-group events, and genuinely new later-group geometry while scanning.
6. **A control getter proves the just-issued stop.** Factorio can expose the previous applied control within the same callback tick. Stop commands are deduplicated by tick, and the following native tick verifies zero displacement.

## Scope and next composition

The scenario consumes real `script_raised_built`/`script_raised_destroy` callbacks through the existing normalized world events, with exact entity bounds and assigned revisions. Other event kinds remain supported by the world module but are not wired or proven by this wrapper. Accepted routes gain regional dependencies; entity dependencies supplied by other route providers are retained. It does not scan every possible neighboring entity or subscribe production `control.lua`.

Transient events produce local-response notifications, with a policy assertion that they do not become topology replans. A local steering/timeout consumer is still required. Motion notifications need a feasibility/prediction consumer; a cross-belt or reverse-belt event cannot safely inherit the aligned fixture's conclusion. Queue overflow triggers a diagnostic fail-closed replan; repeated genuine blocking construction is not debounced by continuing on unsafe stale paths.

The integration owner adds this scenario to the common calibration runner; the specialist invocation is the integration runner with `--domain dynamic --project-root F:\factorio-scv-control-corridor`. The required `-Suite all` remains fully headless; the existing inserted-wall failure baseline is preserved alongside the new proactive-recovery episode.
