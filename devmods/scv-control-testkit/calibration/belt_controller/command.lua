local Trajectory = require("__factorio-scv-control__/scripts/trajectory")
local Command = {}
local function copy(p) return {x = p.x, y = p.y} end
local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function position(value)
  return type(value) == "table" and finite(value.x) and finite(value.y)
end

-- A saved map owns the navigation task as well as the physical surface. New
-- defaults may change generated probes, but may not silently change a loaded
-- source's endpoint or allowed control corridor.
function Command.resolve(fixture, origin, distance, corridor_half_width, saved)
  if saved then
    if not position(saved.start) or not position(saved.goal)
        or not finite(saved.corridor_half_width) or saved.corridor_half_width <= 0
        or (saved.start.x == saved.goal.x and saved.start.y == saved.goal.y) then
      return nil, "invalid-saved-command"
    end
    if origin.x ~= saved.start.x or origin.y ~= saved.start.y then
      return nil, "saved-command-origin-mismatch"
    end
    return {start = copy(saved.start), goal = copy(saved.goal),
      corridor_half_width = saved.corridor_half_width, source = "saved-map-command"}
  end
  local axis = Trajectory.direction_vector(fixture.direction)
  return {start = copy(origin), goal = {x = origin.x + distance * axis.x, y = origin.y + distance * axis.y},
    corridor_half_width = corridor_half_width, source = "generated-probe-command"}
end

return Command
