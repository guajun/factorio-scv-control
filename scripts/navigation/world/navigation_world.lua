local Classification = require("scripts.navigation.world.classification")
local Events = require("scripts.navigation.world.events")
local Geometry = require("scripts.navigation.world.geometry")

local NavigationWorld = {}
local World = {}
World.__index = World

local SCHEMA_VERSION = 1
local DEFAULT_REGION_SIZE = 16
local CATEGORIES = {"topology", "motion", "transient"}

local function copy_basic(value, seen)
  local value_type = type(value)
  if value_type == "nil" or value_type == "boolean"
      or value_type == "number" or value_type == "string" then
    return value
  end
  if value_type ~= "table" then
    error("NavigationWorld state values must be serializable, got " .. value_type)
  end
  seen = seen or {}
  if seen[value] then error("NavigationWorld state values cannot contain cycles") end
  seen[value] = true
  local result = {}
  for key, item in pairs(value) do
    result[copy_basic(key, seen)] = copy_basic(item, seen)
  end
  seen[value] = nil
  return result
end

local function zero_revisions()
  return {topology = 0, motion = 0, transient = 0}
end

local function zero_metrics()
  return {
    events_normalized = 0,
    mutations_applied = 0,
    regions_dirtied = 0,
    dirty_regions_by_category = zero_revisions(),
    region_rescans = 0,
    cells_rescanned = 0,
    entities_rescanned = 0,
    revision_changes = zero_revisions(),
    reconstructions = 0,
    transient_observation_queries = 0,
    transient_entities_observed = 0,
    full_surface_rescans = 0
  }
end

local function ensure_metric_shape(metrics)
  local defaults = zero_metrics()
  for key, value in pairs(defaults) do
    if metrics[key] == nil then metrics[key] = copy_basic(value) end
  end
  for _, category in ipairs(CATEGORIES) do
    metrics.dirty_regions_by_category[category] =
      metrics.dirty_regions_by_category[category] or 0
    metrics.revision_changes[category] = metrics.revision_changes[category] or 0
  end
end

function NavigationWorld.new_state(options)
  options = options or {}
  local region_size = options.region_size or DEFAULT_REGION_SIZE
  assert(region_size > 0 and region_size == math.floor(region_size),
    "NavigationWorld region_size must be a positive integer")
  return {
    schema_version = SCHEMA_VERSION,
    config = {region_size = region_size},
    surfaces = {},
    metrics = zero_metrics()
  }
end

local function validate_state(state)
  assert(type(state) == "table", "NavigationWorld state is required")
  assert(state.schema_version == SCHEMA_VERSION,
    "Unsupported NavigationWorld schema version: " .. tostring(state.schema_version))
  assert(state.config and state.config.region_size,
    "NavigationWorld state is missing region_size")
  state.surfaces = state.surfaces or {}
  state.metrics = state.metrics or zero_metrics()
  ensure_metric_shape(state.metrics)
  for _, surface_state in pairs(state.surfaces) do
    for _, region in pairs(surface_state.regions or {}) do
      for key, entity in pairs(region.entities or {}) do
        if entity.transient and not entity.topology
            and not entity.motion and not entity.transition then
          region.entities[key] = nil
        end
      end
    end
  end
end

function NavigationWorld.new(state, runtime)
  state = state or NavigationWorld.new_state()
  validate_state(state)
  return setmetatable({
    _state = state,
    _runtime = runtime or {}
  }, World)
end

function World:_surface(surface_index)
  if self._runtime.surface_resolver then
    return self._runtime.surface_resolver(surface_index)
  end
  return game and game.surfaces[surface_index] or nil
end

function World:_tile_prototype(name)
  if self._runtime.tile_prototype_resolver then
    return self._runtime.tile_prototype_resolver(name)
  end
  return prototypes and prototypes.tile[name] or nil
end

function World:_classification_runtime()
  return {
    actor_collision_mask = self._runtime.actor_collision_mask,
    entity_classifiers = self._runtime.entity_classifiers,
    tile_classifiers = self._runtime.tile_classifiers
  }
end

function World:_classify_entity(entity)
  return Classification.entity(entity, self:_classification_runtime())
end

function World:_classify_tile_prototype(prototype)
  return Classification.tile(prototype, self:_classification_runtime())
end

function World:_surface_state(surface_index)
  local key = tostring(surface_index)
  local surface_state = self._state.surfaces[key]
  if not surface_state then
    local surface = self:_surface(surface_index)
    surface_state = {
      surface_index = surface_index,
      surface_name = surface and surface.name or nil,
      revisions = zero_revisions(),
      base_revisions = zero_revisions(),
      regions = {}
    }
    self._state.surfaces[key] = surface_state
  end
  return surface_state
end

function World:_region(surface_state, rx, ry)
  local key = Geometry.region_key(rx, ry)
  local region = surface_state.regions[key]
  if not region then
    region = {
      key = key,
      rx = rx,
      ry = ry,
      revisions = copy_basic(surface_state.base_revisions),
      dirty = {topology = true, motion = true, transient = true},
      scanned = false,
      entities = {},
      removed_entities = {},
      tiles = {}
    }
    surface_state.regions[key] = region
  end
  return region
end

local function has_categories(categories)
  return categories
    and (categories.topology or categories.motion or categories.transient)
end

local function sorted_values_by_key(values)
  table.sort(values, function(first, second) return first.key < second.key end)
  return values
end

function World:_apply_mutations(mutations, event_name)
  local groups = {}
  for _, mutation in ipairs(mutations) do
    if has_categories(mutation.categories) then
      local surface_key = tostring(mutation.surface_index)
      local group = groups[surface_key]
      if not group then
        group = {
          surface_index = mutation.surface_index,
          categories = {},
          regions = {},
          mutation_count = 0
        }
        groups[surface_key] = group
      end
      group.mutation_count = group.mutation_count + 1
      self._state.metrics.mutations_applied = self._state.metrics.mutations_applied + 1
      for _, category in ipairs(CATEGORIES) do
        if mutation.categories[category] then group.categories[category] = true end
      end
      for _, coordinates in ipairs(Geometry.regions_for_bounds(
        mutation.bounds,
        self._state.config.region_size
      )) do
        local affected = group.regions[coordinates.key]
        if not affected then
          affected = {
            key = coordinates.key,
            rx = coordinates.rx,
            ry = coordinates.ry,
            categories = {},
            removed_entities = {}
          }
          group.regions[coordinates.key] = affected
        end
        for _, category in ipairs(CATEGORIES) do
          if mutation.categories[category] then affected.categories[category] = true end
        end
        if mutation.remove_entity_key then
          affected.removed_entities[mutation.remove_entity_key] = true
        end
      end
    end
  end

  local report_surfaces = {}
  for _, group in pairs(groups) do
    local surface_state = self:_surface_state(group.surface_index)
    local assigned_revisions = {}
    for _, category in ipairs(CATEGORIES) do
      if group.categories[category] then
        surface_state.revisions[category] = surface_state.revisions[category] + 1
        assigned_revisions[category] = surface_state.revisions[category]
        self._state.metrics.revision_changes[category] =
          self._state.metrics.revision_changes[category] + 1
      end
    end

    local affected_regions = {}
    for _, affected in pairs(group.regions) do
      local region = self:_region(surface_state, affected.rx, affected.ry)
      self._state.metrics.regions_dirtied = self._state.metrics.regions_dirtied + 1
      for _, category in ipairs(CATEGORIES) do
        if affected.categories[category] then
          region.revisions[category] = assigned_revisions[category]
          region.dirty[category] = true
          self._state.metrics.dirty_regions_by_category[category] =
            self._state.metrics.dirty_regions_by_category[category] + 1
        end
      end
      region.removed_entities = region.removed_entities or {}
      for entity_key in pairs(affected.removed_entities) do
        region.removed_entities[entity_key] = true
      end
      affected_regions[#affected_regions + 1] = {
        key = region.key,
        revisions = copy_basic(region.revisions),
        categories = copy_basic(affected.categories)
      }
    end
    sorted_values_by_key(affected_regions)
    report_surfaces[#report_surfaces + 1] = {
      key = tostring(group.surface_index),
      surface_index = group.surface_index,
      mutation_count = group.mutation_count,
      categories = copy_basic(group.categories),
      revisions = copy_basic(surface_state.revisions),
      regions = affected_regions
    }
  end
  table.sort(report_surfaces, function(first, second)
    return first.surface_index < second.surface_index
  end)
  return {
    event_name = event_name,
    surfaces = report_surfaces
  }
end

function World:_reset_surface(surface_index, source)
  local surface_state = self:_surface_state(surface_index)
  local region_count = 0
  for _ in pairs(surface_state.regions) do region_count = region_count + 1 end
  self._state.metrics.regions_dirtied =
    self._state.metrics.regions_dirtied + region_count
  for _, category in ipairs(CATEGORIES) do
    surface_state.revisions[category] = surface_state.revisions[category] + 1
    surface_state.base_revisions[category] = surface_state.revisions[category]
    self._state.metrics.revision_changes[category] =
      self._state.metrics.revision_changes[category] + 1
    self._state.metrics.dirty_regions_by_category[category] =
      self._state.metrics.dirty_regions_by_category[category] + region_count
  end
  surface_state.regions = {}
  return {
    action = "clear",
    source = source,
    surface_index = surface_index,
    categories = {topology = true, motion = true, transient = true},
    revisions = copy_basic(surface_state.revisions),
    regions_dirtied = region_count
  }
end

function World:_apply_operations(operations)
  local reports = {}
  for _, operation in ipairs(operations) do
    if operation.action == "delete" then
      self._state.surfaces[tostring(operation.surface_index)] = nil
      reports[#reports + 1] = copy_basic(operation)
    elseif operation.action == "clear" then
      reports[#reports + 1] = self:_reset_surface(
        operation.surface_index,
        operation.source
      )
    else
      local surface_state = self:_surface_state(operation.surface_index)
      local surface = self:_surface(operation.surface_index)
      if surface then surface_state.surface_name = surface.name end
      reports[#reports + 1] = {
        action = operation.action,
        source = operation.source,
        surface_index = operation.surface_index,
        surface_name = surface_state.surface_name
      }
    end
  end
  return reports
end

function World:_cached_tile_class(surface_index, position)
  local surface_state = self._state.surfaces[tostring(surface_index)]
  if not surface_state then return nil end
  local rx, ry = Geometry.region_coordinates(position, self._state.config.region_size)
  local region = surface_state.regions[Geometry.region_key(rx, ry)]
  if not region or not region.scanned
      or region.dirty.topology or region.dirty.motion then return nil end
  local tile_position = Geometry.position(position)
  return copy_basic(region.tiles[
    math.floor(tile_position.x) .. "," .. math.floor(tile_position.y)
  ])
end

function World:_current_tile_class(surface_index, position)
  local surface = self:_surface(surface_index)
  if not surface then return nil end
  position = Geometry.position(position)
  local tile = surface.get_tile(math.floor(position.x), math.floor(position.y))
  return self:_classify_tile_prototype(tile.prototype)
end

function World:handle_event(event_name, event)
  self._state.metrics.events_normalized = self._state.metrics.events_normalized + 1
  local normalized = Events.normalize(event_name, event, {
    classify_entity = function(entity) return self:_classify_entity(entity) end,
    classify_tile_prototype = function(prototype)
      return self:_classify_tile_prototype(prototype)
    end,
    classify_tile_name = function(name)
      return self:_classify_tile_prototype(self:_tile_prototype(name))
    end,
    cached_tile_class = function(surface_index, position)
      return self:_cached_tile_class(surface_index, position)
    end,
    current_tile_class = function(surface_index, position)
      return self:_current_tile_class(surface_index, position)
    end
  })
  local report = self:_apply_mutations(normalized.mutations, event_name)
  report.operations = self:_apply_operations(normalized.operations)
  report.unsupported = normalized.unsupported
  self._state.last_event_report = copy_basic(report)
  return report
end

local function persistent_entity(classification)
  return classification.topology
    or classification.motion
    or classification.transition
end

local function entity_snapshot(classification)
  return copy_basic({
    key = classification.key,
    name = classification.name,
    type = classification.type,
    unit_number = classification.unit_number,
    position = classification.position,
    bounds = classification.bounds,
    direction = classification.direction,
    mirrored = classification.mirrored,
    blocking = classification.blocking,
    topology = classification.topology,
    transient = classification.transient,
    motion = classification.motion,
    transition = classification.transition,
    dependency = classification.dependency
  })
end

local function tile_snapshot(classification, position)
  return copy_basic({
    name = classification.name,
    position = position,
    blocking = classification.blocking,
    walking_speed_modifier = classification.walking_speed_modifier,
    motion = classification.motion
  })
end

function World:_refresh_region(surface_state, region)
  local surface = self:_surface(surface_state.surface_index)
  if not surface or surface.valid == false then return false end
  local bounds = Geometry.region_bounds(
    region.rx,
    region.ry,
    self._state.config.region_size
  )
  local entities = {}
  local removed_entities = region.removed_entities or {}
  local found_entities = surface.find_entities_filtered({area = bounds})
  for _, entity in ipairs(found_entities) do
    local classification = self:_classify_entity(entity)
    if classification and persistent_entity(classification)
        and not removed_entities[classification.key] then
      entities[classification.key] = entity_snapshot(classification)
    end
  end

  local tiles = {}
  local min_x = math.floor(bounds.left_top.x)
  local min_y = math.floor(bounds.left_top.y)
  local max_x = math.ceil(bounds.right_bottom.x) - 1
  local max_y = math.ceil(bounds.right_bottom.y) - 1
  local cells_rescanned = 0
  for x = min_x, max_x do
    for y = min_y, max_y do
      local tile = surface.get_tile(x, y)
      tiles[x .. "," .. y] = tile_snapshot(
        self:_classify_tile_prototype(tile.prototype),
        {x = x, y = y}
      )
      cells_rescanned = cells_rescanned + 1
    end
  end

  region.entities = entities
  region.removed_entities = {}
  region.tiles = tiles
  region.scanned = true
  region.dirty = {topology = false, motion = false, transient = false}
  self._state.metrics.region_rescans = self._state.metrics.region_rescans + 1
  self._state.metrics.cells_rescanned =
    self._state.metrics.cells_rescanned + cells_rescanned
  self._state.metrics.entities_rescanned =
    self._state.metrics.entities_rescanned + #found_entities
  return true
end

function World:_region_for_position(surface_index, position, refresh)
  local surface_state = self:_surface_state(surface_index)
  local rx, ry = Geometry.region_coordinates(position, self._state.config.region_size)
  local region = self:_region(surface_state, rx, ry)
  if refresh and (not region.scanned
      or region.dirty.topology or region.dirty.motion) then
    self:_refresh_region(surface_state, region)
  end
  return surface_state, region
end

function World:_regions_for_bounds(surface_index, bounds, refresh)
  local surface_state = self:_surface_state(surface_index)
  local regions = {}
  for _, coordinates in ipairs(Geometry.regions_for_bounds(
    bounds,
    self._state.config.region_size
  )) do
    local region = self:_region(surface_state, coordinates.rx, coordinates.ry)
    if refresh and (not region.scanned
        or region.dirty.topology or region.dirty.motion) then
      self:_refresh_region(surface_state, region)
    end
    regions[#regions + 1] = region
  end
  sorted_values_by_key(regions)
  return surface_state, regions
end

local function ignore_entity(entity, options)
  return options and options.ignore_unit_number
    and entity.unit_number == options.ignore_unit_number
end

function World:query(surface_index, position, options)
  options = options or {}
  position = Geometry.position(position)
  local actor_collision_box = options.actor_collision_box
    or self._runtime.actor_collision_box
  assert(actor_collision_box,
    "NavigationWorld query requires an actor_collision_box")
  local actor_bounds = Geometry.place_bounds(position, actor_collision_box)
  local surface_state, regions = self:_regions_for_bounds(
    surface_index,
    actor_bounds,
    true
  )
  local center_rx, center_ry = Geometry.region_coordinates(
    position,
    self._state.config.region_size
  )
  local center_key = Geometry.region_key(center_rx, center_ry)
  local center_region
  for _, region in ipairs(regions) do
    if region.key == center_key then center_region = region end
  end
  assert(center_region, "NavigationWorld query did not resolve its center region")
  local tile_key = math.floor(position.x) .. "," .. math.floor(position.y)
  local tile = center_region.tiles[tile_key]
  local occupancy = {}
  local transitions = {}
  local motion = {}
  local dependencies = {}
  local region_revisions = {}
  local entities_by_key = {}
  local traversable = true

  if tile and tile.motion then
    motion[#motion + 1] = copy_basic(tile.motion)
  end
  for _, region in ipairs(regions) do
    dependencies[#dependencies + 1] = {
      kind = "navigation-region",
      surface_index = surface_index,
      region_key = region.key,
      revisions = copy_basic(region.revisions)
    }
    region_revisions[#region_revisions + 1] = {
      key = region.key,
      revisions = copy_basic(region.revisions)
    }
    for _, candidate_tile in pairs(region.tiles) do
      if candidate_tile.blocking and Geometry.intersects(
        Geometry.tile_bounds(candidate_tile.position),
        actor_bounds
      ) then
        traversable = false
      end
    end
    for key, entity in pairs(region.entities) do
      if not entities_by_key[key]
          and Geometry.intersects(entity.bounds, actor_bounds)
          and not ignore_entity(entity, options) then
        entities_by_key[key] = entity
      end
    end
  end
  for _, entity in pairs(entities_by_key) do
    occupancy[#occupancy + 1] = copy_basic(entity)
  end
  table.sort(occupancy, function(first, second) return first.key < second.key end)
  for _, entity in ipairs(occupancy) do
    dependencies[#dependencies + 1] = copy_basic(entity.dependency)
    if entity.transition then
      transitions[#transitions + 1] = copy_basic(entity.transition)
      if not entity.transition.traversable then traversable = false end
    elseif entity.blocking then
      traversable = false
    end
    if entity.motion and Geometry.contains(entity.bounds, position) then
      motion[#motion + 1] = copy_basic(entity.motion)
    end
  end

  return {
    surface_index = surface_index,
    position = position,
    actor_bounds = actor_bounds,
    traversability_kind = "actor-footprint",
    traversable = traversable,
    occupancy = occupancy,
    transitions = transitions,
    motion = motion,
    tile = copy_basic(tile),
    dependencies = dependencies,
    revisions = {
      surface = copy_basic(surface_state.revisions),
      region = copy_basic(center_region.revisions),
      regions = region_revisions
    }
  }
end

function World:is_traversable(surface_index, position, options)
  return self:query(surface_index, position, options).traversable
end

function World:occupancy(surface_index, position, options)
  return self:query(surface_index, position, options).occupancy
end

function World:conditional_transitions(surface_index, position, options)
  return self:query(surface_index, position, options).transitions
end

function World:observe_transients(surface_index, bounds, options)
  options = options or {}
  bounds = Geometry.copy_bounds(bounds)
  local surface = self:_surface(surface_index)
  assert(surface and surface.valid ~= false,
    "NavigationWorld transient observation surface is unavailable")
  local entities = {}
  for _, entity in ipairs(surface.find_entities_filtered({area = bounds})) do
    local classification = self:_classify_entity(entity)
    if classification and classification.transient
        and not ignore_entity(classification, options) then
      entities[#entities + 1] = entity_snapshot(classification)
    end
  end
  table.sort(entities, function(first, second) return first.key < second.key end)
  self._state.metrics.transient_observation_queries =
    self._state.metrics.transient_observation_queries + 1
  self._state.metrics.transient_entities_observed =
    self._state.metrics.transient_entities_observed + #entities
  return {
    surface_index = surface_index,
    bounds = bounds,
    entities = entities,
    revisions = self:revision_snapshot(surface_index, bounds)
  }
end

function World:directed_motion(surface_index, from, to, options)
  from = Geometry.position(from)
  to = Geometry.position(to)
  local positions = {
    {role = "from", position = from},
    {role = "midpoint", position = {x = (from.x + to.x) / 2, y = (from.y + to.y) / 2}},
    {role = "to", position = to}
  }
  local samples = {}
  local dependencies = {}
  local seen_dependencies = {}
  for _, sample in ipairs(positions) do
    local query = self:query(surface_index, sample.position, options)
    samples[#samples + 1] = {
      role = sample.role,
      position = sample.position,
      motion = query.motion
    }
    for _, dependency in ipairs(query.dependencies) do
      local key = dependency.kind .. ":"
        .. tostring(dependency.region_key or dependency.unit_number or dependency.name)
      if not seen_dependencies[key] then
        seen_dependencies[key] = true
        dependencies[#dependencies + 1] = dependency
      end
    end
  end
  return {
    surface_index = surface_index,
    from = from,
    to = to,
    travel_vector = {x = to.x - from.x, y = to.y - from.y},
    samples = samples,
    dependencies = dependencies
  }
end

function World:revision_snapshot(surface_index, bounds)
  local surface_state = self:_surface_state(surface_index)
  local regions = {}
  for _, coordinates in ipairs(Geometry.regions_for_bounds(
    bounds,
    self._state.config.region_size
  )) do
    local region = self:_region(surface_state, coordinates.rx, coordinates.ry)
    regions[#regions + 1] = {
      key = region.key,
      revisions = copy_basic(region.revisions)
    }
  end
  sorted_values_by_key(regions)
  return {
    surface_index = surface_index,
    surface = copy_basic(surface_state.revisions),
    regions = regions
  }
end

function World:region_dependencies(surface_index, bounds)
  local snapshot = self:revision_snapshot(surface_index, bounds)
  local dependencies = {}
  for _, region in ipairs(snapshot.regions) do
    dependencies[#dependencies + 1] = {
      kind = "navigation-region",
      surface_index = surface_index,
      region_key = region.key,
      revisions = copy_basic(region.revisions)
    }
  end
  return dependencies
end

function World:reconstruct(surface_indices)
  local indices = {}
  if surface_indices then
    for _, surface_index in ipairs(surface_indices) do indices[#indices + 1] = surface_index end
  else
    for _, surface_state in pairs(self._state.surfaces) do
      indices[#indices + 1] = surface_state.surface_index
    end
  end
  table.sort(indices)

  local report = {surface_count = 0, regions_rescanned = 0}
  for _, surface_index in ipairs(indices) do
    local surface_state = self:_surface_state(surface_index)
    local surface = self:_surface(surface_index)
    if surface and surface.valid ~= false then
      surface_state.surface_name = surface.name
      report.surface_count = report.surface_count + 1
      for _, region in pairs(surface_state.regions) do
        region.scanned = false
        region.dirty = {topology = true, motion = true, transient = true}
        if self:_refresh_region(surface_state, region) then
          report.regions_rescanned = report.regions_rescanned + 1
        end
      end
    end
  end
  self._state.metrics.reconstructions = self._state.metrics.reconstructions + 1
  return report
end

function World:event_bundle(defines_events)
  return Events.compose(defines_events, self)
end

function World:metrics()
  return copy_basic(self._state.metrics)
end

function World:last_event_report()
  return copy_basic(self._state.last_event_report)
end

function World:serialized_state()
  return self._state
end

NavigationWorld.SCHEMA_VERSION = SCHEMA_VERSION
NavigationWorld.DEFAULT_REGION_SIZE = DEFAULT_REGION_SIZE

return NavigationWorld
