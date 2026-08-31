local Geometry = require("scripts.navigation.world.geometry")

local Classification = {}

local MOTION_ENTITY_TYPES = {
  ["linked-belt"] = true,
  ["loader"] = true,
  ["loader-1x1"] = true,
  ["splitter"] = true,
  ["transport-belt"] = true,
  ["underground-belt"] = true
}

local TRANSIENT_ENTITY_TYPES = {
  ["car"] = true,
  ["character"] = true,
  ["combat-robot"] = true,
  ["construction-robot"] = true,
  ["logistic-robot"] = true,
  ["spider-vehicle"] = true,
  ["unit"] = true
}

local function each_collision_layer(mask, callback)
  if not mask then return end
  local layers = mask.layers or mask
  for key, value in pairs(layers) do
    if type(key) == "number" then
      callback(value)
    elseif value then
      callback(key)
    end
  end
end

local function collision_layers(mask)
  local layers = {}
  each_collision_layer(mask, function(layer)
    layers[layer] = true
  end)
  return layers
end

local function masks_intersect(first, second)
  if not first then return false end
  if not second then
    local found = false
    each_collision_layer(first, function() found = true end)
    return found
  end
  local second_layers = collision_layers(second)
  local intersects = false
  each_collision_layer(first, function(layer)
    if second_layers[layer] then intersects = true end
  end)
  return intersects
end

local function copy_position(position)
  return Geometry.position(position)
end

local function basic_equal(first, second)
  if type(first) ~= type(second) then return false end
  if type(first) ~= "table" then return first == second end
  for key, value in pairs(first) do
    if not basic_equal(value, second[key]) then return false end
  end
  for key in pairs(second) do
    if first[key] == nil then return false end
  end
  return true
end

local function apply_extensions(classification, value, extensions)
  if not extensions then return end
  for _, extension in ipairs(extensions) do
    local override = extension(value, classification)
    if override then
      for key, result in pairs(override) do
        classification[key] = result
      end
    end
  end
end

local function entity_dependency(entity)
  return {
    kind = "entity",
    name = entity.name,
    unit_number = entity.unit_number
  }
end

function Classification.entity(entity, runtime)
  runtime = runtime or {}
  if not entity or entity.valid == false then return nil end

  local transient = TRANSIENT_ENTITY_TYPES[entity.type] == true
  local blocks_actor = masks_intersect(
    entity.prototype.collision_mask,
    runtime.actor_collision_mask
  )
  local classification = {
    key = entity.unit_number and ("unit:" .. entity.unit_number)
      or (entity.type .. ":" .. entity.name .. ":"
        .. entity.position.x .. "," .. entity.position.y),
    name = entity.name,
    type = entity.type,
    unit_number = entity.unit_number,
    position = copy_position(entity.position),
    bounds = Geometry.copy_bounds(entity.bounding_box),
    direction = entity.direction,
    mirrored = entity.mirroring == true,
    blocking = blocks_actor and not transient,
    topology = blocks_actor and not transient,
    transient = transient,
    dependency = entity_dependency(entity)
  }

  if MOTION_ENTITY_TYPES[entity.type] then
    classification.motion = {
      kind = "directed-entity",
      direction = entity.direction,
      entity_name = entity.name,
      entity_type = entity.type,
      prototype_belt_speed = entity.prototype.belt_speed
    }
  end

  apply_extensions(classification, entity, runtime.entity_classifiers)
  if classification.transition then
    classification.topology = true
    if classification.transition.traversable then classification.blocking = false end
  end
  return classification
end

function Classification.tile(prototype, runtime)
  runtime = runtime or {}
  if not prototype then return nil end
  local speed = prototype.walking_speed_modifier or 1
  local classification = {
    name = prototype.name,
    blocking = masks_intersect(prototype.collision_mask, runtime.actor_collision_mask),
    walking_speed_modifier = speed
  }
  if speed ~= 1 then
    classification.motion = {
      kind = "walking-speed",
      multiplier = speed,
      tile_name = prototype.name
    }
  end
  apply_extensions(classification, prototype, runtime.tile_classifiers)
  return classification
end

function Classification.categories(entity_classification)
  local categories = {}
  if entity_classification then
    if entity_classification.topology then categories.topology = true end
    if entity_classification.motion then categories.motion = true end
    if entity_classification.transient then categories.transient = true end
  end
  return categories
end

function Classification.tile_change(old_classification, new_classification)
  if not old_classification or not new_classification then
    return {topology = true, motion = true}
  end
  local categories = {}
  if old_classification.blocking ~= new_classification.blocking then
    categories.topology = true
  end
  if old_classification.walking_speed_modifier
      ~= new_classification.walking_speed_modifier
      or not basic_equal(old_classification.motion, new_classification.motion) then
    categories.motion = true
  end
  return categories
end

return Classification
