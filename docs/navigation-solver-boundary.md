# Navigation Solver Boundary

Updated 2026-09-15. This document combines the target design with an explicitly scoped implementation checkpoint. It extends the [architecture plan](navigation-architecture-plan.md) and draws on [game navigation research](navigation-industry-research.md). The [Lua extension contract](navigation-extension-contract.md) describes concrete adapter APIs; requirements below the checkpoint remain targets unless included here.

## Implemented subset and limits

- `scripts/navigation/solver_boundary.lua`: `scv-navigation/1` snapshot/query/result checks, identities, objective units, finite bounds, capability checks, outcome preservation, and generation admission.
- `navigation_data.lua`: committed captured-input generations with pin/release and staged, ordered delta commit/abort. This is not a Recast bake/update backend and is not wired into production world invalidation.
- `canonical.lua` and `wire_json.lua`: cross-language exact binary64 value identity and JSON output. The Adler32 checksum is not a security digest. Empty plain Lua arrays/objects have one canonical empty representation.
- `imported-route` and `external-route`: shared PlanningRun admission, collision/trajectory validation, distance scoring, selection, and native follower. External completion tokens cannot satisfy engine requests. Incomplete, budget, timeout and unsupported results cannot become successful arrival.
- TestKit capture/replay exports fixture-v4 source geometry plus a declared conservative grid and exact endpoint connectors. Gates, belts, moving actors and unknown chunks are rejected by this static capture profile, not silently approximated as supported domains.
- Python Dijkstra/A* solve the exported directed graph. Synthetic travel-time queries are supported offline; actual Factorio execution profiles accept distance only. No third-party library or navmesh adapter is implemented yet.
- `/scv-nav-agent` and `tools/navigation/live.py` provide a fixed, chunked JSON RCON protocol for an isolated headless test lab. The current envelope uses `operation`, session nonce, request token and sequential chunk index; it is not a general-purpose RPC implementation of every logical operation below. GUI use is an explicit manual connection to that lab, not an automated client launch.

See [testing](testing.md), the [live host guide](../tools/navigation/LIVE.md), and the newest [experiment log](pathfinding-experiments.md) for commands, actual evidence, and remaining lifecycle/performance limitations. Keep packages C (third-party topology) and E (real domains) open; do not claim they are completed by the reference graph solver.

The boundary allows the same captured problem to be solved by Lua, an external graph library, or a navigation-mesh library, then evaluated in Factorio. Language and transport adapters implement one project contract; this is not an industry-standard protocol.

## Ownership

| Component | Owns |
| --- | --- |
| Factorio world adapter | Observed geometry and semantics, actor state, revisions, command identity, and authoritative movement. |
| NavigationData backend | Derived grid/portal/mesh, configuration and actor-envelope key, committed snapshot identity, update lifecycle. |
| Solver | Search over that committed representation, query filters/objective, budget accounting, explicit coverage and result quality. |
| Lua provider adapter | Value conversion, request/result correlation, delivery into shared `PlanningRun`; no alternate acceptance pipeline. |
| Shared validation and execution | Live clearance, trajectory feasibility, gate conditions, final cost, selection, route actions, and follower. |
| Host eval runner | External processes, artifact validation, transport framing, wall-clock watchdog, replay manifests, and cleanup of only its own processes. |

A solver process cannot authorize its own route execution. External costs and validation flags are reported predictions; shared Factorio checks remain required.

## Values and identity

The initial interchange version will be `scv-navigation/1`, independent of Lua storage schema versions. Values are JSON objects/arrays with finite numbers, booleans, strings, and explicit nulls where permitted. No callbacks, Lua objects, executable expressions, or host file paths appear in domain values. Use strings for IDs and backend polygon references to avoid cross-language integer precision loss.

Coordinates are Factorio world `{x, y}` in tiles, with positive x east and positive y south. Tile `(i, j)` covers `[i, i+1) x [j, j+1)`; its center is `(i+0.5, j+0.5)`. Actor collision boxes use local offsets. Preserve exported sub-tile positions; do not round to grid centers. Adapters declare transformations to a library's axes and precision. Time predictions use simulation ticks, velocity uses tiles/tick, and host timings use milliseconds in separate fields. Requested and projected endpoints are both recorded with explicit projection policy/tolerance.

Every operation carries `protocol`, `message_id`, `session_id`, and operation name. Replies correlate to `message_id`. Planning operations additionally carry `command_id`, `request_id`, and `attempt_id`; duplicate delivery has at most one effect. A session identifies one live load/incarnation, so IDs reused by another save, surface, or process cannot accept an old result.

## WorldSnapshot and NavigationDataRef

Snapshot groups:

| Group | Required semantics |
| --- | --- |
| Identity | World/surface identity, incarnation, captured tick, snapshot ID, canonical content hash, exporter and Factorio/mod versions. |
| Coverage | Exact bounded region and observed/unknown areas. Unknown space is blocked for the first protocol profile. An out-of-bounds target requires expansion or a scoped result, not an invented free cell. |
| Geometry | Supported obstacle/tile shapes and collision categories. Mark unresolved prototype semantics explicitly; a conservative approximation records its method. |
| Actor | Collision box/mask, force relation context, native movement model/version, walking modifiers and belt immunity. |
| Semantics | Stable gate transition IDs with eligibility/state; directed motion descriptors with calibration version. Unsupported semantics cause capability failure for profiles that require them. |
| Revisions | Regional topology/motion revisions and observed transient timestamp. Do not persist live moving actors as static occupancy. |
| Optional derived data | Grid occupancy, portal graph, or other versioned representation with source hash and build config. It supplements observed facts, not silently replaces them. |

Exported entity IDs need only be stable within the session; entities without `unit_number` need exporter-assigned identity. Deletion uses the same identity in a delta. Deterministic export fixes field ordering, entity/region order, numeric encoding, and empty-array representation before calculating hashes.

`NavigationDataRef` contains backend ID/version, build configuration hash, actor-envelope hash, generation ID, source snapshot hash, and committed revision coverage. A result echoes the complete reference. A hash identifies inputs; it does not certify their completeness or collision accuracy.

Delta updates contain `base_generation`, ordered change identity, dirty bounds, upserts/removals, and new revisions. Apply to a staged generation. Acknowledging receipt is distinct from publishing a fully built generation. Queries pin a committed generation; an update may keep the old generation alive or cancel affected queries explicitly. A missing/out-of-order base requests resynchronization. A duplicate delta with identical identity/content is idempotent; conflicting duplicates are errors.

## NavigationQuery and QueryPolicy

The query binds start, goal and tolerance, actor snapshot, `NavigationDataRef`, profile ID/config hash, and budget to one request. The policy contains:

- allowed areas/transitions and required actor capabilities;
- objective ID/version and units (`distance` or `travel_ticks` initially), with serializable parameters;
- directed edge and gate-delay semantics, including the motion calibration version;
- heuristic ID and its lower-bound justification, or `zero` for a Dijkstra reference;
- explicit search coverage, endpoint projection, partial-result policy, and approximation declaration;
- deterministic limits such as expanded nodes and output points, plus a host watchdog recorded separately.

Local callbacks implementing edge costs stay behind an adapter. Across a process boundary, send a supported cost-model ID and its data, or explicit directed graph weights. Unsupported cost semantics return `unsupported`, never an unannounced Euclidean substitute. Negative edge costs are out of scope for this first search contract.

Capabilities are checked for **each provider/backend pair**. A profile-wide union containing a belt or gate capability does not prove that every candidate search supports it. A comparison may deliberately include a geometry-only baseline, but must label its search objective separately from the common final scoring objective and cannot claim it solves the time-optimal query.

Post-processors must preserve mandatory transitions and dependency coverage. They recompute cost under the same model on final geometry. A solver supporting directed edge cost does not automatically supply a cost-aware funnel or a controller capable of staying on a belt.

## Operations and completion

Logical operations are transport-independent. An offline run may implement only capabilities, load, solve, and close; live and delta capabilities are separately negotiated.

| Operation | Input / completion |
| --- | --- |
| `capabilities` | Return protocol versions, geometry/objective/transition support, update mode, endpoint/partial policies, determinism declaration, and size limits. |
| `load_world` | Snapshot and build config; finish with a committed `NavigationDataRef` or error. |
| `update_world` | Base generation and delta; finish with the new committed reference or explicit resync/error. |
| `solve` | Query on a committed reference; finish with one `SolverResult`. Progress is optional and never success. |
| `cancel` | Target request/attempt; delivery may race completion, but only the active request can be admitted. Acknowledgement does not resurrect an obsolete result. |
| `close_world` | Release one session's backend state and cancel pending work; later handles are invalid. |

Transport adapters may enqueue and poll these operations. `PlanningRun` must not block a Factorio event waiting for a process. Its future completion envelope must distinguish engine event IDs from external request IDs and deliver both through the same provider completion/state transition path. Existing engine-specific async handling is not yet this generic scheduler.

## SolverResult and admission

Results contain request identity, echoed query/input hashes, committed data reference, solver build/config, outcome, coverage/quality, route payload when applicable, and work metrics.

| Outcome | Meaning and admission |
| --- | --- |
| `complete` | Reached the requested goal within declared tolerance; eligible for validation, not an optimality claim. |
| `partial` | Endpoint short of the requested goal, approximate goal, or truncated route. The first production adapter rejects it as a full candidate; evaluation retains its payload and reason. |
| `no-path` | Search exhausted the declared graph/domain for the declared actor/policy without a route. Include graph/domain scope and approximation limits; it does not prove global physical unreachability. |
| `budget-exhausted` | Work or memory/output budget prevented completion. May carry a separately labelled partial path; never translate to `no-path`. |
| `cancelled` | Request was cancelled or superseded. No route admission. |
| `stale-world` | Requested generation unavailable or result no longer admissible. Replan/resynchronize according to profile. |
| `unsupported` / `invalid-query` / `error` | Capability, input, or implementation failure with stable reason. Preserve the distinction in eval. |

An engine or library result with unknown exhaustiveness is retained as a source-reported failure with coverage `unknown`, not promoted to a proof. Detour detail flags such as partial result, exhausted nodes, and output truncation must be decoded even when its high-level flag says success; see [Detour status definitions](https://github.com/recastnavigation/recastnavigation/blob/main/Detour/Include/DetourStatus.h).

Route payload includes points, requested/resolved endpoints, portable corridor geometry, backend references scoped to generation, ordered transition actions, world dependencies, and predicted objective/components. The adapter must supply conservative portable dependency coverage if the backend cannot; it cannot invent precise corridor support. Keep raw solver output and the final processed candidate as separate artifacts.

Admission order:

1. Parse and validate version, finite coordinates/costs, bounded sizes, identities, hashes, complete endpoint semantics, transition types, and references. No result-provided code is executed.
2. Match the active command/request/attempt/session and pinned generation. Initially reject any relevant world revision mismatch; dependency-aware revalidation can later admit changes outside the route. A moved actor also requires a validated connector from its current position, or a replan.
3. Convert into the shared candidate contract without losing outcome detail. Revalidate collision, trajectory envelope, conditional gates, corridor/dependencies, and actor configuration against Factorio.
4. Run permitted post-processing and validate the resulting geometry again; rescore with the declared objective. Shared selection alone accepts the final route.
5. Execute allowed route actions and native follower commands. Observe arrival, blocking, cancellation, and world changes through the episode/session loop.

The existing pipeline post-processes before its final validators. A cheap import/identity check can precede it, but the authoritative checks must apply to the exact route that will execute. Preserve existing schema-v1 behavior; implement richer outcomes and objective units through an explicitly versioned migration. Do not encode external timeout as v1 `no-path`, or silently disable v1's provider-specific early terminal rules.

## Lifecycle, synchronization, and replay

Offline import generates a data-only Lua module or companion-mod artifact before the isolated game loads; runtime cannot read arbitrary host JSON files. The host validates and escapes data during generation. The normal mod package has no solver-process dependency.

For live headless experiments, the host uses a fixed command handler with encoded data and `rcon.print` responses. Bound/chunk messages by negotiated limits and validate reassembly; never interpolate a solver-returned string as a Lua expression. Use isolated runner-owned server credentials and process handles. Transport loss or crash finishes as an explicit error/timeout and may activate the declared local fallback; it does not mark arrival.

Do not hold open handles, sockets, or native library references in Factorio storage. On a live save/load or reconnect, rotate the external session identity, reconstruct world/backend state, and reissue only the still-current command. The exact supported lifecycle hooks and synchronized delivery must be proven by an integration test before live use.

Factorio's `on_load` also runs on a joining multiplayer client. It must reconstruct
the same Lua-local state from saved storage, not independently cancel work or mark
that peer disconnected. Session rotation belongs to a synchronized host command.
The installed 2.0.77 [data lifecycle documentation](https://lua-api.factorio.com/2.0.77/auxiliary/data-lifecycle.html)
explicitly requires load/join equivalence. A headless server-only arrival test is
not evidence that a second client can join without a desync.

One authoritative host delivers external answers through Factorio's synchronized input/command path. Never let each multiplayer peer independently choose whichever sidecar answer arrives first. Log response admission tick and ordered messages; deterministic replay uses those recorded deliveries and does not depend on matching external wall-clock timing. Fresh-run timing variance remains a separate latency measurement.

GUI support has two paths: replay captured results in the existing TestKit lab on reload, or explicitly join the isolated headless server. Both consume the same fixtures, profiles and accepted-route renderer. The default suite never launches or attaches a graphical client.

## Evaluation and implementation packages

Each case records snapshot/query hashes, Factorio/mod/solver versions, backend config, actor/profile, ordered world actions, raw/final routes, validity reasons, semantic terminal outcome, and selected fallback. Measure export, transport, bake/update, search, validation, and execution separately. Compare cold and warm data, and report unsupported/partial/timeout cases rather than removing them from the denominator.

Implementation order and ownership:

| Package | Dependencies and owned files (proposed where absent) | Exit criteria |
| --- | --- | --- |
| A: Boundary contracts | Integration owner: shared contracts, profile/resolver, `PlanningRun`, report schema. | Query/data identities, per-provider capabilities, objective units, and generic completion/outcomes have conformance tests; `production-v1` baseline preserved. |
| B: Capture and replay | After A: isolated `devmods/scv-control-testkit/interchange/` plus host artifact adapters under `tools/navigation/`. | Export existing fixture-v4 cases, round-trip value/hash checks, import known routes through shared validation/follower, GUI replay from the same artifact. |
| C: Solver comparison | After A/B: separate external reference-graph and Recast/portal adapter directories. | Dijkstra reference and one library adapter solve identical declared input coverage; clearance, costs, failures and full setup work are reported. Pin dependency versions/licenses. |
| D: Live transport | After A/B: isolated transport adapter and host process controller. | Headless RCON probe plus stale/cancel/reorder/crash/load lifecycle cases; no GUI/Steam launches. UDP only after its own exact-version probe. |
| E: Domain composition | Existing gate/belt/world issue owners, after their calibration and A. | Shared real gate, belt, and dynamic-world episodes exercise every claimed capability through local and supported external profiles. |

A is the additional merge barrier; it does not reopen the completed original Phase 0. Gate and belt calibration can continue independently now. Once A/B land, C and D can proceed in parallel with one integration owner for central files. New paths above are ownership proposals, not existing APIs. Each implementation package runs `pwsh -NoProfile -File .\tools\test.ps1 -Suite all`; update the experiment log newest first with measured results and failed hypotheses.
