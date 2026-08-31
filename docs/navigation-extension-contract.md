# Navigation Extension Contract

Navigation composition is static and data-driven. Profiles and runtime references are
plain serializable tables; implementations are resolved from fixed registries after a
save is loaded. The initial schema version is `1`.

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
