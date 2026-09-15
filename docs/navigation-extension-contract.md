# Navigation Extension Contract

Navigation composition is static and data-driven. Profiles and runtime references are
plain serializable tables; implementations are resolved from fixed registries after a
save is loaded. The initial schema version is `1`.

This document describes implemented Lua contracts, including the bounded external
boundary below. The [solver boundary](navigation-solver-boundary.md) separates the
implemented subset from longer-term domain and backend requirements. Plain-table
serializability alone does not implement that boundary.

## Implemented boundary extension (`scv-navigation/1`)

The framework now has an independently versioned external value contract in
`scripts/navigation/solver_boundary.lua`. `NavigationData` stores committed bounded
snapshots and stages revisioned deltas; it does not build meshes. A query binds actor,
endpoints, session/command/attempt, backend generation, source checksum, objective units,
capabilities and budget. Snapshot and query content are immutable for that request.

`ProfileResolver.preflight_query` checks every provider's supported objective, backend,
and required capabilities. `interchange-distance-v1` accepts recorded results;
`external-distance-v1` adds callback-based asynchronous completion. Both use the shared
collision/trajectory validators, scorer, selector, and native follower. Neither claims
calibrated gate actions, belts, a mesh backend, or travel-time execution yet. The offline
Python graph solver can compare directed travel-time objectives in synthetic graphs.

`PlanningRun.start` accepts `specification.navigation_query`. Runtime services provide
`navigation_snapshot`, `navigation_data_ref`, and either `solver_result` for import or
`request_solver(query)` for asynchronous submission. Its nonempty string token is
completed through `PlanningRun.handle_solver_result(run, {id=token,
provider_id="external-route", result=result}, runtime)`. Engine and external completion
channels cannot satisfy one another. `fail_pending` closes a transport failure; normal
`cancel` prevents late replies from reactivating a route. The transport owner remains
responsible for its watchdog and discarding process-local work.

Existing Lua schema-v1 terminal statuses remain unchanged. External detail is retained
in `planning_result.values.solver_outcome`: partial/budget/unsupported/error become
`failed`, cancellation becomes `cancelled`, and a scoped solver `no-path` remains
`no-path`. These outcomes are never presented as arrival. Per-route objective values
and units are recorded under `route.values.scored_objective`; geometric distance is
always computed separately.

Captured queries separate `goal_tolerance` (solver endpoint eligibility) from
`execution.arrival_tolerance` (the existing speed-dependent native follower
stopping bound). Replay checks the latter against `Follower.tolerance(actor)`;
an imported query cannot enlarge it. Reports retain both actual arrival error and
the pinned execution bound. This exposes existing controller behavior, not a new
tuning value or a relaxed assertion after movement.

The new profiles preserve imported points without geometric smoothing. This makes the
raw versus accepted comparison explicit and avoids unimplemented objective/transition
preservation promises. Validators consume any candidate route; declaring it safe before
validation is no longer a registry prerequisite. `production-v1` retains its existing
smoothing, provider order and selection behavior.

Use `canonical.lua` for cross-language value identity and `wire_json.lua` for
hash-sensitive export. The normal Factorio JSON writer can round binary64 values:
its output is unsuitable for exact snapshot identity. `scv-c14n1-adler32` is a
non-cryptographic content checksum, with plain Lua empty objects/arrays normalized
to the same representation. Identity checks and live collision validation remain
required regardless of the checksum.

## Storage boundary

Production storage contains only the selected profile ID and serializable run values:

```lua
{
  schema_version = 1,
  profile_id = "production-v1",
  values = {}
}
```

Do not store a registry entry, module table, callback, metatable, Lua object, or resolved
profile. `scripts/navigation/serializable.lua` rejects functions, userdata, threads,
non-finite numbers, metatables, cycles, and unsupported table keys. Resolve the stored
reference again after load or configuration change.

## Versioned values

`scripts/navigation/contracts.lua` owns schemas for:

- profile and profile reference;
- candidate;
- successful route, including corridor segments;
- route action and world dependency;
- validator result and cost result;
- metrics;
- terminal result.

Every top-level contract carries `schema_version`. Embedded corridor geometry inherits
the route schema version. New optional data belongs under a contract's `values`,
`components`, `metrics.values`, or another explicitly serializable extension table.
Changing required fields or their meaning requires a new schema version and an explicit
migration; do not silently reinterpret version `1` values.

## Registry families

Each stage has a separate registry under `scripts/navigation/registries/`:

1. world models;
2. candidate providers;
3. post-processors;
4. validators;
5. cost models;
6. selectors;
7. trajectory adapters;
8. replan policies.

A registry entry declares an ID, implementation module string, provided capabilities,
and required capabilities. IDs and capability names are stable public contracts. Add a
new entry to only its owning family, then wire an intentional profile through the central
registry/profile indexes. Do not add algorithm-specific branches to a benchmark or
production orchestrator.

Registry entries are descriptors, not mutable configuration. Per-profile configuration
belongs in the profile; per-run data belongs in the stored reference's `values` table.

## Preflight and resolution

Call `ProfileResolver.preflight(reference)` before issuing engine requests. It validates
the profile contract, resolves every ID to a registry descriptor, and verifies component
and profile capability requirements. Failure returns a serializable
`profile-resolution-error` with a stable code and contextual fields such as `stage`,
`component_id`, and `missing_capabilities`.

Implementation modules are loaded into private registry tables by calling
`ProfileResolver.load_implementations()` during `control.lua` parsing, because Factorio
forbids `require` from runtime events. This explicit bootstrap also lets registries refer
to an orchestrator that loaded the resolver without creating a circular `require`. Call
`ProfileResolver.resolve(reference)` after load when those implementations are needed.
Its return value contains module tables and must remain transient.

The following errors are deterministic pre-run failures:

- `invalid-profile-reference` or `invalid-profile`;
- `unknown-profile` or `unknown-component`;
- `invalid-stage-combination`;
- `missing-capability` or `missing-profile-capability`;
- `module-load-failed`.

## `production-v1`

`production-v1` describes the existing production behavior without changing it: serial
normal and inflated engine requests, conservative local A*, safe string pulling, actor
and trajectory clearance validation, polyline-distance comparison, least-cost safe
selection, native direction trajectory decomposition, and the existing stuck retry
policy. Future behavior changes require a new profile ID rather than changing the meaning
of `production-v1`.
