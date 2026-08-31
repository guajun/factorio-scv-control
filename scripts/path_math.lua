local Policy = require("scripts.navigation_policy")

local PathMath = {}

PathMath.ARRIVAL_DISTANCE = Policy.path_request.arrival_radius
PathMath.MIN_WAYPOINT_DISTANCE = Policy.follower.min_waypoint_distance
PathMath.SPEED_DISTANCE_MULTIPLIER = Policy.follower.speed_distance_multiplier
PathMath.ALTERNATE_LATERAL_FRACTIONS = Policy.optimization.alternate_lateral_fractions

function PathMath.squared_distance(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

function PathMath.copy_position(position)
  return {x = position.x, y = position.y}
end

function PathMath.distance(a, b)
  return math.sqrt(PathMath.squared_distance(a, b))
end

function PathMath.polyline_distance(start_position, points)
  local total = 0
  local previous = start_position
  for _, point in ipairs(points) do
    total = total + PathMath.distance(previous, point)
    previous = point
  end
  return total
end

function PathMath.append_unique_point(points, point)
  local last = points[#points]
  if not last or PathMath.squared_distance(last, point) > Policy.diagnostics.position_epsilon then
    points[#points + 1] = PathMath.copy_position(point)
  end
end

function PathMath.path_from_event(event, exact_goal)
  local path = {}
  local logged_path = {}
  for _, waypoint in ipairs(event.path or {}) do
    PathMath.append_unique_point(path, waypoint.position)
    logged_path[#logged_path + 1] = {
      x = waypoint.position.x,
      y = waypoint.position.y,
      needs_destroy_to_reach = waypoint.needs_destroy_to_reach
    }
  end
  if exact_goal then
    PathMath.append_unique_point(path, exact_goal)
  end
  return path, logged_path
end

function PathMath.alternate_vias(surface, character_name, start_position, goal_position, baseline_path)
  local direct_x = goal_position.x - start_position.x
  local direct_y = goal_position.y - start_position.y
  local direct_length = math.sqrt(direct_x * direct_x + direct_y * direct_y)
  if direct_length < Policy.optimization.alternate_min_direct_distance then
    return {}
  end

  local perpendicular_x = -direct_y / direct_length
  local perpendicular_y = direct_x / direct_length
  local largest_signed_excursion = 0
  for _, point in ipairs(baseline_path) do
    local relative_x = point.x - start_position.x
    local relative_y = point.y - start_position.y
    local signed_excursion = relative_x * perpendicular_x + relative_y * perpendicular_y
    if math.abs(signed_excursion) > math.abs(largest_signed_excursion) then
      largest_signed_excursion = signed_excursion
    end
  end
  if math.abs(largest_signed_excursion) < Policy.optimization.alternate_min_excursion then
    return {}
  end

  local midpoint = {
    x = (start_position.x + goal_position.x) / 2,
    y = (start_position.y + goal_position.y) / 2
  }
  local vias = {}
  for _, fraction in ipairs(PathMath.ALTERNATE_LATERAL_FRACTIONS) do
    -- Probe the opposite side of the obstacle suggested by the baseline's largest lateral detour.
    local opposite_offset = -largest_signed_excursion * fraction
    local candidate = {
      x = midpoint.x + perpendicular_x * opposite_offset,
      y = midpoint.y + perpendicular_y * opposite_offset
    }
    local position = surface.find_non_colliding_position(
      character_name,
      candidate,
      Policy.optimization.alternate_snap_radius,
      Policy.optimization.alternate_snap_precision,
      false
    )
    if position then
      local duplicate = false
      for _, existing in ipairs(vias) do
        local dedup_distance = Policy.optimization.alternate_dedup_distance
        if PathMath.squared_distance(existing.position, position)
            < dedup_distance * dedup_distance then
          duplicate = true
          break
        end
      end
      if not duplicate then
        vias[#vias + 1] = {fraction = fraction, position = PathMath.copy_position(position)}
      end
    end
  end
  return vias
end

function PathMath.combine_paths(first, second)
  local combined = {}
  for _, point in ipairs(first) do
    PathMath.append_unique_point(combined, point)
  end
  for _, point in ipairs(second) do
    PathMath.append_unique_point(combined, point)
  end
  return combined
end

function PathMath.complete_alternate_candidate(start_position, candidate)
  if not candidate.segments
      or not candidate.segments[1]
      or not candidate.segments[2] then
    return false
  end

  candidate.path = PathMath.combine_paths(candidate.segments[1], candidate.segments[2])
  candidate.distance = PathMath.polyline_distance(start_position, candidate.path)
  return true
end

function PathMath.select_shortest_path(baseline_path, baseline_distance, candidates)
  local selected_path = baseline_path
  local selected_distance = baseline_distance
  local selected_candidate_index = nil
  for index, candidate in ipairs(candidates) do
    if candidate.distance
        and candidate.distance + Policy.optimization.selection_epsilon < selected_distance then
      selected_path = candidate.path
      selected_distance = candidate.distance
      selected_candidate_index = index
    end
  end
  return selected_path, selected_distance, selected_candidate_index
end

function PathMath.turn_metrics(points)
  local metrics = {
    corner_count = 0,
    max_turn_degrees = 0,
    reversal_count = 0,
    turns = {}
  }
  for index = 2, #points - 1 do
    local previous = points[index - 1]
    local current = points[index]
    local following = points[index + 1]
    local incoming_x = current.x - previous.x
    local incoming_y = current.y - previous.y
    local outgoing_x = following.x - current.x
    local outgoing_y = following.y - current.y
    local incoming_length = math.sqrt(incoming_x * incoming_x + incoming_y * incoming_y)
    local outgoing_length = math.sqrt(outgoing_x * outgoing_x + outgoing_y * outgoing_y)
    if incoming_length > Policy.diagnostics.position_epsilon
        and outgoing_length > Policy.diagnostics.position_epsilon then
      local cosine = (incoming_x * outgoing_x + incoming_y * outgoing_y)
        / (incoming_length * outgoing_length)
      cosine = math.max(-1, math.min(1, cosine))
      local angle = math.deg(math.acos(cosine))
      if angle > Policy.diagnostics.corner_degrees then
        metrics.corner_count = metrics.corner_count + 1
        metrics.max_turn_degrees = math.max(metrics.max_turn_degrees, angle)
        if angle > Policy.diagnostics.reversal_degrees then
          metrics.reversal_count = metrics.reversal_count + 1
        end
        metrics.turns[#metrics.turns + 1] = {
          index = index,
          position = PathMath.copy_position(current),
          degrees = angle
        }
      end
    end
  end
  return metrics
end

return PathMath
