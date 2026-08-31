local GridSearch = require("__factorio-scv-control__/scripts/grid_search")
local NavigationGrid = require("__factorio-scv-control__/scripts/navigation_grid")
local PathMath = require("__factorio-scv-control__/scripts/path_math")
local PathSmoothing = require("__factorio-scv-control__/scripts/path_smoothing")
local Policy = require("__factorio-scv-control__/scripts/navigation_policy")

local Benchmark = {}
Benchmark.GRID_RESOLUTION = Policy.grid.resolution

Benchmark.ALGORITHMS = {
  "engine",
  "engine-alternate",
  "engine-alternate-global",
  "grid-a-star",
  "grid-weighted-a-star-2",
  "grid-theta-star",
  "grid-theta-star-exact"
}

local function algorithm_selected(state, algorithm)
  local selection = state.selected_algorithms
  if selection == nil then return true end
  if type(selection) == "string" then return selection == algorithm end
  return selection[algorithm] == true
end

local function copy_path(path)
  if not path then return nil end
  local copy = {}
  for _, point in ipairs(path) do copy[#copy + 1] = PathMath.copy_position(point) end
  return copy
end

local function path_result(surface, actor, fixture, algorithm, path, extra)
  extra = extra or {}
  if not path then
    return {
      algorithm = algorithm,
      status = extra.status or "no-path",
      expanded_nodes = extra.expanded_nodes,
      generated_nodes = extra.generated_nodes,
      reopened_nodes = extra.reopened_nodes,
      sampled_nodes = extra.sampled_nodes,
      line_checks = extra.line_checks,
      surface_line_checks = extra.surface_line_checks,
      request_count = extra.request_count or 0,
      duration_ticks = extra.duration_ticks or 0,
      optimization_status = extra.optimization_status
    }
  end

  local start = fixture.start
  local distance = PathMath.polyline_distance(start, path)
  local direct_distance = PathMath.distance(start, fixture.goal)
  return {
    algorithm = algorithm,
    status = "success",
    path = copy_path(path),
    distance = distance,
    direct_distance = direct_distance,
    detour_ratio = direct_distance > 0 and distance / direct_distance or 1,
    waypoint_count = #path,
    turns = PathMath.turn_metrics(path),
    actor_collision_safe = PathSmoothing.path_is_clear(surface, actor, start, path, 0),
    trajectory_clearance_safe = PathSmoothing.path_is_clear(surface, actor, start, path),
    raw_distance = extra.raw_distance,
    raw_waypoint_count = extra.raw_waypoint_count,
    expanded_nodes = extra.expanded_nodes,
    generated_nodes = extra.generated_nodes,
    reopened_nodes = extra.reopened_nodes,
    sampled_nodes = extra.sampled_nodes,
    line_checks = extra.line_checks,
    surface_line_checks = extra.surface_line_checks,
    request_count = extra.request_count or 0,
    duration_ticks = extra.duration_ticks or 0,
    optimization_status = extra.optimization_status,
    selected_candidate_index = extra.selected_candidate_index
  }
end

local function run_grid_algorithm(surface, actor, fixture, grid, algorithm, options)
  grid.line_cache = {}
  grid.line_checks = 0
  grid.surface_line_checks = 0
  grid.exact_line_checks = options.exact_line_checks == true
  local raw_path, metrics = GridSearch.search(grid, fixture.start, fixture.goal, options)
  local final_path = raw_path and PathSmoothing.simplify(
    surface,
    actor,
    raw_path,
    fixture.goal
  ) or nil
  metrics.raw_distance = raw_path and PathMath.polyline_distance(fixture.start, raw_path) or nil
  metrics.raw_waypoint_count = raw_path and #raw_path or nil
  return path_result(surface, actor, fixture, algorithm, final_path, metrics)
end

local function run_selected_grid_algorithms(state, grid)
  local specs = {
    ["grid-a-star"] = {heuristic_weight = 1},
    ["grid-weighted-a-star-2"] = {heuristic_weight = 2},
    ["grid-theta-star"] = {heuristic_weight = 1, any_angle = true},
    ["grid-theta-star-exact"] = {
      heuristic_weight = 1,
      any_angle = true,
      exact_line_checks = true
    }
  }
  for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
    local options = specs[algorithm]
    if options and algorithm_selected(state, algorithm) then
      state.results[algorithm] = run_grid_algorithm(
        state.surface,
        state.actor,
        state.fixture,
        grid,
        algorithm,
        options
      )
    end
  end
end

local function request_path(state, kind, start_position, goal_position, fields)
  local actor = state.actor
  local prototype = actor.prototype
  local request_id = state.surface.request_path({
    bounding_box = prototype.collision_box,
    collision_mask = prototype.collision_mask,
    start = start_position,
    goal = goal_position,
    force = actor.force,
    radius = PathMath.ARRIVAL_DISTANCE,
    pathfind_flags = {
      prefer_straight_paths = kind == "baseline",
      cache = false
    },
    can_open_gates = true,
    entity_to_ignore = actor
  })
  local request = fields or {}
  request.kind = kind
  request.start_position = PathMath.copy_position(start_position)
  request.goal_position = PathMath.copy_position(goal_position)
  state.requests[request_id] = request
  state.engine_request_count = state.engine_request_count + 1
  return request_id
end

local function start_alternate_candidate(state, candidate_index)
  local candidate = state.alternate.candidates[candidate_index]
  if not candidate then return false end
  candidate.segments = {}
  state.alternate.active_candidate_index = candidate_index
  request_path(state, "alternate-segment", state.fixture.start, candidate.via, {
    candidate_index = candidate_index,
    segment = 1
  })
  request_path(state, "alternate-segment", candidate.via, state.fixture.goal, {
    candidate_index = candidate_index,
    segment = 2
  })
  return true
end

local function alternate_fallback(state, optimization_status)
  local engine = state.results.engine
  local extra = {
    request_count = state.engine_request_count,
    duration_ticks = game.tick - state.started_tick,
    optimization_status = optimization_status
  }
  if algorithm_selected(state, "engine-alternate") then
    state.results["engine-alternate"] = path_result(
      state.surface,
      state.actor,
      state.fixture,
      "engine-alternate",
      engine.path,
      extra
    )
  end
  if algorithm_selected(state, "engine-alternate-global") then
    state.results["engine-alternate-global"] = path_result(
      state.surface,
      state.actor,
      state.fixture,
      "engine-alternate-global",
      engine.path,
      extra
    )
  end
  state.complete = true
end

local function finish_alternates(state)
  local baseline = state.results.engine
  if algorithm_selected(state, "engine-alternate") then
    local current_path = baseline.path
    local current_index = nil
    if state.production_alternate_eligible then
      current_path, _, current_index = PathMath.select_shortest_path(
        baseline.path,
        baseline.distance,
        state.alternate.candidates
      )
    end
    state.results["engine-alternate"] = path_result(
      state.surface,
      state.actor,
      state.fixture,
      "engine-alternate",
      current_path,
      {
        request_count = state.engine_request_count,
        duration_ticks = game.tick - state.started_tick,
        optimization_status = state.production_alternate_eligible
          and "evaluated"
          or "not-eligible",
        selected_candidate_index = current_index
      }
    )
  end

  local global_candidates = {}
  for index, candidate in ipairs(state.alternate.candidates) do
    if candidate.path then
      local path = PathSmoothing.simplify(
        state.surface,
        state.actor,
        candidate.path,
        state.fixture.goal
      )
      global_candidates[index] = {
        path = path,
        distance = PathMath.polyline_distance(state.fixture.start, path)
      }
    else
      global_candidates[index] = {}
    end
  end
  if algorithm_selected(state, "engine-alternate-global") then
    local global_path, _, global_index = PathMath.select_shortest_path(
      baseline.path,
      baseline.distance,
      global_candidates
    )
    state.results["engine-alternate-global"] = path_result(
      state.surface,
      state.actor,
      state.fixture,
      "engine-alternate-global",
      global_path,
      {
        request_count = state.engine_request_count,
        duration_ticks = game.tick - state.started_tick,
        optimization_status = "evaluated-unconditionally-global-smoothing",
        selected_candidate_index = global_index
      }
    )
  end
  state.complete = true
end

function Benchmark.start(surface, actor, fixture, selected_algorithms)
  local state = {
    surface = surface,
    actor = actor,
    fixture = fixture,
    started_tick = game.tick,
    requests = {},
    engine_request_count = 0,
    results = {},
    selected_algorithms = selected_algorithms,
    complete = false
  }

  local needs_grid = selected_algorithms == nil
  for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
    needs_grid = needs_grid
      or (algorithm:find("^grid%-") and algorithm_selected(state, algorithm))
  end
  if needs_grid then
    local grid = NavigationGrid.capture(
      surface,
      actor,
      fixture.bounds,
      fixture.grid_resolution or Benchmark.GRID_RESOLUTION
    )
    run_selected_grid_algorithms(state, grid)
  end

  local needs_engine = algorithm_selected(state, "engine")
    or algorithm_selected(state, "engine-alternate")
    or algorithm_selected(state, "engine-alternate-global")
  if not needs_engine then
    state.complete = true
    return state
  end
  request_path(state, "baseline", fixture.start, fixture.goal)
  return state
end

function Benchmark.handle_path_result(state, event)
  local request = state.requests[event.id]
  state.requests[event.id] = nil
  if not request or state.complete then return false end

  if request.kind == "baseline" then
    if event.try_again_later then
      state.results.engine = path_result(
        state.surface,
        state.actor,
        state.fixture,
        "engine",
        nil,
        {
          status = "busy",
          request_count = state.engine_request_count,
          optimization_status = "busy"
        }
      )
      alternate_fallback(state, "baseline-busy")
      return true
    end
    if not event.path then
      state.results.engine = path_result(
        state.surface,
        state.actor,
        state.fixture,
        "engine",
        nil,
        {
          request_count = state.engine_request_count,
          duration_ticks = game.tick - state.started_tick
        }
      )
      alternate_fallback(state, "baseline-no-path")
      return true
    end

    local engine_path = PathMath.path_from_event(event)
    local path = PathSmoothing.simplify(
      state.surface,
      state.actor,
      engine_path,
      state.fixture.goal
    )
    state.results.engine = path_result(
      state.surface,
      state.actor,
      state.fixture,
      "engine",
      path,
      {
        raw_distance = PathMath.polyline_distance(state.fixture.start, engine_path),
        raw_waypoint_count = #engine_path,
        request_count = state.engine_request_count,
        duration_ticks = game.tick - state.started_tick
      }
    )

    local needs_production_alternate = algorithm_selected(state, "engine-alternate")
    local needs_global_alternate = algorithm_selected(state, "engine-alternate-global")
    state.production_alternate_eligible = state.results.engine.detour_ratio
      > Policy.optimization.detour_ratio
    if not needs_production_alternate and not needs_global_alternate then
      state.complete = true
      return true
    end

    if not state.production_alternate_eligible and not needs_global_alternate then
      alternate_fallback(state, "not-eligible")
      return true
    end

    local vias = PathMath.alternate_vias(
      state.surface,
      state.actor.name,
      state.fixture.start,
      state.fixture.goal,
      path
    )
    if #vias == 0 then
      alternate_fallback(state, "no-via")
      return true
    end

    state.alternate = {candidates = {}, active_candidate_index = nil}
    for index, spec in ipairs(vias) do
      state.alternate.candidates[index] = {
        fraction = spec.fraction,
        via = PathMath.copy_position(spec.position)
      }
    end
    start_alternate_candidate(state, 1)
    return true
  end

  if request.kind == "alternate-segment" then
    local candidate = state.alternate
      and state.alternate.candidates[request.candidate_index]
      or nil
    if not candidate
        or state.alternate.active_candidate_index ~= request.candidate_index then
      return true
    end

    if event.try_again_later or not event.path then
      candidate.segments[request.segment] = false
    else
      local engine_path = PathMath.path_from_event(event)
      candidate.segments[request.segment] = PathSmoothing.simplify(
        state.surface,
        state.actor,
        engine_path,
        request.goal_position
      )
    end

    if candidate.segments[1] ~= nil and candidate.segments[2] ~= nil then
      PathMath.complete_alternate_candidate(state.fixture.start, candidate)
      state.alternate.active_candidate_index = nil
      if not start_alternate_candidate(state, request.candidate_index + 1) then
        finish_alternates(state)
      end
    end
    return true
  end

  return false
end

return Benchmark
