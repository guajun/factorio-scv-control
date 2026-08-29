local PathMath = require("scripts.path_math")

local PathSmoothing = {}
local SAMPLE_DISTANCE = 0.25
local MAX_LOOKAHEAD_WAYPOINTS = 96

local function translated_collision_box(character, position)
  local box = character.prototype.collision_box
  return {
    left_top = {
      x = position.x + box.left_top.x,
      y = position.y + box.left_top.y
    },
    right_bottom = {
      x = position.x + box.right_bottom.x,
      y = position.y + box.right_bottom.y
    }
  }
end

local function masks_collide(first, second)
  if not first or not second then return false end
  for layer in pairs(first.layers) do
    if second.layers[layer] then return true end
  end
  return false
end

local function position_is_clear(surface, character, position)
  local area = translated_collision_box(character, position)
  local character_mask = character.prototype.collision_mask
  for _, entity in pairs(surface.find_entities(area)) do
    if entity ~= character
        and entity.valid
        and masks_collide(character_mask, entity.prototype.collision_mask) then
      return false
    end
  end
  for _, tile in pairs(surface.find_tiles_filtered({area = area})) do
    if masks_collide(character_mask, tile.prototype.collision_mask) then
      return false
    end
  end
  return true
end

local function segment_is_clear(surface, character, from, to)
  local length = PathMath.distance(from, to)
  if length <= 0.000001 then return true end

  local samples = math.max(1, math.ceil(length / SAMPLE_DISTANCE))
  for index = 1, samples do
    local ratio = index / samples
    local position = {
      x = from.x + (to.x - from.x) * ratio,
      y = from.y + (to.y - from.y) * ratio
    }
    if not position_is_clear(surface, character, position) then
      return false
    end
  end
  return true
end

function PathSmoothing.simplify(surface, character, engine_path, exact_goal)
  local points = {}
  for _, point in ipairs(engine_path) do
    PathMath.append_unique_point(points, point)
  end

  if exact_goal then
    local last = points[#points]
    if not last then
      points[1] = PathMath.copy_position(character.position)
      last = points[1]
    end
    if segment_is_clear(surface, character, last, exact_goal) then
      PathMath.append_unique_point(points, exact_goal)
    end
  end

  if #points <= 2 then return points end

  local simplified = {PathMath.copy_position(points[1])}
  local anchor = 1
  while anchor < #points do
    local next_index = anchor + 1
    local farthest_candidate = math.min(#points, anchor + MAX_LOOKAHEAD_WAYPOINTS)
    for candidate = farthest_candidate, anchor + 1, -1 do
      if segment_is_clear(surface, character, points[anchor], points[candidate]) then
        next_index = candidate
        break
      end
    end
    PathMath.append_unique_point(simplified, points[next_index])
    anchor = next_index
  end
  return simplified
end

return PathSmoothing
