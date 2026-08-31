local PathMath = require("scripts.path_math")
local PathSmoothing = require("scripts.path_smoothing")
local Policy = require("scripts.navigation_policy")

local NavigationGrid = {}

local function round(value)
  return math.floor(value + 0.5)
end

local function key(ix, iy)
  return ix .. "," .. iy
end

function NavigationGrid.capture(surface, character, bounds, resolution)
  local grid = {
    resolution = resolution,
    min_ix = math.ceil(bounds[1][1] / resolution),
    max_ix = math.floor(bounds[2][1] / resolution),
    min_iy = math.ceil(bounds[1][2] / resolution),
    max_iy = math.floor(bounds[2][2] / resolution),
    blocked = {},
    line_cache = {},
    sampled_nodes = 0,
    line_checks = 0,
    surface_line_checks = 0,
    exact_line_checks = false
  }

  function grid:contains(ix, iy)
    return ix >= self.min_ix and ix <= self.max_ix
      and iy >= self.min_iy and iy <= self.max_iy
  end

  function grid:position(ix, iy)
    return {x = ix * self.resolution, y = iy * self.resolution}
  end

  function grid:is_blocked(ix, iy)
    return not self:contains(ix, iy) or self.blocked[key(ix, iy)] == true
  end

  for ix = grid.min_ix, grid.max_ix do
    for iy = grid.min_iy, grid.max_iy do
      grid.sampled_nodes = grid.sampled_nodes + 1
      if not PathSmoothing.position_is_clear(surface, character, grid:position(ix, iy)) then
        grid.blocked[key(ix, iy)] = true
      end
    end
  end

  function grid:line_is_clear(first_ix, first_iy, second_ix, second_iy)
    local first_key = key(first_ix, first_iy)
    local second_key = key(second_ix, second_iy)
    local cache_key = first_key < second_key
      and first_key .. ":" .. second_key
      or second_key .. ":" .. first_key
    local cached = self.line_cache[cache_key]
    if cached ~= nil then return cached end

    self.line_checks = self.line_checks + 1
    local dx = second_ix - first_ix
    local dy = second_iy - first_iy
    local steps = math.max(math.abs(dx), math.abs(dy))
      * Policy.grid.line_samples_per_cell
    local clear = true
    for step = 0, steps do
      local ratio = steps == 0 and 0 or step / steps
      local ix = round(first_ix + dx * ratio)
      local iy = round(first_iy + dy * ratio)
      if self:is_blocked(ix, iy) then
        clear = false
        break
      end
    end
    if clear and self.exact_line_checks then
      self.surface_line_checks = self.surface_line_checks + 1
      clear = PathSmoothing.segment_is_clear(
        surface,
        character,
        self:position(first_ix, first_iy),
        self:position(second_ix, second_iy)
      )
    end
    self.line_cache[cache_key] = clear
    return clear
  end

  function grid:nearest_free(position)
    local center_ix = round(position.x / self.resolution)
    local center_iy = round(position.y / self.resolution)
    local best = nil
    local best_distance = math.huge
    local max_ring = math.max(2, math.ceil(2 / self.resolution))
    for ring = 0, max_ring do
      for ix = center_ix - ring, center_ix + ring do
        for iy = center_iy - ring, center_iy + ring do
          if math.max(math.abs(ix - center_ix), math.abs(iy - center_iy)) == ring
              and not self:is_blocked(ix, iy) then
            local node_position = self:position(ix, iy)
            local distance = PathMath.squared_distance(position, node_position)
            if distance < best_distance
                and PathSmoothing.segment_is_clear(surface, character, position, node_position) then
              best = {ix = ix, iy = iy}
              best_distance = distance
            end
          end
        end
      end
      if best then return best end
    end
    return nil
  end

  return grid
end

return NavigationGrid
