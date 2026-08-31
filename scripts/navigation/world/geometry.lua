local Geometry = {}

local EPSILON = 1e-9

local function coordinate(position, name, index)
  return position[name] or position[index]
end

function Geometry.position(position)
  return {
    x = coordinate(position, "x", 1),
    y = coordinate(position, "y", 2)
  }
end

function Geometry.bounds(bounds)
  local left_top = bounds.left_top or bounds[1]
  local right_bottom = bounds.right_bottom or bounds[2]
  return {
    left_top = Geometry.position(left_top),
    right_bottom = Geometry.position(right_bottom)
  }
end

function Geometry.copy_bounds(bounds)
  return Geometry.bounds(bounds)
end

function Geometry.point_bounds(position)
  local point = Geometry.position(position)
  return {
    left_top = {x = point.x, y = point.y},
    right_bottom = {x = point.x + EPSILON, y = point.y + EPSILON}
  }
end

function Geometry.tile_bounds(position)
  local tile = Geometry.position(position)
  return {
    left_top = {x = tile.x, y = tile.y},
    right_bottom = {x = tile.x + 1, y = tile.y + 1}
  }
end

function Geometry.chunk_bounds(position)
  local chunk = Geometry.position(position)
  return {
    left_top = {x = chunk.x * 32, y = chunk.y * 32},
    right_bottom = {x = (chunk.x + 1) * 32, y = (chunk.y + 1) * 32}
  }
end

function Geometry.union(first, second)
  if not first then return Geometry.copy_bounds(second) end
  if not second then return Geometry.copy_bounds(first) end
  first = Geometry.bounds(first)
  second = Geometry.bounds(second)
  return {
    left_top = {
      x = math.min(first.left_top.x, second.left_top.x),
      y = math.min(first.left_top.y, second.left_top.y)
    },
    right_bottom = {
      x = math.max(first.right_bottom.x, second.right_bottom.x),
      y = math.max(first.right_bottom.y, second.right_bottom.y)
    }
  }
end

function Geometry.translate(bounds, offset)
  bounds = Geometry.bounds(bounds)
  offset = Geometry.position(offset)
  return {
    left_top = {
      x = bounds.left_top.x + offset.x,
      y = bounds.left_top.y + offset.y
    },
    right_bottom = {
      x = bounds.right_bottom.x + offset.x,
      y = bounds.right_bottom.y + offset.y
    }
  }
end

function Geometry.place_bounds(position, relative_bounds)
  return Geometry.translate(relative_bounds, position)
end

function Geometry.intersects(first, second)
  first = Geometry.bounds(first)
  second = Geometry.bounds(second)
  return first.left_top.x < second.right_bottom.x
    and first.right_bottom.x > second.left_top.x
    and first.left_top.y < second.right_bottom.y
    and first.right_bottom.y > second.left_top.y
end

function Geometry.orientation_envelope(position, prototype_bounds)
  position = Geometry.position(position)
  prototype_bounds = Geometry.bounds(prototype_bounds)
  local radius = math.max(
    math.abs(prototype_bounds.left_top.x),
    math.abs(prototype_bounds.left_top.y),
    math.abs(prototype_bounds.right_bottom.x),
    math.abs(prototype_bounds.right_bottom.y)
  )
  return {
    left_top = {x = position.x - radius, y = position.y - radius},
    right_bottom = {x = position.x + radius, y = position.y + radius}
  }
end

function Geometry.region_key(rx, ry)
  return rx .. "," .. ry
end

function Geometry.region_coordinates(position, region_size)
  position = Geometry.position(position)
  return math.floor(position.x / region_size), math.floor(position.y / region_size)
end

function Geometry.region_bounds(rx, ry, region_size)
  return {
    left_top = {x = rx * region_size, y = ry * region_size},
    right_bottom = {x = (rx + 1) * region_size, y = (ry + 1) * region_size}
  }
end

function Geometry.regions_for_bounds(bounds, region_size)
  bounds = Geometry.bounds(bounds)
  local min_rx = math.floor(bounds.left_top.x / region_size)
  local min_ry = math.floor(bounds.left_top.y / region_size)
  local max_x = math.max(bounds.left_top.x, bounds.right_bottom.x - EPSILON)
  local max_y = math.max(bounds.left_top.y, bounds.right_bottom.y - EPSILON)
  local max_rx = math.floor(max_x / region_size)
  local max_ry = math.floor(max_y / region_size)
  local regions = {}
  for rx = min_rx, max_rx do
    for ry = min_ry, max_ry do
      regions[#regions + 1] = {
        key = Geometry.region_key(rx, ry),
        rx = rx,
        ry = ry
      }
    end
  end
  return regions
end

function Geometry.contains(bounds, position)
  bounds = Geometry.bounds(bounds)
  position = Geometry.position(position)
  return position.x >= bounds.left_top.x
    and position.y >= bounds.left_top.y
    and position.x <= bounds.right_bottom.x
    and position.y <= bounds.right_bottom.y
end

function Geometry.offset_for_position(bounds, current_position, target_position)
  current_position = Geometry.position(current_position)
  target_position = Geometry.position(target_position)
  return Geometry.translate(bounds, {
    x = target_position.x - current_position.x,
    y = target_position.y - current_position.y
  })
end

return Geometry
