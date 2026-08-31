local GridSearch = require("scripts.grid_search")
local NavigationGrid = require("scripts.navigation_grid")
local PathMath = require("scripts.path_math")
local PathSmoothing = require("scripts.path_smoothing")
local Policy = require("scripts.navigation_policy")

local LocalPlanner = {}

local function search_bounds(character, start_position, goal_position, baseline_distance)
  local dx = goal_position.x - start_position.x
  local dy = goal_position.y - start_position.y
  local direct_distance = math.sqrt(dx * dx + dy * dy)
  local major_radius = math.max(baseline_distance, direct_distance) / 2
  local focus_radius = direct_distance / 2
  local minor_radius = math.sqrt(math.max(
    0,
    major_radius * major_radius - focus_radius * focus_radius
  ))
  local unit_x = direct_distance > Policy.diagnostics.position_epsilon
    and dx / direct_distance
    or 1
  local unit_y = direct_distance > Policy.diagnostics.position_epsilon
    and dy / direct_distance
    or 0
  local extent_x = math.sqrt(
    major_radius * major_radius * unit_x * unit_x
      + minor_radius * minor_radius * unit_y * unit_y
  )
  local extent_y = math.sqrt(
    major_radius * major_radius * unit_y * unit_y
      + minor_radius * minor_radius * unit_x * unit_x
  )
  local center_x = (start_position.x + goal_position.x) / 2
  local center_y = (start_position.y + goal_position.y) / 2
  local base_resolution = Policy.grid.resolution
  local padding = PathSmoothing.clearance_margin(character) + base_resolution * 2
  local bounds = {
    min_x = math.floor(center_x - extent_x - padding),
    max_x = math.ceil(center_x + extent_x + padding),
    min_y = math.floor(center_y - extent_y - padding),
    max_y = math.ceil(center_y + extent_y + padding)
  }

  local width = math.max(1, bounds.max_x - bounds.min_x)
  local height = math.max(1, bounds.max_y - bounds.min_y)
  local resolution = base_resolution
  local estimated_nodes = (width / resolution + 1) * (height / resolution + 1)
  if estimated_nodes > Policy.grid.max_local_nodes then
    local required = math.sqrt(width * height / Policy.grid.max_local_nodes)
    resolution = math.ceil(required / base_resolution) * base_resolution
  end
  return {
    area = {{bounds.min_x, bounds.min_y}, {bounds.max_x, bounds.max_y}},
    resolution = resolution
  }
end

function LocalPlanner.compare(
    surface,
    character,
    start_position,
    goal_position,
    baseline_path,
    additional_candidates
)
  local baseline_distance = PathMath.polyline_distance(start_position, baseline_path)
  local baseline_safe = PathSmoothing.path_is_clear(
    surface,
    character,
    start_position,
    baseline_path
  )
  local bounds = search_bounds(character, start_position, goal_position, baseline_distance)
  local grid = NavigationGrid.capture(surface, character, bounds.area, bounds.resolution)
  local raw_path, metrics = GridSearch.search(
    grid,
    start_position,
    goal_position,
    {heuristic_weight = 1}
  )
  local grid_path = raw_path and PathSmoothing.simplify(
    surface,
    character,
    raw_path,
    goal_position
  ) or nil
  local grid_safe = grid_path and PathSmoothing.path_is_clear(
    surface,
    character,
    start_position,
    grid_path
  ) or false
  local grid_distance = grid_path and PathMath.polyline_distance(start_position, grid_path) or nil

  local selected_path = baseline_path
  local selected_source = "engine"
  local selected_distance = baseline_distance
  local selected_safe = baseline_safe
  local additional_results = {}
  for _, candidate in ipairs(additional_candidates or {}) do
    local safe = candidate.path and PathSmoothing.path_is_clear(
      surface,
      character,
      start_position,
      candidate.path
    ) or false
    local distance = candidate.path
      and PathMath.polyline_distance(start_position, candidate.path)
      or nil
    additional_results[#additional_results + 1] = {
      source = candidate.source,
      safe = safe,
      distance = distance,
      path = candidate.path
    }
    if safe and (not selected_safe or distance < selected_distance) then
      selected_path = candidate.path
      selected_source = candidate.source
      selected_distance = distance
      selected_safe = true
    end
  end
  if grid_safe and (not selected_safe or grid_distance < selected_distance) then
    selected_path = grid_path
    selected_source = "grid-a-star"
    selected_distance = grid_distance
    selected_safe = true
  end

  return {
    path = selected_path,
    source = selected_source,
    distance = selected_distance,
    baseline_safe = baseline_safe,
    baseline_distance = baseline_distance,
    additional_results = additional_results,
    grid_path = grid_path,
    grid_safe = grid_safe,
    grid_distance = grid_distance,
    grid_resolution = bounds.resolution,
    search_bounds = bounds.area,
    expanded_nodes = metrics.expanded_nodes,
    generated_nodes = metrics.generated_nodes,
    line_checks = metrics.line_checks,
    sampled_nodes = metrics.sampled_nodes
  }
end

return LocalPlanner
