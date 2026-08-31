# NavigationWorld

`NavigationWorld` is a domain-neutral, incremental view of navigation-relevant
Factorio state. It separates three revision categories:

- `topology`: static occupancy and conditional transitions;
- `motion`: walking-speed tiles and directed-motion entities;
- `transient`: moving actors observed by local steering.

## Storage contract

Store only the value returned by `NavigationWorld.new_state()`. Construct the
runtime handle after init, configuration change, or load:

```lua
local NavigationWorld = require("scripts.navigation.world.navigation_world")

storage.navigation_world = storage.navigation_world
  or NavigationWorld.new_state({region_size = 16})

local world = NavigationWorld.new(storage.navigation_world, {
  actor_collision_box = prototypes.entity.character.collision_box,
  actor_collision_mask = prototypes.entity.character.collision_mask,
  surface_resolver = function(index) return game.surfaces[index] end,
  tile_prototype_resolver = function(name) return prototypes.tile[name] end
})
```

The runtime handle and classifier callbacks contain functions and must not be
stored. Region snapshots, revisions, dependencies, and metrics contain only
serializable values. `world:reconstruct()` refreshes already tracked regions
without scanning an entire surface and without changing their revisions.

## Queries

- `query(surface_index, position)` places the configured actor collision box at
  the position, refreshes every intersecting region, and returns actor-center
  traversability, static occupancy, conditional transitions, motion
  observations, dependencies, and revisions. A call-specific
  `actor_collision_box` can override the configured footprint.
- `observe_transients(surface_index, bounds)` scans live moving actors in a
  bounded local-steering area. Transient actors are never persisted in region
  caches, and ordinary movement does not change world revisions.
- `directed_motion(surface_index, from, to)` samples motion context for a
  directed edge. A later cost model owns the velocity formula.
- `revision_snapshot(surface_index, bounds)` and
  `region_dependencies(surface_index, bounds)` capture bounded dependencies.
- `metrics()` reports dirty regions, rescanned cells/entities, revision changes,
  and reconstruction work.

Entity and tile classifier callbacks can add semantic transitions or motion
descriptors. Their results must contain serializable values.

## Event integration

`events.lua` owns the table-driven event inventory and normalization. The
production integration owner can compose it with existing handlers:

```lua
local bundle = world:event_bundle(defines.events)
script.on_event(bundle.event_ids, bundle.handle)
```

Local events only mark intersecting regions dirty. Tile changes raised through
`script_raised_set_tiles` use the cached old tile semantics when available and
fall back to conservative topology-and-motion invalidation when the region has
not been observed. Script changes that do not raise the corresponding Factorio
event cannot be observed by any event-driven world model.
