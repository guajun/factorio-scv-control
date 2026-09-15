# Pathfinding Experiment Log

New entries go at the top. Keep failed hypotheses and operational mistakes: the purpose of this log is to prevent the same plausible shortcut from being rediscovered without its failure context.

Each entry should state the question, exact fixture/version, measured result, falsified assumption, and decision. Generated JSON remains the source of exact per-path data; this document records why the result changed the design.

## 2026-09-15 - Four planner configurations on identical saved static worlds

**Question:** Do production-v1, captured-grid A*, Dijkstra and source polygons differ in native movement when every row starts from the same authoritative ZIP, actor and task?

**Boundary:** `codex/saved-solver-comparison` starts at saved-map commit `1cdbb94`. The new corpus preserves all eleven shared static fixtures, including the unreachable case. Its native `out-of-map` perimeter makes external coverage a real world boundary for the engine too; this policy is recorded in saved facts rather than silently clipping only the external solver. Each configuration loads each case in a fresh process, with zero geometry builders after loading. All use shared PlanningRun admission and native Replay/Follower execution. Production keeps safe string pulling; external graph/polygon routes remain exact, so representation and postprocessing differences must be distinguished from A* versus Dijkstra search differences. Historical `gate-open`/`gate-closed` fixtures are wall-gap controls, not automatic gates.

**Initial native result:** The three-map diagnostic corpus `v1-20260915-230243-084335` passed 12/12. The first complete corpus is `F:\factorio-scv-testbench\static-corpora\v1-20260915-230807-161ad4`; its first comparison passed all 44 rows: forty arrivals and four expected no-path results. All grid A* results agree with Dijkstra's cost on the exact captured graph. Across ten reachable cases, source polygons have shorter accepted paths than production in seven and equal lengths in three; six arrive earlier and four tie. This small static set does not establish a general optimality or realtime claim.

| Fixture | Production length / ticks | Captured grid A* length / ticks | Source polygons length / ticks |
| --- | ---: | ---: | ---: |
| open-diagonal | 27.7849 / 133 | 27.7849 / 133 | 27.7849 / 133 |
| long-wall-return | 26.8146 / 123 | 28.2535 / 124 | 25.5533 / 116 |
| long-wall-enter | 30.1992 / 143 | 32.7479 / 144 | 29.0448 / 137 |
| tight-clearance-corridor | 20.1705 / 89 | 23.2191 / 101 | 20.0661 / 89 |
| u-trap | 35.6876 / 164 | 37.5563 / 166 | 34.3466 / 156 |
| slalom | 42.7522 / 199 | 44.6274 / 200 | 42.0314 / 194 |
| captured-slalom-return | 36.6805 / 170 | 38.3585 / 172 | 35.1031 / 165 |

Values above are compact rounded observations; exact paths and values live in the first report, `F:\factorio-scv-testbench\comparisons\v1-20260915-230807-161ad4\comparison.json`, with artifacts in local temp `scv-static-compare-mnri7hbe`. This report precedes the direction-counter correction below. Final integrated evidence is recorded in [project progress](project-progress.md).

**Falsified assumptions:** Equal graph cost does not imply identical native travel time. In slalom, A* and Dijkstra both cost 44.627416998, but return 76 versus 75 points and arrive in 200 versus 199 ticks. The tight polygon route saves about 0.1044 tiles versus production but both arrive in 89 ticks. Distance, arrival tolerance, waypoint layout and discrete native movement are different quantities; reducing geometric length alone does not guarantee a tick improvement. Production does not preserve every pre-smoothing local-grid path, so unavailable raw metrics remain explicitly unavailable.

**Instrumentation pitfall:** The inherited `direction_switches` counter was zero on the 75/76-point slalom routes. It counted `Trajectory.switched`, which resets at each waypoint, and therefore missed all transitions between grid segments. The new `command_direction_changes` compares consecutive `selected_direction` diagnostics emitted by the real Follower across waypoints, with an explicit sample denominator; initial direction and final stop are excluded. The old field retains its within-segment scope. Two regression assertions drive the shared Follower/Replay across east/south/east observations, and saved slalom/U-trap arrivals require observed direction changes. No movement command or algorithm is changed by this fix.

**Performance scope:** On the first long-wall-return sample, source-polygon compilation/build/first-query/prepared-repeat took about 6.40/4.02/1.29/1.11 ms. The end-to-end experiment is much slower: it captures a full grid control, validates and hashes data repeatedly, and performs repeated queries plus Dijkstra references. Open-diagonal grid admission alone measured 5,359 ms in the initial diagnostic run. These are retained costs, not hidden under a millisecond library search label. Frozen external waits prove correctness; normal-speed native movement and Lua hook timing still supply the engine-backed execution evidence. Source checking and shared capture are comparison overhead for production and are not attributed to an ordinary production right-click.

**Operational failures retained:** The first integration wiring tried to `require` the contract tests during on_init; Factorio requires module loading during control parsing. Hoisting it then exposed the scenario-relative module path; a qualified companion-mod require fixed that. Artifacts `factorio-scv-agent-test-0958110c0a9e43e2b96a2330686b2665` retain the first failure. Independent review also caught no-path verdicts that could have trusted a budget/unsupported planning outcome, malformed assertion/profiler types, incomplete matrices, and mislabeled derived backends. The host/native boundaries now test these explicitly instead of treating native arrival or a matching hash as sufficient evidence.

**Final verification:** Required `-Suite all -KeepArtifacts` passes, including 131 integration assertions, all 45 existing domain saves, all 44 static comparison rows, 95 host tests (the optional dependency case is additionally verified in pinned Python), seven realtime and sixteen stepped checks. Final static evidence is `F:\factorio-scv-testbench\comparisons\v1-20260915-232708-989d05\comparison.json`, with local temp `scv-static-compare-88ctapxc`. All 44 accepted paths and native travel tick counts exactly match the earlier full run after the observational fix. Slalom now reports 4/6 actual issued-direction changes for grid A*/Dijkstra, versus 17 production and 15 polygon; fewest direction changes is not the same as shortest or fastest. Final polygon first-query samples are 0.54–2.24 ms, but full capture reaches 6.16 s and upload/admission 2.53 s. Production's own cold planning callbacks peak at 605.49 ms on long-wall-enter and 595.40 ms on slalom, including local comparison/validation work. These are additional measured performance constraints, not failures erased by the 44 passing functional rows.

**Decision:** Keep the 44-row source-save comparison in default headless validation, beside the existing 45 domain maps. Preserve the current production profile while using the polygon results as a measured topology candidate. The next performance target is resident derived data and bounded validation/update work; replacing the search algorithm alone does not solve the measured cold pipeline cost. Automatic gates, dynamic edits and belt travel-time routing remain separate domain promotion gates. See [the comparison protocol and commands](saved-solver-comparison.md).

## 2026-09-15 - Saved native maps as the oracle, with exact external-solver stepping

**Question:** Can a human open the same native map used by automated evaluation, while current algorithms recompile their derived state and a slow external solver can be tested without advancing the world?

**Source boundary:** `codex/save-backed-testbench` starts at execution commit `0f07a87`. The prior probes did use real headless Factorio entities, but generated their worlds inside the run rather than retaining a common pre-command save. The new v1 corpus contains 45 actual ZIPs: ten gate/action cases, five dynamic episodes and thirty belt cases. Each source is built in a fresh process, frozen before execution, published with observed native tile/entity/actor facts, and loaded by another process. Source ZIP SHA-256, facts hash and copied-mod fingerprint identify the experiment. The complete corpus is `F:\factorio-scv-testbench\corpora\v1-20260915-174358-8e2cde`; its manual launcher opens those same maps, and automation never launches a GUI.

**First failure preserved:** In the initial three-case corpus `v1-20260915-173451-f5befb`, `same-force-fast-follower` failed after loading. A paused RPC armed the command, then `on_tick` sampled it again at the same tick before physical movement. This invented a zero-speed collision and queried an intermediate gate state. Recording the last native update tick corrected the scheduling error; it did not change the gate opening threshold. All three original ZIPs then passed unchanged, with `loaded_from_save=true`, `source_verified=true`, `runtime_build_calls=0`, and one derived compile. Gate crossing took 32 ticks, `wall-built-on-remaining-route` 127 ticks, and blue east crossing with compensation 70 ticks. Failure artifacts remain in local temp `scv-savebench-ywk2k5l1`; corrected replay is `scv-savebench-ryivq_8k`.

**What may be recompiled:** Gate actions, motion fields and PlanningRun state use the current implementation and the persisted native entities. Geometry factories do not run during replay. Review caught a belt task being reconstructed from current default direction/distance/width, which could change the experiment while keeping the old map. Replay now binds the saved goal and corridor width; a regression changes current defaults and checks that the stored task is unchanged. Derived grids, meshes or precomputed edit tables may use the new source binding, but their equivalence still requires paired results and native execution. The canonical facts hash omits incarnation IDs and records unavailable gate opening progress explicitly; it does not replace the ZIP's complete engine state.

**First complete replay:** All 45 source maps pass their expected terminals in `scv-savebench-9idb1r3v/savebench-results.json`: 38 arrivals, three eligibility rejections and four changed-precondition stops. Unchanged-Follower belt controls still assert their known excessive drift; their passing status does not claim corridor safety. The five dynamic cases all expose planning callbacks above the 16.667 ms reference budget: maxima 137.9394 ms (inserted wall), 31.4548 ms (off-route), 31.4784 ms (behind), 188.5763 ms (removed-wall detour) and 41.0832 ms (forward belt edit). The inserted-wall case's four callbacks total 198.4028 ms. These are instrumented Lua hook durations on the actual loaded map, not an attribution to search alone or a full engine/GUI CPU profile. Normal movement hooks have much lower p95; successful arrival does not establish realtime planning performance.

**External solver stepping:** The separate long-wall case creates a real save, starts a fresh server on it and captures the persisted actor/surface. Factorio 2.0.77's native `ticks_to_run` advances the paused simulation by exactly N updates, with RCON still available. A three-tick assertion verifies both game time and actual character displacement. The first integrated run passes 16 checks; it measures 2,996.7 ms capture, 1,093.6 ms solver, an explicit 250.5 ms artificial delay and 6,210.6 ms total frozen wall time, with zero simulation ticks during that wait. Native movement then arrives in 124 travel ticks. The host wall watchdog remains active independently of paused game ticks. `real_time_performance_evidence=false` prevents this correctness test from masking latency. Artifacts: local temp `factorio-scv-live-v4daa8n4`.

**Evidence freshness:** Independent review found that the saved gate probe retained validator assertions and calibration traces from authoring; the belt probe could retain old model provenance. Recompiling only the action or field was insufficient. Shared `Probe.arm` operations now rebuild assertions, timelines, metrics and algorithm state against the existing native objects. Seven added assertions deliberately change the current validator answer or calibration/model identity and prove that stored passing verdicts cannot become evidence about the new implementation. Source geometry and task constraints remain unchanged.

**Other failed assumptions:** A valid-save check initially required a literal `level.dat`, but Factorio 2.0.77 uses numbered level shards plus metadata. Assuming exactly two shards also failed in a later full-suite run: the game finished saving a valid 500,538-byte ZIP containing only `level.dat0`. The host mislabeled this as a publication timeout. The correct check accepts contiguous shard numbers starting at zero and validates CRC, then proves loadability by restarting the engine. The failed artifact remains in local temp `factorio-scv-live-rtbzh_ae`; extending the timeout would not fix the parser. Its exact original ZIP and original mod copies subsequently pass all 16 native stepped checks, with an unchanged ZIP hash, in `scv-single-shard-recheck-a1vm622t`. LuaProfiler cannot be read as a numeric Lua value or serialized into synchronized storage. Its localized strings are written on the server and parsed by the host; nested mutation callback time is included in `on_tick` and must not be added twice.

**Decision:** Keep source-save replay and stepped external correctness in the default headless suite alongside the original realtime test. Preserve source artifacts and evaluate changed algorithms against them. Report functional and realtime performance outcomes separately; the measured synchronous callback cost now provides a concrete optimization target. Do not promote the gate/belt experiments into the production profile or claim map-compiler equivalence from hash binding alone. The [saved-map guide](save-backed-testbench.md) defines the boundary, while [project progress](project-progress.md) records final integrated validation.

## 2026-09-15 - Conditional gate actions, remaining-corridor response and belt compensation

**Question:** Can the calibrated domain facts now drive native execution, with shared planner/follower code where applicable, without introducing another route-specific heuristic?

**Boundary:** Branch `codex/domain-execution-wave`, based on calibration/topology commit `765dad0`; Factorio 2.0.77, fixed base + SCV + TestKit and seeded headless hosts. The three lanes add isolated modules under `scripts/navigation/gates`, `execution`, and `motion`. The default production profile and ordinary-save GUI wiring remain unchanged. Gate and belt fixtures author their test segments; only the dynamic wrapper invokes the full shared PlanningRun. A passing action/controller test does not imply solver admission or production deployment. The [concrete domain design](navigation-domain-execution-plan.md) states promotion requirements.

**Gate action:** Ten real-gate cases cover normal/5x straight native Follower crossing, a fast near-side approach, hostile/configured-wall/connected-chain rejection, and force/control/rotation/removal changes during approach. The actor-body-expanded gate bounds determine contact/clear planes; opening lead uses measured 16-tick latency, current speed and one native movement step. A near-fast actor waits 14 ticks, matching the stated delay prediction, then arrives without slowed/contact command ticks. The far-fast case waits zero ticks; all three crossing cases have zero follower replans. Four changed-precondition cases return replan on the mutation tick and observe zero native movement the following tick. Opening calibration is version/prototype-scoped input, not a universal gate constant.

**Gate pitfalls:** Factorio 2.0.77 `gate.neighbours` includes the gate itself on perpendicular directions; an initial chain check rejected every ordinary gate until self references were excluded. More importantly, `PathSmoothing` tests the prototype collision mask and rejects even a fully opened gate. The test asserts that existing limitation rather than bypassing admission. This slice supplies conditional semantics and action execution; shared semantic collision queries, capture, gate-versus-detour scoring and production-profile tests remain in #9. Circuit behavior and distinct allied forces are not guessed from same-force automatic-gate measurements.

**Dynamic execution:** A wrapper reuses the current PlanningRun/Follower adapter and an actor-agnostic remaining-polyline policy. Real normalized build/destroy events carry bounded world changes; segment intersection includes actor and trajectory clearance. In the inserted-wall episode, seven walls are requested at `x=0,y=-3..3` (native centers `x=0.5,y=-2.5..3.5`) after four tiles of actor progress from `(-12,0)` toward `(12,0)`. The blocking event stops walking that tick; shared replan starts one tick later, 8.506894 tiles from the nearest wall center. The replacement route arrives with one replan and no stuck recovery. Off-route and behind-actor construction do not trigger replans. A native removal case retains its still-valid detour; a forward-belt insertion emits motion-only revisions and arrives without claiming generic drift-safe response. Policy tests separately cover inflation, diagonal footprints, traversed prefixes, exact dirty members, overflow and bounded resumed work. Transient notification is not local avoidance.

**Dynamic failed hypotheses:** The first new fixture accidentally created destructible walls. The engine proposed destruction-through-wall paths and shared validators rejected every candidate. Matching the established indestructible fixture policy corrected the scenario; no planner acceptance rule was relaxed. Regional world dependencies also need explicit route-contract schema stamping. Coalescing disconnected dirty boxes by their union alone can invent an obstacle across the route; retain exact member boxes for narrow-phase intersection. A follow-up check found a removal-only notification queue could cause a one-tick safety hold despite zero replans/immediate stops; distinguish pending blocking work from notification work. Independent review also found repeated duplicate events could reset a partially completed scan forever, starving an actor held for safety. Unchanged geometry must not restart that scan. Immediate stop counters cannot rely on reading a just-written walking state in the same event. Callback work is bounded per event, not across every event in an arbitrary construction burst; external committed-generation admission and a total frame budget remain future work.

**Belt execution:** Thirty native arrivals plus three pure model cases use measured eight-direction vectors plus belt drift. A zero-lateral slice of the attainable velocity convex hull determines positive forward feasibility and directed `length/speed` cost. The controller keeps its native primitive while the next displacement fits an explicit +/-0.25-tile centerline band, then switches based on actual error. This band is an execution constraint, not a belt-attraction bonus. In eight-tile crossings of uniform cardinal fields, all four belt orientations agree:

| Tier | Existing Follower: ticks / maximum drift | Compensation: ticks / maximum drift | Compensation direction switches |
| --- | --- | --- | ---: |
| Yellow | 66 / 1.6875 tiles | 58 / 0.25 tile | 6 |
| Red | 90 / 3.375 tiles | 63 / 0.25 tile | 7 |
| Blue | 142 / 5.0625 tiles | 70 / 0.24609375 tile | 3 |

All native displacement vectors have zero residual against the measured model. Full-segment time predictions have an analytic arrival/cross-track error bound, not a fitted percentage. Blue with/against travel arrives in 32/141 ticks respectively. The synthetic two-route comparison costs an eight-tile ground route at 53.894737 ticks and a twelve-tile favorable belt detour at 49.548387 ticks; it is explicitly a model check, not cost-aware search or native detour execution.

**Belt failed hypothesis and limits:** The first telemetry recorder read the prior applied `walking_state` after setting a new command, creating false model residuals. Correlating the following displacement with `Follower`'s reported selected direction fixes the recorder; motion constants and acceptance bounds are unchanged. There are no neighboring corridor walls in this experiment: centerline retention is not swept-body collision validation. Entry/exit, turns/splitters, immunity/equipment, dynamic fields and stationary holding remain untested. Clearing walking state does not cancel passive belt motion, so combining gates/dynamic stops with belts needs its own holding/retreat action before promotion.

**Repeated integrated domain evidence:** `scv-calibration-dl3fhajz/calibration-summary.json` in local temp retains both exact runs: gates 10 cases/68 assertions, dynamic 18/89, belts 33/188. Total 61 cases/345 assertions per repetition; 38 cases are native arrivals, seven are intentional rejection/invalidation terminals, and sixteen are pure model/policy checks. Full case records agree, including normalized timelines and measured values.

**Decision:** Add these execution experiments to the default headless suite and preserve all historical controls, including the original inserted-wall expected failure. Keep #9, #11 and #2 open for their complete admission/production/dynamic-domain contracts. Next integration work is semantic gate geometry, time-objective search with motion boundaries, and combined episodes that prove safe waiting/replanning on belts. The [detailed dynamic experiment](experiments/dynamic-corridor-2026-09-15.md) records exact callbacks and regressions. Exact integrated validation and review links are maintained in [project progress](project-progress.md).

## 2026-09-15 - Parallel native-domain calibration and source-polygon replay

**Question:** With bulk transport no longer the primary blocker, can independent domain and topology work use the same headless/acceptance foundation without changing production behavior?

**Frozen scopes:** Framework base `a770ae4`, Factorio 2.0.77. Gate fixture-v1 uses a real gate at `(0.5,0.5)`, adjacent walls, eastbound unassociated native characters from `(-12.5,0.5)` to `x>=12.5`, same-force/enemy, speed modifiers 0/4, and passive/explicit request. Belt fixture-v1 uses grass-1 and eight ground controls plus 48 uniform-field cases: three tiers, four cardinal directions, four relative commands, six-tile command progress. Calibration uses fixed map seed 424242, gate surface seed 82451, and base + SCV + TestKit only (DLC disabled). Each domain runs twice and compares complete assertions, metrics and normalized timelines. These are physical probes, not copied planners or follower algorithms.

**Gate findings:** Six cases / 46 assertions pass in each seeded run. Normal passive/explicit approaches clear the gate collision extent at tick 91 and reach the far endpoint at 169 without contact. At 5x speed, passive opening completes at 21, collision clearance at 23 and endpoint at 38, with five slowed / three stationary commanded ticks. Proactive opening completes at 16, clearance at 18 and endpoint at 34, without slowed/contact ticks. The tested 13-tile request lead is sufficient, not a proven minimal-distance rule. Enemy cases require real contact, a distant friendly positive-control open/close cycle, and crossing after removing only the enemy gate; this proves a local blocker, not global no-path. Final specialist evidence: local temp `scv-calibration-ouz_z507`.

**Gate failed hypotheses:** Incompatible `request_to_open` throws a Lua error rather than silently rejecting. The probe now catches/asserts the specific force error. Unseeded processes had several ticks of passive timing variance; exact comparison correctly rejected them instead of dropping timing fields. `extra_time=120` did not guarantee a 120-tick minimum hold during approach: the fast explicit gate began closing at tick 24 and was closed at 39. Automatic interaction replacing the timer is only a hypothesis, not a measured internal cause. Circuit control, allied-but-distinct forces and GUI-player equivalence remain open in #8; #9 is not implemented by this probe.

**Belt findings:** All 56 cases pass twice with identical per-tick records. Measured ground cardinal speed is `0.1484375` tiles/tick despite the `0.15` runtime speed property. In these uniform fields, measured ground displacement plus the belt vector predicts all 48 means with zero residual. Representative eastward fields:

| Case | Measured displacement/tick `(x,y)` | Ticks to six-tile command progress | Cross-track drift |
| --- | --- | ---: | ---: |
| Ground east | `(0.1484375,0)` | 41 | 0 |
| Yellow east, with | `(0.1796875,0)` | 34 | 0 |
| Yellow east, against | `(-0.1171875,0)` | 52 | 0 |
| Express east, with | `(0.2421875,0)` | 25 | 0 |
| Express east, against | `(-0.0546875,0)` | 110 | 0 |
| Express east, command south | `(0.09375,0.1484375)` | 41 | 3.84375 tiles |

The lateral displacement is not automatically compensated: raw commands are the control. This does not validate the existing follower on belts or a faster-route planner. No immunity equipment, field boundaries, turning belts, dynamic changes or cost-aware search is covered yet. Record `factorio-native-uniform-belts-v1` as bounded calibration input, not a universal motion law. Evidence: local temp `scv-calibration-h8aw941u`.

**Third-party topology:** Pinned extremitypathfinder 2.7.2 with Shapely 2.1.2 / GEOS 3.13.1, NumPy 1.26.4, NetworkX 3.5, isolated Python 3.12.14. Source wall rectangles and tile facts build configuration-space polygons; the exported trajectory margin is retained, with a separately declared 1/256-tile contact guard. No occupied grid cells or extra half-cell-diagonal inflation build the new topology. This is restricted static stone-wall geometry, not Recast, live belts/gates or a dynamic mesh.

All 11 fixture-v4 cases remain: ten complete and one disconnected-domain no-path. The ten library routes agree with the existing Dijkstra on that library's exported query graph. `tight-clearance-corridor` is **20.066104 tiles** versus the captured-grid control's **23.219122**; `long-wall-return` is 25.553298 vs 28.253505; `captured-slalom-return` is 35.103094 vs 38.358487. These compare different representations explicitly; they are not evidence that changing language improves an identical graph. For tight, geometry/build/search/warm-search measured 1.918/2.346/0.765/0.757 ms; total comparison work including source checks and controls is 223.252 ms, not a game command-latency measurement.

The integration owner admits the new backend for **offline imported routes only**, with shared-validator and live-backend-rejection assertions. The full generated bundle then passed **33 native interchange assertions**, including arrival for all ten complete paths; no collision/follower acceptance code was bypassed. First integration replay artifact: local temp `factorio-scv-agent-test-653b6705533e42c495585468d9f3ad4b`, isolated project `scv-topology-replay-dc4154ea44c3490b8ecdef2f956022af`. The backend-only comparison intentionally says `replay_status=not-run`; the separate correlated Factorio report supplies execution evidence.

**Operational pitfalls:** The first calibration launcher omitted the required server `description` and failed before scenario startup; fixed without launching GUI. Python 3.14 could not satisfy the library's NumPy <2 wheel constraint, so the specialist used a separate pinned 3.12 environment rather than overriding dependencies. Third-party dependency installation is optional, never a production-mod or default-test prerequisite.

**Decision:** Promote the first calibration slices and replay experiment for review, not the algorithms into `production-v1`. Continue #8/#10 matrices before #9/#2 policy, and retain #11's known inserted-wall failure until real proactive invalidation passes. #17 still needs update/memory/larger-domain/capability work; #16 warm caching and GUI lifecycle remain independent. Full-wave validation and branch-level delivery are recorded in [project progress](project-progress.md).

## 2026-09-15 - Move bulk snapshots out of the synchronized command channel

**Question:** Is the 18-second local snapshot transfer inherent to external solving, and can a supported transport replace the serial RCON downloads?

**Available interfaces:** Installed Factorio 2.0.77 documentation confirms sandboxed Lua removes `io`, `os`, `loadfile` and arbitrary external module loading; there is no supported mod shared-memory mapping API. `helpers.write_file` writes to the controlled script-output directory and supports server-only output. Localhost `send_udp`/`recv_udp` also exist with `--enable-lua-udp`, but receive documentation specifies a 256 KiB buffer, possible loss while paused/saving, and multiplayer input-action distribution. Sources: [libraries](https://lua-api.factorio.com/latest/auxiliary/libraries.html), [LuaHelpers](https://lua-api.factorio.com/latest/classes/LuaHelpers.html), cross-checked against the installed `doc-html` at 2.0.77. UDP was reviewed, not runtime-benchmarked in this experiment.

**Change:** Default to a server-only, single-slot bulk file for the exact snapshot/query bytes. Publish the bounded file descriptor after `write_file` completes; the host checks the fixed confined path, exact byte count, session/request, query hash and snapshot content hash. RCON carries small control/result messages and retains the authoritative shared PlanningRun commit. No native injection, external Lua file reading, dropped metadata, grid coarsening or relaxed collision check was introduced. Legacy RCON snapshot download is an explicit comparison mode, not the default.

**Same-input measurement:** `python tools/navigation/live.py --test --compare-transports`, Factorio 2.0.77, fixture-v4 `open-diagonal`, **3,382,790 identical bytes**:

| Channel/stage | Measured wall time | Bulk RCON commands |
| --- | ---: | ---: |
| Legacy chunked download + JSON decode | 18,845 ms | 1,128 |
| Bulk file read only | 2.107 ms | 0 |
| Bulk file read + JSON decode + query/source identity checks | 359.321 ms | 0 |

Both channels produce exactly equal problem values and native movement still arrives in 133 movement ticks with the same 0.311326-tile error. All eight A/B/live assertions passed, including ordinary lifecycle checks. Artifact: local temp `factorio-scv-live-s5pbrpww`.

**Do not hide remaining latency:** Game-side capture/build/encoding/publication took 4,590.881 ms; solver call including input validation/setup took 1,450.133 ms; result upload plus Lua admission took 1,461.038 ms. Game-side file-write time belongs to capture-to-ready, not the 2.107 ms host read. The final default-mode probe measured **9,974.417 ms from begin to admission**, with no A/B delay: capture-to-ready 4,671.666 ms, read/decode/identity 365.652 ms, solver including input validation/setup 1,455.317 ms, separate host result validation 725.654 ms, upload/admission 1,523.096 ms. The remaining approximately 1,233 ms includes diagnostic artifact serialization/writing and harness work; this probe is not a warmed GUI latency measurement. The report flags whether the deliberately slow A/B comparison is included. A fast bulk transfer does not make this cold-per-command prototype low-latency.

**Regression coverage:** Missing/truncated/oversized files, unexpected paths, changed query/geometry, stale session/request, malformed/duplicate-key/nonfinite JSON all reject. A host test forbids any RCON data call in file mode. Engine conformance checks default transport selection and requires a new synchronized session to change transports. Final `pwsh -NoProfile -File .\tools\test.ps1 -Suite all -KeepArtifacts` passed: smoke, 107 integration assertions, the unchanged static benchmark and three episode baselines, 11 interchange assertions, 36 Python tests, and seven default-file live assertions. Explicit legacy `--snapshot-transport rcon` also passed all six lifecycle assertions. Everything ran headless; slow A/B is opt-in. Final artifacts: local temp `factorio-scv-agent-test-a6b5df8ae9e74a108f27e24473a9d67f` and `factorio-scv-live-rhl7bp5i`; legacy probe `factorio-scv-live-5we_qkgz`.

**Decision:** Separate control traffic from bulk data now. Continue #16 with committed world reuse, incremental changes and staged capture; those address the remaining seconds of capture/admission. Do not treat compression, shared-memory terminology, or a transport swap as a substitute for that cache lifecycle. Leave a reliable explicit baseline for measuring each subsequent change.

## 2026-09-15 - External solver boundary reaches native execution; transport remains expensive

**Question:** Can an external solver consume the same exact captured problem, return through production validation, and finish real character movement without launching a GUI?

**Scope:** Factorio 2.0.77, fixture version 4, `scv-navigation/1`, `factorio-captured-grid-v1` at 0.5 tiles, Python standard-library Dijkstra/A*. These are reference graph implementations, not a Recast/Detour experiment. Production stays `production-v1`. Actual gates/belts/moving actors are explicitly unsupported by static capture; the historical `gate-open`/`gate-closed` fixtures remain wall-gap geometry.

**Measured results:** Both external algorithms solved the identical 11-case capture with 10 `complete` and one graph-scoped `no-path`. All ten complete results passed the shared collision/trajectory validators and arrived under the native Follower in separate Factorio replays. Every per-case distance matched within `1e-8` tiles. Representative raw graph paths:

| Fixture | Distance (tiles) | Dijkstra expansions | A* expansions |
| --- | ---: | ---: | ---: |
| `open-diagonal` | 27.784888 | 3,733 | 2 |
| `long-wall-return` | 28.253505 | 1,659 | 429 |
| `tight-clearance-corridor` | 23.219122 | 236 | 195 |
| `captured-slalom-return` | 38.358487 | 1,702 | 1,134 |
| `unreachable-box` | no-path | 2,369 | 2,369 |

The raw imported paths are intentionally not geometrically smoothed. `tight` still takes the conservative-grid detour: 23.2191 is worse than the historical production inflated-engine result around 20.17. The Python language boundary does not recover clearance erased by the graph representation. Original source geometry is retained for a genuinely different topology backend.

The loopback headless/RCON probe admitted one result, rejected duplicate/cancelled/prior-session replies, and moved `open-diagonal` to arrival in **133 movement ticks**, error **0.311326 tiles**, actual travel **29.463282 tiles**. Its existing speed-dependent follower bound is **0.3375 tiles**; the solver endpoint eligibility radius remains **0.25 tiles**. These are separate contracts. The first host assertion incorrectly conflated them; capture now pins both before search, and replay rejects any imported execution bound that differs from `Follower.tolerance(actor)`. Neither controller tuning nor endpoint assertion was adjusted to the observed error.

The live fixture snapshot needed **1,128 RCON chunks** at 3,000 payload bytes each. Transfer took **18.225 seconds**, while the measured solver call (including graph validation/hash/setup) took **1.452 seconds**. This establishes a functional live loop, not low-latency RTS interaction. Capture remains synchronous. Cached committed generations, bounded capture work and avoiding repeated whole-world transfer are the next priorities, not another search heuristic.

**Failed hypotheses retained:**

- A 200k-value canonical limit rejected four real fixture graphs; export preserved all failures instead of silently dropping cases. The bounded canonical limit is now one million values/8 MiB per value, while multi-case JSON has a separate limit.
- Publishing fixture metadata through a second generation, encoding the full bundle twice and retaining every graph caused an `on_init` watchdog failure at 180 seconds. Single publication, per-fixture encode/check and bounded retained working data reduced a diagnostic run to 46.4 seconds. The default 90-second per-suite watchdog was not enlarged; success still requires semantic completion.
- Factorio's JSON writer and patched `string.format("%.17g")` can round `0.15 * 1.5` from `0.22499999999999998` to `0.225`. Even `%.0f` rounded a large canonical mantissa. Local Lua tests alone missed the engine-specific formatting behavior. Integer-digit canonical encoding and exact decimal expansion now preserve the binary64 value, with fixed Python vectors and actual Factorio round-trip tests. Old broken captures must be re-exported.
- A Lua-local `needs handshake` flag reset by `on_load` would let a newly joining client cancel a request the host still executes. Session state is now synchronized storage; only the host command rotates it. The headless contract test exercises load-hook invariance. A real second-client/desync test remains unrun.

**Reproduction:** `pwsh -NoProfile -File .\tools\test.ps1 -Suite all` includes smoke, 104 integration assertions, the existing static benchmark, three production-equivalent episodes, capture/replay conformance, 29 Python tests, and six live headless assertions. `tools/navigation/eval.ps1 -KeepArtifacts` separately captures once and imports both solver bundles through isolated Factorio replays. The dynamic `wall-inserted-ahead` episode still expects the known `failed/no-safe-candidate` outcome; passing that baseline is not dynamic recovery.

The first full comparison artifacts are under local `scv-navigation-eval-861abda7e5414edd947603809de2ff66`; the final explicit-execution-contract rerun also passes at `scv-navigation-eval-1c60eea8eb574482be790771e5c5dd97` (33 replay assertions per algorithm). The measured live transport run is `factorio-scv-live-sv1b9q07`; final `all` artifacts are `factorio-scv-agent-test-665c098a4e07404a97d3da1780c5159c` plus `factorio-scv-live-jnt2lm91`. All are under the runner's printed temporary directory. Generated manifests include source/query identity and full replay paths; these machine-specific locations are diagnostic evidence, not checked-in inputs.

**Decision and follow-up:** Keep the implemented boundary and native execution loop, preserve production behavior, and prioritize [live caching/GUI lifecycle #16](https://github.com/guajun/factorio-scv-control/issues/16). Compare a real source-geometry topology backend in [#17](https://github.com/guajun/factorio-scv-control/issues/17). GUI launch remains manual with an isolated matching-mod profile. No ordinary save, existing GUI mod junction, or graphical process was changed by these tests. Real domains remain the existing gate/belt/invalidation issues.

## 2026-09-15 - Industry research exposes objective and backend boundaries

**Question:** Can external game-navigation libraries fit the composable pipeline, and is a serialized polyline plus final cost scoring a sufficient contract?

**Evidence scope:** Source/documentation review against main `852349a`, using the primary references in [game navigation research](navigation-industry-research.md). This entry records a design investigation, not a new runtime experiment. No solver timings, transport probe, or improved arrival results were measured.

**Finding:** The merged pipeline shares request order, validation, and follower behavior, but providers receive no explicit committed NavigationData/query-objective contract. Cost runs after candidate generation; `PlanningRun` currently writes the scalar score into `predicted.distance`. The local search domain is justified for distance improvement, and geometric smoothing has no directed-time preservation contract.

**Rejected assumption:** Replacing the final scorer with travel time, or wrapping an external `findPath`, is sufficient to discover a longer favorable belt route. The distance ellipse can exclude that route; an incompatible search heuristic can distort the objective; smoothing can remove the useful belt section. Exporting only the already-inflated grid would additionally preserve the known narrow-channel loss in every external solver.

**Decision:** Separate observed world facts, committed derived navigation data, and query policy. Pass filter/directed objective into search, retain objective units and transition metadata, and validate the final executable geometry in Factorio. Keep the current production profile as a comparison baseline. Use offline capture/replay before adding live transport; design explicit partial/budget/stale/cancel outcomes rather than treating every missing answer as no-path.

**Next evidence:** [Planned comparisons](navigation-industry-research.md#experiments-and-decision-gates) cover fixture-v4 tight clearance, a longer-faster directed route against a same-graph Dijkstra reference, objective-preserving smoothing, committed world updates, the known inserted-wall failure, and external lifecycle faults. Exact new fixture definitions and acceptance bounds must land before collecting their measurements. [Boundary packages A-E](navigation-solver-boundary.md#evaluation-and-implementation-packages) define dependencies and ownership; real gate and belt calibration remain independently actionable.

## 2026-09-01 - Late wall replanning cannot recover a safe production route

**Question:** Does the current stuck-triggered replan recover after a wall is inserted ahead of a moving character when the episode uses the shared `production-v1` `PlanningRun`?

**Fixture version:** NavigationEpisode fixture version 1, `wall-inserted-ahead`, start `(-12, 0)`, goal `(12, 0)`, and a wall from `(0, -8)` through `(0, 8)` on Factorio 2.0.77.

**Measured result:** The initial run selected the 24-tile `engine-normal` route and predicted 107 travel ticks. The wall action fired 20 episode ticks after planning began. The character reached `(0.0078125, 0)`, detected stuck, and began its first replan 71 ticks after the action at an obstacle distance of `0.0078125`. On that production-equivalent replan, `engine-normal` returned a route that passed actor collision but failed trajectory-envelope validation; `engine-inflated` and `grid-a-star` both returned no-path. The selector terminated with `failed/no-safe-candidate`. Two isolated runs produced the same action, assertion, provider, and terminal ordering.

**Falsified assumption:** The temporary single-engine episode adapter appeared to recover and arrive, but it bypassed the production candidate validation contract and accepted a route from a start already pressed against the new wall. That result was not production-equivalent evidence of dynamic-world recovery.

**Decision:** Phase 1 records `failed/no-safe-candidate` as the semantic baseline and preserves its route, action, position, provider traces, and 71-tick replan latency. Corridor invalidation work in issue #11 must trigger replanning before contact; the episode runner must not add an eval-only proactive replan policy to manufacture an arrival.

## 2026-08-31 - Shared PlanningRun makes benchmark order production-equivalent

**Question:** Can production and the static benchmark share candidate algorithms without also sharing the asynchronous request state machine?

**Fixture version:** 4, eleven fixtures and ten reported algorithms on Factorio 2.0.77.

**Measured result:** The shared `production-v1` run issued `engine-normal`, then `engine-inflated`, then synchronous `grid-a-star` for every reachable fixture. The unreachable fixture terminated after `engine-normal` reported no-path; the standalone inflated-engine benchmark then ran through its isolated legacy adapter. `production-local` solved 10/10 reachable fixtures with zero trajectory-clearance violations, 21 production engine requests, 8,310 expanded local nodes, and 33,733 in-memory line checks. Representative selected distances remained `20.17` for `tight-clearance-corridor`, `26.81` for `long-wall-return`, and `36.68` for `captured-slalom-return`.

**Falsified assumption:** Sharing only `LocalPlanner.compare` does not make an evaluation production-equivalent. The previous benchmark requested the inflated path first, duplicated busy/no-path control flow, and could perturb Factorio's scheduling-sensitive normal result.

**Decision:** `PlanningRun` owns provider order, request correlation, terminal states, post-processing, validation, scoring, selection, and deterministic traces. Production, engine-backed integration, `production-local`, and live preview use that run. Historical alternate, standalone engine, and experimental grid algorithms remain benchmark-only adapters and cannot alter the production provider sequence.

## 2026-08-31 - Tight corridor needs the inflated-engine candidate in production

**Question:** Why did live plans near the `tight` marker increasingly route around the wall columns even though the corridor was physically traversable?

**Fixture version:** 4 captures the logged non-grid-aligned command at local start `(9.9296875, -9.87890625)` and goal `(9.9296875, 9.8671875)`.

**Measured result:**

```text
normal engine             19.97  trajectory-unsafe
inflated engine           20.17  trajectory-safe, through corridor
conservative grid A*      22.14  trajectory-safe, outside detour
new production-local      20.17  selected engine-inflated
```

The normal engine centerline was shortest but violated the follower's complete trajectory envelope. The conservative 0.5-tile snapshot correctly remained safe, but its cell inflation erased the usable channel and forced the outside route. Factorio could still plan through the channel when its request bounding box was expanded by the exact trajectory margin.

**Falsified assumption:** Normal engine plus conservative local A* did not span the useful safety/quality frontier. Validating the normal route can reject a corridor that an inflated engine request can represent more precisely than the sampled grid.

**Decision:** Production now requests normal and inflated engine paths sequentially, then compares both with conservative local A*. It selects the shortest trajectory-safe candidate with no detour-ratio trigger. The extra request is an explicit latency/work tradeoff and is recorded by the benchmark. The fixture now asserts that production retains the safe narrow channel rather than silently accepting the grid detour.

## 2026-08-31 - Same-version reload does not run configuration migration

The first strict-zone migration only rebuilt the test lab from `on_configuration_changed`. `game.reload_mods()` loaded the new control checksums but did not raise that migration path because both development mods still reported version `0.1.0`; the visible map therefore remained unchanged.

**Decision:** The interactive TestKit checks its fixture schema version on the first tick and rebuilds when stale. `/scv-test-reset` remains the explicit immediate rebuild command. Do not assume source checksum reload is equivalent to a Mod version configuration change.

## 2026-08-31 - Production removes alternate via and uses safe local comparison

Production now makes one Factorio baseline request, validates the complete smoothed path against the trajectory envelope, and compares it with conservative local A* inside the baseline-length ellipse. It chooses the shorter safe result; there is no detour-ratio gate, lateral fraction, or forced intermediate point.

**Fixture version:** 3, eleven fixtures, ten planner variants.

**Production-local results:**

- Reachable fixtures solved: 10/10.
- Trajectory clearance misses: 0.
- Mean distance / best trajectory-safe distance: 1.001.
- Maximum distance / best trajectory-safe distance: 1.007.
- `long-wall-return`: 26.81 instead of engine 49.53.
- `captured-slalom-return`: 36.68 instead of engine 39.05.
- `tight-clearance-corridor`: preserves the safe engine route at 20.29 instead of conservative-grid detour 22.34.

**Cost risk:** Local snapshot capture and A* currently run synchronously after the engine result. The benchmark reports 8,342 expanded nodes and 33,932 in-memory line checks across the fixture set, but wall-clock/UI latency still needs interactive profiling before this is considered production-ready for long commands.

**Decision:** Remove alternate state from production and retain it only as a legacy benchmark family. Next optimize navigation snapshot caching/invalidation rather than reintroducing trigger heuristics.

## 2026-08-31 - Baseline-mirror bounds were another hidden heuristic

**Question:** Can production local A* search only a bounding box containing the engine path and its reflection across the start-goal line?

**Failure:** On `long-wall-return`, the first production-local implementation selected a 51.74-tile safe path, worse than the 49.53 engine path and far worse than the 26.81 conservative grid result using fixture bounds. The reflected polyline did not define the complete opposite homotopy region.

**Falsified assumption:** Moving the mirror operation from via placement to search-window construction does not remove the heuristic; it merely hides it in a different layer.

**Replacement:** Any point on a path shorter than a known baseline of length `L` lies inside the ellipse whose foci are start/goal and whose major axis is `L`. Production now searches the axis-aligned bounds of that ellipse, plus derived clearance padding and an adaptive node budget.

**Result:** `long-wall-return` production-local changed from 51.74 to 26.81. Across ten reachable fixtures it has zero clearance misses, mean safe ratio 1.001, and maximum safe ratio 1.007.

**Decision:** Search bounds must follow a geometric guarantee or explicit resource budget, never a guessed obstacle side.

## 2026-08-31 - Tight-clearance fixture exposes conservative-grid detours

Two wall columns form a narrow corridor that the trajectory envelope can traverse. Results:

```text
engine / inflated engine     20.29
conservative grid A*         22.34
conservative Theta*          22.74
production-local             20.29
```

The half-cell-diagonal inflation did not return no-path, but it rejected the direct narrow channel and routed around the wall columns.

**Falsified assumption:** A conservative sampled grid can be both universally safe and geometrically neutral at clearance boundaries.

**Decision:** Production compares the fully validated engine path with conservative local A*. If the engine centerline already satisfies the trajectory envelope, it preserves the shorter exact-engine corridor.

## 2026-08-31 - Fixture rendering must be surface-scoped

The first shared fixture builder used `rendering.clear()`. Running a benchmark surface could erase strict-zone labels and live overlays on the main test surface.

**Decision:** Fixture cleanup destroys only render objects whose `surface` matches the fixture surface. Test utilities must not mutate unrelated surfaces or ordinary saves.

## 2026-08-31 - Conservative snapshot inflation makes fast grid paths safe

**Question:** Can a cached 0.5-tile collision snapshot provide trajectory-safe paths without running tens of thousands of Factorio geometry queries?

**Change:** Inflate every sampled blocked position by the trajectory envelope plus half the grid-cell diagonal. The half-diagonal term is derived from grid resolution and covers the space between a node center and any point in its cell.

**Fixture set:** Version 2, ten fixtures, Factorio 2.0.77.

**Results:**

| Algorithm | Mean / actor-best | Clearance misses | Expanded | Factorio line checks |
| --- | ---: | ---: | ---: | ---: |
| `grid-a-star` | 1.034 | 0 | 10287 | 0 |
| `grid-weighted-a-star-2` | 1.037 | 0 | 7456 | 0 |
| `grid-theta-star` | 1.042 | 0 | 9004 | 0 |
| `grid-theta-star-exact` | 1.042 | 0 | 9004 | 46306 |
| `safe-hybrid` | 1.034 | 0 | 6653 | 0 |

The original narrow corridor remains reachable at 30.00 tiles. The later tight-clearance fixture shows the conservative grid may choose a longer outside route even when an exact safe corridor exists.

**Falsified assumption:** Exact any-angle visibility checks are not automatically worth their cost. Once the snapshot is conservatively inflated, Exact Theta produced no safety improvement on this fixture set and did not improve path length enough to justify 46k surface queries.

**Tradeoff:** Conservative inflation removes corner leakage but costs roughly 3%-4% against the shortest actor-safe result, which is often an unsafe legacy route. Reports must therefore show both actor-safe and trajectory-safe baselines.

**Decision:** Continue toward cached inflated navigation regions plus a small number of final exact checks. Compare against a fully validated engine path before replacing it. Do not use Exact Theta throughout every search expansion.

## 2026-08-31 - Inflating the engine subject solves safety, not topology

**Question:** Is passing an expanded character bounding box to Factorio sufficient to replace alternate vias?

**Change:** Add `engine-inflated`, using the normal character collision box plus the complete speed-dependent trajectory clearance margin.

**Results:**

- Clearance misses: 6 -> 0.
- Narrow corridor: still reachable, 30.00 tiles.
- `long-wall-return`: 49.53 -> 50.70, while safe local grid search is 26.81.
- `captured-slalom-return`: 39.05 -> 39.06, while safe local grid search is 36.68.

**Falsified assumption:** A correct configuration-space footprint does not repair Factorio's weighted topology choice. It can make the same wrong wall end slightly longer while remaining collision-safe.

**Decision:** Keep inflated engine as a cheap safe baseline/fallback. Do not treat it as the topology planner.

## 2026-08-31 - Forced via creates the visible wall-end cone

**Observation:** Live command 28 selected this production path:

```text
start -> (-45.19,-4.15) -> (-42.5,-5.5) -> (-41.5,-6.5) -> goal
```

The real wall portals are near `(-42.5,-4.5)` and `(-42.5,-6.5)`. The via overshoots the wall end by about 2.7 tiles and creates a 144.5-degree turn. Multiple algorithm overlays converge at the wall end and fan toward different approach points, producing the visible cone.

**Falsified assumption:** Full-path string pulling cannot reliably repair an arbitrary via. It can delete points but cannot move a bad point onto a missing obstacle tangent/portal.

**Decision:** Via placement is a legacy comparison only. The target planner must generate topology/portal information from the collision world model.

## 2026-08-31 - Direct-distance detour ratio misses meaningful portal mistakes

**Fixture:** `captured-slalom-return`.

```text
direct distance             32.49
engine / production         39.05
unconditional global via    35.99
grid A* actor-safe           35.25
```

The engine path is 10.8% longer than the shortest observed result, but `39.05 / 32.49 = 1.202`, so production's `detour_ratio > 2` gate does nothing.

**Falsified assumption:** Direct distance is too weak a lower bound in multi-obstacle scenes to decide whether a path deserves optimization.

**Decision:** Benchmark alternate-global unconditionally. Production remains unchanged until a bounded non-via planner is ready.

## 2026-08-30 - Parallel path requests perturb engine results

Issuing many alternate probes concurrently changed Factorio's returned routes for identical coordinates. Serial evaluation produced stable candidate lengths.

**Decision:** Engine candidate families remain strictly serial. Parallel requests are not used as a cheap k-path API.

## 2026-08-30 - Character directions expose 16 values but 8 motions

Engine-backed calibration showed `walking_state` has eight unique physical movement vectors. Nearest-direction control caused rapid switching and missed corners.

**Decision:** Keep geometric planning separate from the hysteresis-controlled 8-vector trajectory follower. Collision planning must include the follower's cross-track envelope.
