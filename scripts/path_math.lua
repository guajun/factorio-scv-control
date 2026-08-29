local PathMath = {}

PathMath.ARRIVAL_DISTANCE = 0.25
PathMath.MIN_WAYPOINT_DISTANCE = 0.3
PathMath.SPEED_DISTANCE_MULTIPLIER = 1.5
PathMath.ALTERNATE_LATERAL_FRACTION = 0.75

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
  if not last or PathMath.squared_distance(last, point) > 0.000001 then
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
  PathMath.append_unique_point(path, exact_goal)
  return path, logged_path
end

function PathMath.alternate_via(surface, character_name, start_position, goal_position, baseline_path)
  local direct_x = goal_position.x - start_position.x
  local direct_y = goal_position.y - start_position.y
  local direct_length = math.sqrt(direct_x * direct_x + direct_y * direct_y)
  if direct_length < 1 then
    return nil
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
  if math.abs(largest_signed_excursion) < 2 then
    return nil
  end

  local midpoint = {
    x = (start_position.x + goal_position.x) / 2,
    y = (start_position.y + goal_position.y) / 2
  }
  -- Probe the opposite side of the obstacle suggested by the baseline's largest lateral detour.
  local opposite_offset = -largest_signed_excursion * PathMath.ALTERNATE_LATERAL_FRACTION
  local candidate = {
    x = midpoint.x + perpendicular_x * opposite_offset,
    y = midpoint.y + perpendicular_y * opposite_offset
  }
  return surface.find_non_colliding_position(character_name, candidate, 2, 0.25, false)
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

return PathMath
