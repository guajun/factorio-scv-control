local PathMath = require("scripts.path_math")

local Follower = {}

local function direction_towards(from, to)
  local dx = to.x - from.x
  local dy = to.y - from.y
  local orientation = math.atan2(dx, -dy) / (2 * math.pi) % 1
  return math.floor(orientation * 16 + 0.5) % 16
end

function Follower.stop(control)
  control.walking_state = {walking = false, direction = defines.direction.north}
end

function Follower.tolerance(control)
  return math.max(
    PathMath.MIN_WAYPOINT_DISTANCE,
    control.character_running_speed * PathMath.SPEED_DISTANCE_MULTIPLIER
  )
end

local function passed_waypoint(position, segment_start, waypoint)
  if not segment_start then return false end
  local segment_x = waypoint.x - segment_start.x
  local segment_y = waypoint.y - segment_start.y
  if segment_x == 0 and segment_y == 0 then return true end
  local beyond_x = position.x - waypoint.x
  local beyond_y = position.y - waypoint.y
  return beyond_x * segment_x + beyond_y * segment_y >= 0
end

function Follower.advance(control, state, goal)
  local tolerance = Follower.tolerance(control)
  local waypoint = state.path[state.waypoint_index]
  while waypoint do
    local is_final_waypoint = state.waypoint_index == #state.path
    local reached = PathMath.squared_distance(control.position, waypoint) <= tolerance * tolerance
    local passed = not is_final_waypoint
      and passed_waypoint(control.position, state.segment_start, waypoint)
    if not reached and not passed then break end
    state.segment_start = PathMath.copy_position(waypoint)
    state.waypoint_index = state.waypoint_index + 1
    waypoint = state.path[state.waypoint_index]
  end

  if not waypoint then
    local arrival_distance = math.max(PathMath.ARRIVAL_DISTANCE, tolerance)
    if PathMath.squared_distance(control.position, goal) <= arrival_distance * arrival_distance then
      Follower.stop(control)
      return "arrived"
    end
    Follower.stop(control)
    return "replan"
  end

  control.walking_state = {
    walking = true,
    direction = direction_towards(control.position, waypoint)
  }
  return "moving"
end

return Follower
