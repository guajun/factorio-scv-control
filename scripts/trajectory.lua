local PathMath = require("scripts.path_math")

local Trajectory = {}
local PRIMITIVE_COUNT = 8
local TWO_PI = 2 * math.pi
local MIN_CROSS_TRACK_BAND = 0.15
local SPEED_BAND_MULTIPLIER = 1.25
local CLEARANCE_SPEED_MULTIPLIER = 0.5
local CLEARANCE_PADDING = 0.05

local function primitive_vector(primitive)
  local angle = primitive * TWO_PI / PRIMITIVE_COUNT
  return {x = math.sin(angle), y = -math.cos(angle)}
end

function Trajectory.direction_vector(direction)
  local primitive = math.floor((direction % 16) / 2 + 0.5) % PRIMITIVE_COUNT
  return primitive_vector(primitive)
end

function Trajectory.cross_track_band(speed)
  return math.max(MIN_CROSS_TRACK_BAND, speed * SPEED_BAND_MULTIPLIER)
end

function Trajectory.clearance_margin(speed)
  return Trajectory.cross_track_band(speed)
    + speed * CLEARANCE_SPEED_MULTIPLIER
    + CLEARANCE_PADDING
end

local function segment_frame(from, to)
  local dx = to.x - from.x
  local dy = to.y - from.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length <= 0.000001 then return nil end

  local along = {x = dx / length, y = dy / length}
  local normal = {x = -along.y, y = along.x}
  local orientation = math.atan2(dx, -dy) / TWO_PI % 1
  local scaled_direction = orientation * PRIMITIVE_COUNT
  local lower = math.floor(scaled_direction) % PRIMITIVE_COUNT
  local fraction = scaled_direction - math.floor(scaled_direction)
  local upper = fraction <= 0.000001
    and lower
    or (lower + 1) % PRIMITIVE_COUNT
  return {
    along = along,
    normal = normal,
    length = length,
    orientation = orientation,
    lower_primitive = lower,
    upper_primitive = upper,
    fraction = fraction
  }
end

local function dot(first, second)
  return first.x * second.x + first.y * second.y
end

function Trajectory.cross_track_error(position, from, to)
  local frame = segment_frame(from, to)
  if not frame then return 0 end
  return dot({x = position.x - from.x, y = position.y - from.y}, frame.normal)
end

function Trajectory.passed_waypoint(position, from, waypoint)
  local frame = segment_frame(from, waypoint)
  if not frame then return true end
  local relative = {x = position.x - waypoint.x, y = position.y - waypoint.y}
  return dot(relative, frame.along) >= 0
end

local function initial_direction(frame, cross_track_error, speed)
  if frame.lower_primitive == frame.upper_primitive then return frame.lower_primitive end
  local lower_vector = primitive_vector(frame.lower_primitive)
  local upper_vector = primitive_vector(frame.upper_primitive)
  local lower_error = math.abs(cross_track_error + speed * dot(lower_vector, frame.normal))
  local upper_error = math.abs(cross_track_error + speed * dot(upper_vector, frame.normal))
  if math.abs(lower_error - upper_error) <= 0.000001 then
    return frame.fraction <= 0.5 and frame.lower_primitive or frame.upper_primitive
  end
  return lower_error < upper_error and frame.lower_primitive or frame.upper_primitive
end

function Trajectory.step(position, from, to, speed, trajectory)
  local frame = segment_frame(from, to)
  if not frame then return trajectory or {}, defines.direction.north, {degenerate = true} end

  trajectory = trajectory or {
    current_primitive = nil,
    tick_count = 0,
    switch_count = 0,
    current_run_ticks = 0,
    min_run_ticks = nil,
    max_cross_track_error = 0
  }

  local cross_track_error = dot(
    {x = position.x - from.x, y = position.y - from.y},
    frame.normal
  )
  local band = Trajectory.cross_track_band(speed)
  local current = trajectory.current_primitive
  if current ~= frame.lower_primitive and current ~= frame.upper_primitive then
    current = initial_direction(frame, cross_track_error, speed)
  end

  local switched = trajectory.current_primitive ~= nil and current ~= trajectory.current_primitive
  if frame.lower_primitive ~= frame.upper_primitive and not switched then
    local current_vector = primitive_vector(current)
    local predicted_error = cross_track_error + speed * dot(current_vector, frame.normal)
    local moving_toward_center = math.abs(predicted_error) + 0.000001 < math.abs(cross_track_error)
    if math.abs(predicted_error) > band and not moving_toward_center then
      current = current == frame.lower_primitive
        and frame.upper_primitive
        or frame.lower_primitive
      switched = current ~= trajectory.current_primitive
    end
  end

  if trajectory.current_primitive == nil then
    trajectory.current_run_ticks = 1
  elseif switched then
    if trajectory.current_run_ticks > 0 then
      trajectory.min_run_ticks = trajectory.min_run_ticks
        and math.min(trajectory.min_run_ticks, trajectory.current_run_ticks)
        or trajectory.current_run_ticks
    end
    trajectory.switch_count = trajectory.switch_count + 1
    trajectory.current_run_ticks = 1
  else
    trajectory.current_run_ticks = trajectory.current_run_ticks + 1
  end

  trajectory.current_primitive = current
  trajectory.tick_count = trajectory.tick_count + 1
  trajectory.max_cross_track_error = math.max(
    trajectory.max_cross_track_error,
    math.abs(cross_track_error)
  )

  local selected_vector = primitive_vector(current)
  local predicted_error = cross_track_error + speed * dot(selected_vector, frame.normal)
  local selected_direction = current * 2
  return trajectory, selected_direction, {
    desired_orientation = frame.orientation,
    lower_direction = frame.lower_primitive * 2,
    upper_direction = frame.upper_primitive * 2,
    selected_direction = selected_direction,
    selected_primitive = current,
    switched = switched,
    cross_track_error = cross_track_error,
    predicted_cross_track_error = predicted_error,
    cross_track_band = band,
    switch_count = trajectory.switch_count,
    current_run_ticks = trajectory.current_run_ticks,
    min_run_ticks = trajectory.min_run_ticks,
    max_cross_track_error = trajectory.max_cross_track_error,
    distance_to_waypoint = PathMath.distance(position, to)
  }
end

return Trajectory
