local Classification = require("scripts.navigation.world.classification")
local Geometry = require("scripts.navigation.world.geometry")

local Events = {}

local SPECS = {
  {name = "on_built_entity", kind = "entity", action = "add", field = "entity"},
  {name = "on_robot_built_entity", kind = "entity", action = "add", field = "entity"},
  {name = "script_raised_built", kind = "entity", action = "add", field = "entity"},
  {name = "script_raised_revive", kind = "entity", action = "add", field = "entity"},
  {name = "on_player_mined_entity", kind = "entity", action = "remove", field = "entity"},
  {name = "on_robot_mined_entity", kind = "entity", action = "remove", field = "entity"},
  {name = "on_entity_died", kind = "entity", action = "remove", field = "entity"},
  {name = "script_raised_destroy", kind = "entity", action = "remove", field = "entity"},
  {name = "on_player_rotated_entity", kind = "entity", action = "orientation", field = "entity"},
  {name = "on_player_flipped_entity", kind = "entity", action = "orientation", field = "entity"},
  {name = "on_entity_cloned", kind = "entity", action = "add", field = "destination"},
  {name = "on_area_cloned", kind = "area-clone"},
  {name = "script_raised_teleported", kind = "teleport", field = "entity"},
  {name = "on_player_built_tile", kind = "tiles", action = "build"},
  {name = "on_robot_built_tile", kind = "tiles", action = "build"},
  {name = "on_player_mined_tile", kind = "tiles", action = "mine"},
  {name = "on_robot_mined_tile", kind = "tiles", action = "mine"},
  {name = "script_raised_set_tiles", kind = "tiles", action = "script"},
  {name = "on_chunk_generated", kind = "chunk", action = "generated"},
  {name = "on_chunk_deleted", kind = "chunk", action = "deleted"},
  {name = "on_surface_created", kind = "surface", action = "ensure"},
  {name = "on_surface_imported", kind = "surface", action = "ensure"},
  {name = "on_surface_renamed", kind = "surface", action = "rename"},
  {name = "on_surface_cleared", kind = "surface", action = "clear"},
  {name = "on_surface_deleted", kind = "surface", action = "delete"}
}

local SPEC_BY_NAME = {}
for _, spec in ipairs(SPECS) do SPEC_BY_NAME[spec.name] = spec end

local function entity_bounds(entity, action)
  if action == "orientation" then
    return Geometry.orientation_envelope(entity.position, entity.prototype.collision_box)
  end
  return Geometry.copy_bounds(entity.bounding_box)
end

local function entity_mutation(spec, event, context)
  local entity = event[spec.field]
  local classification = context.classify_entity(entity)
  if not classification then return {} end
  return {{
    surface_index = entity.surface.index,
    bounds = entity_bounds(entity, spec.action),
    categories = Classification.categories(classification),
    source = spec.name,
    entity = classification.dependency,
    remove_entity_key = spec.action == "remove" and classification.key or nil
  }}
end

local function teleport_mutations(spec, event, context)
  local entity = event[spec.field]
  local classification = context.classify_entity(entity)
  if not classification then return {} end
  local categories = Classification.categories(classification)
  local current_bounds = Geometry.copy_bounds(entity.bounding_box)
  return {
    {
      surface_index = event.old_surface_index,
      bounds = Geometry.offset_for_position(
        current_bounds,
        entity.position,
        event.old_position
      ),
      categories = categories,
      source = spec.name,
      entity = classification.dependency
    },
    {
      surface_index = entity.surface.index,
      bounds = current_bounds,
      categories = categories,
      source = spec.name,
      entity = classification.dependency
    }
  }
end

local function tile_classes(spec, event, entry, context)
  local old_classification
  local new_classification
  if spec.action == "script" then
    old_classification = context.cached_tile_class(event.surface_index, entry.position)
    new_classification = context.classify_tile_name(entry.name)
  else
    old_classification = context.classify_tile_prototype(entry.old_tile)
    if spec.action == "build" then
      new_classification = context.classify_tile_prototype(event.tile)
    else
      new_classification = context.current_tile_class(event.surface_index, entry.position)
    end
  end
  return old_classification, new_classification
end

local function tile_mutations(spec, event, context)
  local mutations = {}
  for _, entry in ipairs(event.tiles or {}) do
    local old_classification, new_classification = tile_classes(
      spec,
      event,
      entry,
      context
    )
    local categories = Classification.tile_change(old_classification, new_classification)
    mutations[#mutations + 1] = {
      surface_index = event.surface_index,
      bounds = Geometry.tile_bounds(entry.position),
      categories = categories,
      source = spec.name,
      tile_position = Geometry.position(entry.position),
      old_tile = old_classification and old_classification.name,
      new_tile = new_classification and new_classification.name
    }
  end
  return mutations
end

local function chunk_mutations(spec, event)
  local categories = spec.action == "deleted"
    and {topology = true, motion = true, transient = true}
    or {topology = true, motion = true}
  local positions = event.positions or {event.position}
  local mutations = {}
  for _, position in ipairs(positions) do
    mutations[#mutations + 1] = {
      surface_index = event.surface_index or event.surface.index,
      bounds = Geometry.chunk_bounds(position),
      categories = categories,
      source = spec.name
    }
  end
  return mutations
end

local function area_clone_mutations(spec, event)
  local categories = {}
  if event.clone_tiles then
    categories.topology = true
    categories.motion = true
  end
  if event.clear_destination_entities then
    categories.topology = true
    categories.motion = true
    categories.transient = true
  end
  if not next(categories) then return {} end
  return {{
    surface_index = event.destination_surface.index,
    bounds = Geometry.copy_bounds(event.destination_area),
    categories = categories,
    source = spec.name
  }}
end

local function surface_operation(spec, event)
  return {
    action = spec.action,
    surface_index = event.surface_index,
    source = spec.name
  }
end

function Events.normalize(event_name, event, context)
  local spec = SPEC_BY_NAME[event_name]
  if not spec then
    return {mutations = {}, operations = {}, unsupported = event_name}
  end
  if spec.kind == "entity" then
    return {mutations = entity_mutation(spec, event, context), operations = {}}
  elseif spec.kind == "teleport" then
    return {mutations = teleport_mutations(spec, event, context), operations = {}}
  elseif spec.kind == "tiles" then
    return {mutations = tile_mutations(spec, event, context), operations = {}}
  elseif spec.kind == "chunk" then
    return {mutations = chunk_mutations(spec, event), operations = {}}
  elseif spec.kind == "area-clone" then
    return {mutations = area_clone_mutations(spec, event), operations = {}}
  elseif spec.kind == "surface" then
    return {mutations = {}, operations = {surface_operation(spec, event)}}
  end
  return {mutations = {}, operations = {}, unsupported = event_name}
end

function Events.event_names()
  local names = {}
  for _, spec in ipairs(SPECS) do names[#names + 1] = spec.name end
  return names
end

function Events.specifications()
  local specifications = {}
  for _, spec in ipairs(SPECS) do
    local copy = {}
    for key, value in pairs(spec) do copy[key] = value end
    specifications[#specifications + 1] = copy
  end
  return specifications
end

function Events.compose(defines_events, world)
  local event_ids = {}
  local names_by_id = {}
  for _, spec in ipairs(SPECS) do
    local event_id = defines_events[spec.name]
    if event_id then
      event_ids[#event_ids + 1] = event_id
      names_by_id[event_id] = spec.name
    end
  end
  return {
    event_ids = event_ids,
    names_by_id = names_by_id,
    handle = function(event)
      local event_name = names_by_id[event.name]
      if event_name then return world:handle_event(event_name, event) end
      return nil
    end
  }
end

return Events
