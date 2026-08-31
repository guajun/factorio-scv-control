local Events = require("__factorio-scv-control__/scripts/navigation/world/events")
local NavigationWorld = require("__factorio-scv-control__/scripts/navigation/world/navigation_world")

local WorldTests = {}

local REGION_SIZE = 8
local ON_POSITION = {x = 74, y = 42}
local OFF_POSITION = {x = 90, y = 42}
local BOUNDARY_WALL_POSITION = {x = 80, y = 47}
local MOTION_TILE_POSITION = {x = 75, y = 43}
local OFF_MOTION_TILE_POSITION = {x = 92, y = 44}
local TOPOLOGY_TILE_POSITION = {x = 77, y = 43}
local BELT_POSITION = {x = 76, y = 45}
local CHARACTER_START = {x = 78, y = 46}
local CHARACTER_END = {x = 86, y = 46}

local function point_bounds(position)
  return {
    left_top = {x = position.x, y = position.y},
    right_bottom = {x = position.x + 0.01, y = position.y + 0.01}
  }
end

local function add_result(results, name, passed, details)
  results[#results + 1] = {
    name = name,
    passed = passed == true,
    details = details
  }
end

local function only_category(report, category)
  local surface = report.surfaces[1]
  return surface
    and surface.categories[category] == true
    and (category == "topology" or not surface.categories.topology)
    and (category == "motion" or not surface.categories.motion)
    and (category == "transient" or not surface.categories.transient)
end

local function revisions_at(world, surface_index, position)
  local snapshot = world:revision_snapshot(surface_index, point_bounds(position))
  return snapshot.regions[1].revisions
end

local function same_revisions(first, second)
  return first.topology == second.topology
    and first.motion == second.motion
    and first.transient == second.transient
end

local function contains_motion(query, kind)
  for _, motion in ipairs(query.motion) do
    if motion.kind == kind then return true end
  end
  return false
end

local function prepare_area(surface)
  local area = {{68, 36}, {96, 49}}
  for _, entity in pairs(surface.find_entities_filtered({area = area})) do
    entity.destroy()
  end
  local tiles = {}
  for x = 68, 95 do
    for y = 36, 48 do
      tiles[#tiles + 1] = {name = "refined-concrete", position = {x, y}}
    end
  end
  surface.set_tiles(tiles, true, false, false, false)
  surface.set_tiles({{
    name = "landfill",
    position = TOPOLOGY_TILE_POSITION
  }}, true, false, false, false)
  return area
end

local function runtime_for(surface)
  return {
    actor_collision_box = prototypes.entity.character.collision_box,
    actor_collision_mask = prototypes.entity.character.collision_mask,
    surface_resolver = function(surface_index)
      return surface_index == surface.index and surface or nil
    end,
    tile_prototype_resolver = function(name) return prototypes.tile[name] end
  }
end

local function count_region_dependencies(dependencies)
  local count = 0
  for _, dependency in ipairs(dependencies) do
    if dependency.kind == "navigation-region" then count = count + 1 end
  end
  return count
end

local function cleanup(surface, area)
  for _, entity in pairs(surface.find_entities_filtered({area = area})) do
    entity.destroy()
  end
  local tiles = {}
  for x = 68, 95 do
    for y = 36, 48 do
      tiles[#tiles + 1] = {name = "refined-concrete", position = {x, y}}
    end
  end
  surface.set_tiles(tiles, true, false, false, false)
end

local function prepare_movement_area(surface)
  local area = {{68, 54}, {90, 59}}
  for _, entity in pairs(surface.find_entities_filtered({area = area})) do
    entity.destroy()
  end
  local tiles = {}
  for x = 68, 89 do
    for y = 54, 58 do
      tiles[#tiles + 1] = {name = "refined-concrete", position = {x, y}}
    end
  end
  surface.set_tiles(tiles, true, false, false, false)
  return area
end

local function observation_bounds(position)
  return {
    left_top = {x = position.x - 1, y = position.y - 1},
    right_bottom = {x = position.x + 1, y = position.y + 1}
  }
end

local function contains_unit(entities, unit_number)
  for _, entity in ipairs(entities) do
    if entity.unit_number == unit_number then return true end
  end
  return false
end

function WorldTests.run(surface)
  local results = {}
  local area = prepare_area(surface)
  local state = NavigationWorld.new_state({region_size = REGION_SIZE})
  local runtime = runtime_for(surface)
  local world = NavigationWorld.new(state, runtime)
  local surface_index = surface.index

  world:query(surface_index, ON_POSITION)
  world:query(surface_index, OFF_POSITION)

  local event_names = {}
  for _, event_name in ipairs(Events.event_names()) do event_names[event_name] = true end
  local required_events = {
    "on_built_entity",
    "on_robot_built_entity",
    "script_raised_built",
    "script_raised_revive",
    "on_player_mined_entity",
    "on_robot_mined_entity",
    "script_raised_destroy",
    "on_entity_died",
    "on_player_rotated_entity",
    "on_player_flipped_entity",
    "on_entity_cloned",
    "on_area_cloned",
    "script_raised_teleported",
    "on_player_built_tile",
    "on_robot_built_tile",
    "on_player_mined_tile",
    "on_robot_mined_tile",
    "script_raised_set_tiles",
    "on_chunk_generated",
    "on_chunk_deleted",
    "on_surface_created",
    "on_surface_imported",
    "on_surface_renamed",
    "on_surface_cleared",
    "on_surface_deleted"
  }
  local coverage_complete = true
  for _, event_name in ipairs(required_events) do
    if not event_names[event_name] then coverage_complete = false end
  end
  local bundle = world:event_bundle(defines.events)
  add_result(results, "navigation_world.event_coverage_is_table_driven",
    coverage_complete and #bundle.event_ids == #required_events, {
      required_count = #required_events,
      composed_count = #bundle.event_ids
    })

  local on_before = revisions_at(world, surface_index, ON_POSITION)
  local off_before = revisions_at(world, surface_index, OFF_POSITION)
  local on_wall = surface.create_entity({
    name = "stone-wall",
    position = ON_POSITION,
    force = "neutral"
  })
  local on_wall_position = {x = on_wall.position.x, y = on_wall.position.y}
  local wall_report = world:handle_event("script_raised_built", {entity = on_wall})
  local on_after_wall = revisions_at(world, surface_index, on_wall_position)
  local off_after_wall = revisions_at(world, surface_index, OFF_POSITION)
  local wall_query = world:query(surface_index, on_wall_position)
  add_result(results, "navigation_world.on_region_entity_updates_topology_only",
    only_category(wall_report, "topology")
      and on_after_wall.topology == on_before.topology + 1
      and on_after_wall.motion == on_before.motion
      and on_after_wall.transient == on_before.transient
      and same_revisions(off_before, off_after_wall)
      and not wall_query.traversable
      and #wall_query.occupancy >= 1, {
        report = wall_report,
        on_before = on_before,
        on_after = on_after_wall,
        off_before = off_before,
        off_after = off_after_wall,
        traversable = wall_query.traversable,
        wall_position = {x = on_wall.position.x, y = on_wall.position.y},
        wall_bounds = on_wall.bounding_box,
        cached_entities = state.surfaces[tostring(surface_index)]
          .regions["9,5"].entities
      })

  local off_wall = surface.create_entity({
    name = "stone-wall",
    position = OFF_POSITION,
    force = "neutral"
  })
  local off_wall_position = {x = off_wall.position.x, y = off_wall.position.y}
  local on_before_off_event = revisions_at(world, surface_index, ON_POSITION)
  local off_wall_report = world:handle_event("script_raised_built", {entity = off_wall})
  local on_after_off_event = revisions_at(world, surface_index, ON_POSITION)
  local off_after_off_event = revisions_at(world, surface_index, OFF_POSITION)
  add_result(results, "navigation_world.off_region_entity_leaves_on_region_unchanged",
    only_category(off_wall_report, "topology")
      and same_revisions(on_before_off_event, on_after_off_event)
      and off_after_off_event.topology > off_after_wall.topology, {
        report = off_wall_report,
        on_before = on_before_off_event,
        on_after = on_after_off_event,
        off_after = off_after_off_event
      })

  local boundary_wall = surface.create_entity({
    name = "stone-wall",
    position = BOUNDARY_WALL_POSITION,
    force = "neutral"
  })
  world:handle_event("script_raised_built", {entity = boundary_wall})
  local actor_box = prototypes.entity.character.collision_box
  local clearance_position = {
    x = boundary_wall.bounding_box.left_top.x
      - actor_box.right_bottom.x + 0.01,
    y = boundary_wall.position.y
  }
  local clearance_query = world:query(surface_index, clearance_position)
  add_result(results, "navigation_world.actor_footprint_crosses_region_boundary",
    clearance_position.x < boundary_wall.bounding_box.left_top.x
      and not clearance_query.traversable
      and #clearance_query.occupancy >= 1
      and count_region_dependencies(clearance_query.dependencies) >= 2, {
        center = clearance_position,
        actor_bounds = clearance_query.actor_bounds,
        wall_bounds = boundary_wall.bounding_box,
        dependencies = clearance_query.dependencies,
        traversable = clearance_query.traversable
      })

  local belt = surface.create_entity({
    name = "transport-belt",
    position = BELT_POSITION,
    direction = defines.direction.east,
    force = "player"
  })
  local belt_position = {x = belt.position.x, y = belt.position.y}
  local topology_before_belt = revisions_at(world, surface_index, belt_position).topology
  local belt_report = world:handle_event("script_raised_built", {entity = belt})
  local belt_revisions = revisions_at(world, surface_index, belt_position)
  local belt_query = world:query(surface_index, belt_position)
  add_result(results, "navigation_world.directed_motion_is_not_topology",
    only_category(belt_report, "motion")
      and belt_revisions.topology == topology_before_belt
      and contains_motion(belt_query, "directed-entity"), {
        report = belt_report,
        revisions = belt_revisions,
        motion = belt_query.motion,
        belt_position = {x = belt.position.x, y = belt.position.y},
        belt_bounds = belt.bounding_box,
        cached_entities = state.surfaces[tostring(surface_index)]
          .regions["9,5"].entities
      })

  local motion_old_tile = surface.get_tile(
    MOTION_TILE_POSITION.x,
    MOTION_TILE_POSITION.y
  ).prototype
  local on_before_motion_tile = revisions_at(world, surface_index, ON_POSITION)
  surface.set_tiles({{
    name = "stone-path",
    position = MOTION_TILE_POSITION
  }}, true, false, false, false)
  local motion_tile_report = world:handle_event("on_player_built_tile", {
    surface_index = surface_index,
    tile = prototypes.tile["stone-path"],
    tiles = {{old_tile = motion_old_tile, position = MOTION_TILE_POSITION}}
  })
  local motion_tile_query = world:query(surface_index, MOTION_TILE_POSITION)
  add_result(results, "navigation_world.walking_tile_updates_motion_only",
    only_category(motion_tile_report, "motion")
      and revisions_at(world, surface_index, ON_POSITION).topology
        == on_before_motion_tile.topology
      and contains_motion(motion_tile_query, "walking-speed"), {
        report = motion_tile_report,
        tile = motion_tile_query.tile
      })

  local off_motion_old_tile = surface.get_tile(
    OFF_MOTION_TILE_POSITION.x,
    OFF_MOTION_TILE_POSITION.y
  ).prototype
  local on_before_off_tile = revisions_at(world, surface_index, ON_POSITION)
  local off_before_off_tile = revisions_at(
    world,
    surface_index,
    OFF_MOTION_TILE_POSITION
  )
  surface.set_tiles({{
    name = "stone-path",
    position = OFF_MOTION_TILE_POSITION
  }}, true, false, false, false)
  local off_tile_report = world:handle_event("on_robot_built_tile", {
    surface_index = surface_index,
    tile = prototypes.tile["stone-path"],
    tiles = {{old_tile = off_motion_old_tile, position = OFF_MOTION_TILE_POSITION}}
  })
  local on_after_off_tile = revisions_at(world, surface_index, ON_POSITION)
  local off_after_off_tile = revisions_at(
    world,
    surface_index,
    OFF_MOTION_TILE_POSITION
  )
  add_result(results, "navigation_world.off_region_tile_leaves_on_region_unchanged",
    only_category(off_tile_report, "motion")
      and same_revisions(on_before_off_tile, on_after_off_tile)
      and off_after_off_tile.motion > off_before_off_tile.motion, {
        report = off_tile_report,
        on_before = on_before_off_tile,
        on_after = on_after_off_tile,
        off_before = off_before_off_tile,
        off_after = off_after_off_tile
      })

  world:query(surface_index, TOPOLOGY_TILE_POSITION)
  local motion_before_topology_tile = revisions_at(
    world,
    surface_index,
    TOPOLOGY_TILE_POSITION
  ).motion
  surface.set_tiles({{
    name = "water",
    position = TOPOLOGY_TILE_POSITION
  }}, true, false, false, false)
  local topology_tile_report = world:handle_event("script_raised_set_tiles", {
    surface_index = surface_index,
    tiles = {{name = "water", position = TOPOLOGY_TILE_POSITION}}
  })
  local topology_tile_revisions = revisions_at(
    world,
    surface_index,
    TOPOLOGY_TILE_POSITION
  )
  local topology_tile_query = world:query(surface_index, TOPOLOGY_TILE_POSITION)
  add_result(results, "navigation_world.script_tile_uses_cached_old_semantics",
    only_category(topology_tile_report, "topology")
      and topology_tile_revisions.motion == motion_before_topology_tile
      and not topology_tile_query.traversable, {
        report = topology_tile_report,
        revisions = topology_tile_revisions,
        tile = topology_tile_query.tile
      })

  local test_character = surface.create_entity({
    name = "character",
    position = CHARACTER_START,
    force = "player"
  })
  local topology_before_transient = state.surfaces[tostring(surface_index)]
    .revisions.topology
  local transient_build_report = world:handle_event("script_raised_revive", {
    entity = test_character
  })
  test_character.teleport(CHARACTER_END)
  local transient_move_report = world:handle_event("script_raised_teleported", {
    entity = test_character,
    old_position = CHARACTER_START,
    old_surface_index = surface_index
  })
  local surface_revisions = state.surfaces[tostring(surface_index)].revisions
  add_result(results, "navigation_world.transient_observations_do_not_touch_topology",
    only_category(transient_build_report, "transient")
      and only_category(transient_move_report, "transient")
      and surface_revisions.topology == topology_before_transient
      and surface_revisions.transient >= 2, {
        build_report = transient_build_report,
        move_report = transient_move_report,
        revisions = surface_revisions
      })

  local dependency_query = world:query(surface_index, on_wall_position)
  local region_dependency = dependency_query.dependencies[1]
  add_result(results, "navigation_world.queries_expose_region_and_entity_dependencies",
    region_dependency.kind == "navigation-region"
      and region_dependency.region_key ~= nil
      and #dependency_query.dependencies >= 2, {
        dependencies = dependency_query.dependencies
      })

  local conditional_runtime = runtime_for(surface)
  conditional_runtime.entity_classifiers = {
    function(entity)
      if entity.unit_number == on_wall.unit_number then
        return {
          transition = {
            traversable = true,
            condition = "fixture-transition",
            expected_delay_ticks = 3
          }
        }
      end
      return nil
    end
  }
  local conditional_state = NavigationWorld.new_state({region_size = REGION_SIZE})
  local conditional_world = NavigationWorld.new(conditional_state, conditional_runtime)
  local conditional_query = conditional_world:query(surface_index, on_wall_position)
  add_result(results, "navigation_world.conditional_transition_is_extensible",
    conditional_query.traversable
      and #conditional_query.transitions == 1
      and conditional_query.transitions[1].condition == "fixture-transition"
      and #helpers.table_to_json(conditional_state) > 0, {
        transitions = conditional_query.transitions,
        traversable = conditional_query.traversable
      })

  local directed = world:directed_motion(
    surface_index,
    {x = belt_position.x - 0.25, y = belt_position.y},
    {x = belt_position.x + 0.25, y = belt_position.y}
  )
  add_result(results, "navigation_world.directed_motion_query_reports_edge_context",
    directed.travel_vector.x > 0
      and #directed.samples == 3
      and contains_motion({motion = directed.samples[2].motion}, "directed-entity")
      and #directed.dependencies >= 1, directed)

  local before_reconstruction = world:query(surface_index, on_wall_position)
  local before_revision_snapshot = world:revision_snapshot(
    surface_index,
    {left_top = {x = 72, y = 40}, right_bottom = {x = 92, y = 47}}
  )
  local encoded_state = helpers.table_to_json(state)
  local restored_state = helpers.json_to_table(encoded_state)
  local restored_world = NavigationWorld.new(restored_state, runtime)
  local reconstruction = restored_world:reconstruct({surface_index})
  local after_reconstruction = restored_world:query(surface_index, on_wall_position)
  local after_revision_snapshot = restored_world:revision_snapshot(
    surface_index,
    {left_top = {x = 72, y = 40}, right_bottom = {x = 92, y = 47}}
  )
  local revision_round_trip = same_revisions(
    before_revision_snapshot.surface,
    after_revision_snapshot.surface
  ) and #before_revision_snapshot.regions == #after_revision_snapshot.regions
  for index, before_region in ipairs(before_revision_snapshot.regions) do
    local after_region = after_revision_snapshot.regions[index]
    revision_round_trip = revision_round_trip
      and before_region.key == after_region.key
      and same_revisions(before_region.revisions, after_region.revisions)
  end
  add_result(results, "navigation_world.serialized_cold_reconstruction_is_equivalent",
    #encoded_state > 0
      and reconstruction.regions_rescanned > 0
      and before_reconstruction.traversable == after_reconstruction.traversable
      and not after_reconstruction.traversable
      and #before_reconstruction.occupancy == #after_reconstruction.occupancy
      and revision_round_trip, {
        reconstruction = reconstruction,
        before_revisions = before_revision_snapshot,
        after_revisions = after_revision_snapshot
      })

  local on_before_destroy = revisions_at(
    restored_world,
    surface_index,
    on_wall_position
  )
  local destroy_report = restored_world:handle_event("script_raised_destroy", {
    entity = off_wall
  })
  local off_after_destroy = restored_world:query(surface_index, off_wall_position)
  off_wall.destroy()
  local on_after_destroy = revisions_at(
    restored_world,
    surface_index,
    on_wall_position
  )
  add_result(results, "navigation_world.script_destroy_invalidates_only_target_region",
    only_category(destroy_report, "topology")
      and off_after_destroy.traversable
      and same_revisions(on_before_destroy, on_after_destroy), {
        report = destroy_report,
        off_traversable = off_after_destroy.traversable,
        on_before = on_before_destroy,
        on_after = on_after_destroy
      })

  local metrics = restored_world:metrics()
  add_result(results, "navigation_world.rescans_are_region_bounded",
    metrics.full_surface_rescans == 0
      and metrics.region_rescans > 0
      and metrics.cells_rescanned == metrics.region_rescans * REGION_SIZE * REGION_SIZE
      and metrics.revision_changes.topology > 0
      and metrics.revision_changes.motion > 0
      and metrics.revision_changes.transient > 0, metrics)

  cleanup(surface, area)
  return results
end

function WorldTests.start_movement(surface)
  local area = prepare_movement_area(surface)
  local character = surface.create_entity({
    name = "character",
    position = {x = 74, y = 56},
    force = "player"
  })
  local start_position = {x = character.position.x, y = character.position.y}
  local target_position = {x = 82, y = start_position.y}
  local state = NavigationWorld.new_state({region_size = REGION_SIZE})
  local world = NavigationWorld.new(state, runtime_for(surface))
  world:handle_event("script_raised_built", {entity = character})
  world:query(surface.index, start_position)
  world:query(surface.index, target_position)
  return {
    area = area,
    character = character,
    state = state,
    start_position = start_position,
    target_position = target_position,
    start_revisions = revisions_at(world, surface.index, start_position),
    target_revisions = revisions_at(world, surface.index, target_position)
  }
end

function WorldTests.update_movement(surface, test)
  local character = test.character
  if not character or not character.valid then
    return {
      name = "navigation_world.live_transients_follow_ordinary_movement",
      passed = false,
      details = {status = "character-invalid"}
    }
  end
  if character.position.x < test.target_position.x then
    character.walking_state = {walking = true, direction = defines.direction.east}
    return nil
  end

  character.walking_state = {walking = false, direction = defines.direction.east}
  local current_position = {x = character.position.x, y = character.position.y}
  local world = NavigationWorld.new(test.state, runtime_for(surface))
  local old_observation = world:observe_transients(
    surface.index,
    observation_bounds(test.start_position)
  )
  local current_observation = world:observe_transients(
    surface.index,
    observation_bounds(current_position)
  )
  local old_static = world:query(surface.index, test.start_position)
  local current_static = world:query(surface.index, current_position)
  local start_revisions = revisions_at(world, surface.index, test.start_position)
  local target_revisions = revisions_at(world, surface.index, test.target_position)
  local unit_number = character.unit_number
  local crossed_region = math.floor(test.start_position.x / REGION_SIZE)
    ~= math.floor(current_position.x / REGION_SIZE)
  local passed = crossed_region
    and not contains_unit(old_observation.entities, unit_number)
    and contains_unit(current_observation.entities, unit_number)
    and not contains_unit(old_static.occupancy, unit_number)
    and not contains_unit(current_static.occupancy, unit_number)
    and same_revisions(test.start_revisions, start_revisions)
    and same_revisions(test.target_revisions, target_revisions)
  local details = {
    start_position = test.start_position,
    current_position = current_position,
    old_observation = old_observation,
    current_observation = current_observation,
    old_static_occupancy = old_static.occupancy,
    current_static_occupancy = current_static.occupancy,
    start_revisions_before = test.start_revisions,
    start_revisions_after = start_revisions,
    target_revisions_before = test.target_revisions,
    target_revisions_after = target_revisions,
    metrics = world:metrics()
  }
  character.destroy()
  return {
    name = "navigation_world.live_transients_follow_ordinary_movement",
    passed = passed,
    details = details
  }
end

return WorldTests
