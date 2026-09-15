-- Bounded observations of an already existing native world. This module never
-- creates entities/tiles and never reads fixture geometry to manufacture facts.
local Canonical = require("__factorio-scv-control__/scripts/navigation/canonical")
local Facts = {PROTOCOL = "scv-save-facts/1"}
local MAX_TILES, MAX_ENTITIES = 65536, 4096
local BELTS = {['transport-belt'] = true, ['underground-belt'] = true,
  splitter = true, ['linked-belt'] = true, loader = true, ['loader-1x1'] = true}

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

local function point(value)
  return {x = value.x or value[1], y = value.y or value[2]}
end

local function box(value)
  return {left_top = point(value.left_top or value[1]),
    right_bottom = point(value.right_bottom or value[2])}
end

local function ordered(values)
  local encoded = {}
  for index, value in ipairs(values) do
    local key, err = Canonical.encode(value)
    assert(key, err and err.message)
    encoded[index] = {key = key, value = value}
  end
  table.sort(encoded, function(a, b) return a.key < b.key end)
  for index, item in ipairs(encoded) do values[index] = item.value end
  return values
end

local function mask(prototype)
  local result = {layers = {}}
  local value = prototype.collision_mask or {}
  for layer, enabled in pairs(value.layers or value) do
    if type(layer) == "string" and enabled == true then result.layers[#result.layers + 1] = layer end
  end
  table.sort(result.layers)
  -- These flags are part of the runtime collision mask connector itself.
  for _, name in ipairs({'not_colliding_with_itself', 'consider_tile_transitions', 'colliding_with_tiles_only'}) do
    result[name] = value[name] == true
  end
  return result
end

local function reference(entity)
  return {name = entity.name, type = entity.type, position = point(entity.position),
    force = entity.force.name, direction = entity.direction}
end

local function wall_control(entity)
  local control = entity.get_control_behavior()
  if not control then return {configured = false} end
  return {configured = true, open_gate = control.open_gate, read_sensor = control.read_sensor,
    circuit_condition = copy(control.circuit_condition or {})}
end

local function gate_state(entity)
  if entity.is_opened() then return 'opened' end
  if entity.is_opening() then return 'opening' end
  if entity.is_closed() then return 'closed' end
  if entity.is_closing() then return 'closing' end
  return 'unknown'
end

local function entity_facts(entity, actor)
  local result = reference(entity)
  result.bounding_box = box(entity.bounding_box)
  result.prototype_collision_box = box(entity.prototype.collision_box)
  result.collision_mask = mask(entity.prototype)
  result.orientation = entity.orientation
  result.destructible = entity.destructible
  result.minable = entity.minable
  result.quality = entity.quality.name
  result.force_relation = {same = entity.force == actor.force,
    friend = actor.force.get_friend(entity.force), cease_fire = actor.force.get_cease_fire(entity.force)}
  if entity.type == 'wall' then result.wall_control = wall_control(entity) end
  if entity.type == 'gate' then
    local neighbours = {}
    for _, neighbour in pairs(entity.neighbours or {}) do
      if neighbour.valid and neighbour ~= entity then
        local item = reference(neighbour)
        if neighbour.type == 'wall' then item.wall_control = wall_control(neighbour) end
        neighbours[#neighbours + 1] = item
      end
    end
    result.gate = {state = gate_state(entity), neighbours = ordered(neighbours),
      opening_progress = 'unavailable-in-runtime-2.0.77',
      opened_collision_mask = 'unavailable-in-runtime-2.0.77'}
  end
  if BELTS[entity.type] then
    result.belt = {speed = entity.prototype.belt_speed}
    if entity.type == 'transport-belt' then result.belt.shape = entity.belt_shape end
    if entity.type == 'underground-belt' then result.belt.endpoint_type = entity.belt_to_ground_type end
    if entity.type == 'linked-belt' then result.belt.endpoint_type = entity.linked_belt_type end
  end
  return result
end

local function actor_facts(actor)
  local equipment, armor = {}, {}
  local inventory = actor.get_inventory(defines.inventory.character_armor)
  if inventory then
    for index = 1, #inventory do
      local stack = inventory[index]
      if stack.valid_for_read then armor[#armor + 1] = {name = stack.name, quality = stack.quality.name} end
    end
  end
  local grid = actor.grid
  if grid then
    for _, item in pairs(grid.equipment) do
      equipment[#equipment + 1] = {name = item.name, position = point(item.position),
        energy = item.energy, movement_bonus = item.movement_bonus, quality = item.quality.name}
    end
  end
  return {name = actor.name, type = actor.type, force = actor.force.name,
    prototype_collision_box = box(actor.prototype.collision_box), collision_mask = mask(actor.prototype),
    running_speed = actor.character_running_speed,
    running_speed_modifier = actor.character_running_speed_modifier,
    prototype_running_speed = actor.prototype.running_speed,
    prototype_belt_immunity = actor.prototype.has_belt_immunity,
    armor = ordered(armor), equipment = ordered(equipment),
    equipment_scope = #armor == 0 and #equipment == 0 and 'unarmored-native-character-v1'
      or 'captured-equipment-unvalidated',
    movement_bonus_inhibited = grid and grid.inhibit_movement_bonus or false}
end

local function capture(surface, actor, input_bounds, metadata)
  assert(surface and surface.valid, 'A live surface is required.')
  assert(actor and actor.valid and actor.type == 'character' and actor.surface == surface,
    'A live character on the captured surface is required.')
  local bounds = box(input_bounds)
  for _, p in pairs(bounds) do
    assert(type(p.x) == 'number' and type(p.y) == 'number' and p.x % 1 == 0 and p.y % 1 == 0
      and math.abs(p.x) <= 1000000 and math.abs(p.y) <= 1000000, 'Bounds must use finite integer tile edges.')
  end
  local width, height = bounds.right_bottom.x - bounds.left_top.x, bounds.right_bottom.y - bounds.left_top.y
  assert(width > 0 and height > 0 and width * height <= MAX_TILES, 'Captured area exceeds tile bound.')
  for x = math.floor(bounds.left_top.x / 32), math.floor((bounds.right_bottom.x - 1) / 32) do
    for y = math.floor(bounds.left_top.y / 32), math.floor((bounds.right_bottom.y - 1) / 32) do
      assert(surface.is_chunk_generated({x, y}), 'Cannot certify facts for an ungenerated chunk.')
    end
  end
  assert(type(metadata) == 'table', 'Case metadata is required.')
  local identity = {}
  for _, key in ipairs({'case_id', 'domain', 'fixture_version', 'start', 'goal', 'scenario', 'scope'}) do
    if metadata[key] ~= nil then identity[key] = copy(metadata[key]) end
  end
  identity.state_key = metadata.state_key or 'baseline'
  assert(type(identity.case_id) == 'string' and type(identity.domain) == 'string'
    and type(identity.fixture_version) == 'number' and type(identity.goal) == 'table', 'Incomplete case metadata.')
  identity.goal = point(identity.goal)
  if identity.start then identity.start = point(identity.start) end
  local tiles = {}
  for y = bounds.left_top.y, bounds.right_bottom.y - 1 do
    for x = bounds.left_top.x, bounds.right_bottom.x - 1 do
      local tile = surface.get_tile(x, y)
      tiles[#tiles + 1] = {position = {x = x, y = y}, name = tile.name,
        collision_mask = mask(tile.prototype), walking_speed_modifier = tile.prototype.walking_speed_modifier,
        hidden_tile = tile.hidden_tile or false, double_hidden_tile = tile.double_hidden_tile or false}
    end
  end
  local entities = {}
  for _, entity in pairs(surface.find_entities_filtered({area = bounds})) do
    if entity.valid and entity.type ~= 'character' and entity.type ~= 'entity-ghost'
      and entity.type ~= 'tile-ghost' then
      local collides = #mask(entity.prototype).layers > 0
      if collides or BELTS[entity.type] or entity.type == 'gate' or entity.type == 'wall' then
        entities[#entities + 1] = entity_facts(entity, actor)
        assert(#entities <= MAX_ENTITIES, 'Captured entities exceed entity bound.')
      end
    end
  end
  local mods = {}
  for name, version in pairs(script.active_mods) do mods[#mods + 1] = {name = name, version = version} end
  local result = {protocol = Facts.PROTOCOL, metadata = identity,
    coverage = {bounds = bounds, outside = 'unknown', chunks = 'generated',
      tiles = 'all-tile-centres-in-half-open-bounds',
      entities = 'bounding-box-intersection-collision-or-gate-or-belt',
      exclusions = {'characters-other-than-actor-profile', 'entity-ghost', 'tile-ghost', 'noncolliding-nonmotion-entities'},
      gate_neighbours = 'observed-immediate-neighbours-including-outside-bounds',
      identity = 'semantic-state-not-entity-incarnation'},
    environment = {engine_version = script.active_mods.base, active_mods = ordered(mods), surface = surface.name},
    actor = actor_facts(actor), tiles = tiles, entities = ordered(entities)}
  local hash, err = Canonical.hash(result)
  assert(hash, err and err.message)
  result.facts_hash = hash
  return result
end

function Facts.capture(surface, actor, bounds, metadata)
  local ok, result = pcall(capture, surface, actor, bounds, metadata)
  if not ok then return nil, {code = 'save-facts-capture-failed', message = tostring(result)} end
  return result
end

return Facts
