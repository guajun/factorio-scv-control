local PathMath = require("scripts.path_math")
local Policy = require("scripts.navigation_policy")
local Trajectory = require("scripts.trajectory")

local Follower = {}

function Follower.stop(control)
  control.walking_state = {walking = false, direction = defines.direction.north}
end

function Follower.tolerance(control)
  return math.max(
    PathMath.MIN_WAYPOINT_DISTANCE,
    control.character_running_speed * PathMath.SPEED_DISTANCE_MULTIPLIER
  )
end

local function begin_waypoint_recovery(control, state)
  if state.recovery_waypoint_index == state.waypoint_index then
    state.recovery_attempts = (state.recovery_attempts or 0) + 1
  else
    state.recovery_waypoint_index = state.waypoint_index
    state.recovery_attempts = 1
  end
  if state.recovery_attempts > Policy.follower.max_waypoint_recoveries then return false end
  state.segment_start = PathMath.copy_position(control.position)
  state.trajectory = nil
  return true
end

local function clear_waypoint_recovery(state)
  state.recovery_waypoint_index = nil
  state.recovery_attempts = 0
end

function Follower.advance(control, state, goal)
  local tolerance = Follower.tolerance(control)
  local waypoint = state.path[state.waypoint_index]
  while waypoint do
    local is_final_waypoint = state.waypoint_index == #state.path
    local reached = PathMath.squared_distance(control.position, waypoint) <= tolerance * tolerance
    local passed = Trajectory.passed_waypoint(control.position, state.segment_start, waypoint)
    if is_final_waypoint then
      if reached then
        Follower.stop(control)
        return "arrived", {reason = "within-tolerance", waypoint_index = state.waypoint_index}
      elseif passed then
        local cross_track_error = math.abs(Trajectory.cross_track_error(
          control.position,
          state.segment_start,
          waypoint
        ))
        Follower.stop(control)
        if cross_track_error <= tolerance then
          return "arrived", {
            reason = "passed-final-plane",
            waypoint_index = state.waypoint_index,
            cross_track_error = cross_track_error
          }
        end
        if not begin_waypoint_recovery(control, state) then
          return "replan", {
            reason = "missed-final-plane",
            waypoint_index = state.waypoint_index,
            cross_track_error = cross_track_error
          }
        end
        break
      end
      break
    end
    if passed and not reached then
      local cross_track_error = math.abs(Trajectory.cross_track_error(
        control.position,
        state.segment_start,
        waypoint
      ))
      if cross_track_error > tolerance then
        if not begin_waypoint_recovery(control, state) then
          Follower.stop(control)
          return "replan", {
            reason = "missed-waypoint-plane",
            waypoint_index = state.waypoint_index,
            cross_track_error = cross_track_error
          }
        end
        break
      end
    elseif not reached then
      break
    end
    state.segment_start = PathMath.copy_position(waypoint)
    state.waypoint_index = state.waypoint_index + 1
    state.trajectory = nil
    clear_waypoint_recovery(state)
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

  local trajectory, direction, diagnostics = Trajectory.step(
    control.position,
    state.segment_start,
    waypoint,
    control.character_running_speed,
    state.trajectory
  )
  state.trajectory = trajectory
  control.walking_state = {
    walking = true,
    direction = direction
  }
  diagnostics.waypoint_index = state.waypoint_index
  diagnostics.recovery_attempt = state.recovery_attempts or 0
  diagnostics.position = PathMath.copy_position(control.position)
  diagnostics.waypoint = PathMath.copy_position(waypoint)
  return "moving", diagnostics
end

return Follower
