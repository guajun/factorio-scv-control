local GridSearch = require("__factorio-scv-control__/scripts/grid_search")
local NavigationGrid = require("__factorio-scv-control__/scripts/navigation_grid")
local PathMath = require("__factorio-scv-control__/scripts/path_math")
local PathSmoothing = require("__factorio-scv-control__/scripts/path_smoothing")
local Policy = require("__factorio-scv-control__/scripts/navigation_policy")
local PlanningRun = require("__factorio-scv-control__/scripts/navigation/planning_run")
local Profiles = require("__factorio-scv-control__/scripts/navigation/profiles/init")

local Benchmark = {}
Benchmark.GRID_RESOLUTION = Policy.grid.resolution

Benchmark.ALGORITHMS = {
  "engine",
  "production-local",
  "engine-inflated",
  "engine-alternate",
  "engine-alternate-global",
  "grid-a-star",
  "grid-weighted-a-star-2",
  "grid-theta-star",
  "grid-theta-star-exact",
  "safe-hybrid"
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
      optimization_status = extra.optimization_status,
      selected_source = extra.selected_source,
      planning_terminal_status = extra.planning_terminal_status,
      provider_order = extra.provider_order,
      trace = extra.trace,
      failure_reason = extra.failure_reason
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
    selected_candidate_index = extra.selected_candidate_index,
    selected_source = extra.selected_source,
    planning_terminal_status = extra.planning_terminal_status,
    provider_order = extra.provider_order,
    trace = extra.trace,
    failure_reason = extra.failure_reason
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
    local required_by_hybrid = algorithm_selected(state, "safe-hybrid")
      and (algorithm == "grid-a-star"
        or (algorithm == "grid-theta-star-exact"
          and not (state.results["grid-a-star"]
            and state.results["grid-a-star"].trajectory_clearance_safe)))
    if options and (algorithm_selected(state, algorithm) or required_by_hybrid) then
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
  local bounding_box = prototype.collision_box
  if kind == "inflated-baseline" then
    bounding_box = PathSmoothing.collision_box(
      actor,
      PathSmoothing.clearance_margin(actor)
    )
  end
  local request_id = state.surface.request_path({
    bounding_box = bounding_box,
    collision_mask = prototype.collision_mask,
    start = start_position,
    goal = goal_position,
    force = actor.force,
    radius = PathMath.ARRIVAL_DISTANCE,
    pathfind_flags = {
      prefer_straight_paths = kind == "baseline" or kind == "inflated-baseline",
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
  local family = kind == "inflated-baseline" and "inflated"
    or (kind == "baseline" and "baseline" or "alternate")
  state.request_counts[family] = state.request_counts[family] + 1
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

local function finish_benchmark(state)
  if algorithm_selected(state, "safe-hybrid") then
    local selected = nil
    for _, source in ipairs({
      "production-local",
      "engine",
      "engine-inflated",
      "grid-a-star"
    }) do
      local result = state.results[source]
      if result
          and result.status == "success"
          and result.trajectory_clearance_safe
          and (not selected or result.distance < selected.result.distance) then
        selected = {source = source, result = result}
      end
    end
    if not selected then
      local exact = state.results["grid-theta-star-exact"]
      if exact and exact.status == "success" and exact.trajectory_clearance_safe then
        selected = {source = "grid-theta-star-exact", result = exact}
      end
    end
    if selected then
      state.results["safe-hybrid"] = path_result(
        state.surface,
        state.actor,
        state.fixture,
        "safe-hybrid",
        selected.result.path,
        {
          request_count = state.request_counts.inflated + state.request_counts.baseline,
          duration_ticks = game.tick - state.started_tick,
          optimization_status = "shortest-validated-safe-path",
          selected_source = selected.source,
          expanded_nodes = selected.result.expanded_nodes,
          generated_nodes = selected.result.generated_nodes,
          reopened_nodes = selected.result.reopened_nodes,
          sampled_nodes = selected.result.sampled_nodes,
          line_checks = selected.result.line_checks,
          surface_line_checks = selected.result.surface_line_checks
        }
      )
    else
      state.results["safe-hybrid"] = path_result(
        state.surface,
        state.actor,
        state.fixture,
        "safe-hybrid",
        nil,
        {
          request_count = state.request_counts.inflated + state.request_counts.baseline,
          duration_ticks = game.tick - state.started_tick,
          optimization_status = "no-validated-safe-path"
        }
      )
    end
  end
  state.complete = true
end

local function alternate_fallback(state, optimization_status)
  local engine = state.results.engine
  local extra = {
    request_count = state.request_counts.baseline + state.request_counts.alternate,
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
  finish_benchmark(state)
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
        request_count = state.request_counts.baseline + state.request_counts.alternate,
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
        request_count = state.request_counts.baseline + state.request_counts.alternate,
        duration_ticks = game.tick - state.started_tick,
        optimization_status = "evaluated-unconditionally-global-smoothing",
        selected_candidate_index = global_index
      }
    )
  end
  finish_benchmark(state)
end

local function continue_after_baseline(state)
  local baseline = state.results.engine
  if not baseline or baseline.status ~= "success" then
    alternate_fallback(state, "baseline-" .. (baseline and baseline.status or "missing"))
    return
  end

  local needs_production_alternate = algorithm_selected(state, "engine-alternate")
  local needs_global_alternate = algorithm_selected(state, "engine-alternate-global")
  state.production_alternate_eligible = baseline.detour_ratio
    > Policy.optimization.detour_ratio
  if not needs_production_alternate and not needs_global_alternate then
    finish_benchmark(state)
    return
  end
  if not state.production_alternate_eligible and not needs_global_alternate then
    alternate_fallback(state, "not-eligible")
    return
  end

  local vias = PathMath.alternate_vias(
    state.surface,
    state.actor.name,
    state.fixture.start,
    state.fixture.goal,
    baseline.path
  )
  if #vias == 0 then
    alternate_fallback(state, "no-via")
    return
  end
  state.alternate = {candidates = {}, active_candidate_index = nil}
  for index, spec in ipairs(vias) do
    state.alternate.candidates[index] = {
      fraction = spec.fraction,
      via = PathMath.copy_position(spec.position)
    }
  end
  start_alternate_candidate(state, 1)
end

local function candidate_for(run, provider_id)
  for _, candidate in ipairs(run.candidates) do
    if candidate.provider_id == provider_id then return candidate end
  end
  return nil
end

local function metric_values(candidate)
  return candidate
    and candidate.route
    and candidate.route.metrics
    and candidate.route.metrics.values
    or {}
end

local function planning_status(result)
  if result.status == "busy-retry" then return "busy" end
  return result.status
end

local function record_shared_planning(state, result)
  local run = state.planning_run
  local request_count = result.metrics.values.request_count
  local duration_ticks = result.metrics.values.duration_ticks
  local normal = candidate_for(run, "engine-normal")
  local inflated = candidate_for(run, "engine-inflated")
  local grid = candidate_for(run, "grid-a-star")
  local normal_metrics = metric_values(normal)
  local inflated_metrics = metric_values(inflated)
  local grid_metrics = metric_values(grid)
  local trace = PlanningRun.provider_trace(run)

  state.request_counts.baseline = normal and 1 or 0
  state.request_counts.inflated = inflated and 1 or 0
  state.results.engine = path_result(
    state.surface,
    state.actor,
    state.fixture,
    "engine",
    normal and normal.route and normal.route.points or nil,
    {
      status = normal and normal.status or planning_status(result),
      raw_distance = normal_metrics.raw_distance,
      raw_waypoint_count = normal_metrics.raw_waypoint_count,
      request_count = state.request_counts.baseline,
      duration_ticks = duration_ticks
    }
  )
  if inflated then
    state.results["engine-inflated"] = path_result(
      state.surface,
      state.actor,
      state.fixture,
      "engine-inflated",
      inflated.route and inflated.route.points or nil,
      {
        status = inflated.status,
        raw_distance = inflated_metrics.raw_distance,
        raw_waypoint_count = inflated_metrics.raw_waypoint_count,
        request_count = state.request_counts.inflated,
        duration_ticks = duration_ticks,
        optimization_status = "inflated-trajectory-envelope"
      }
    )
  end
  state.results["production-local"] = path_result(
    state.surface,
    state.actor,
    state.fixture,
    "production-local",
    result.route and result.route.points or nil,
    {
      status = planning_status(result),
      request_count = request_count,
      duration_ticks = duration_ticks,
      optimization_status = "shared-production-v1-planning-run",
      selected_source = result.selected_source,
      expanded_nodes = grid_metrics.expanded_nodes,
      generated_nodes = grid_metrics.generated_nodes,
      sampled_nodes = grid_metrics.sampled_nodes,
      line_checks = grid_metrics.line_checks,
      planning_terminal_status = result.status,
      provider_order = result.provider_order,
      trace = trace,
      failure_reason = result.reason
    }
  )
  if not inflated and algorithm_selected(state, "engine-inflated") then
    state.resume_after_inflated = "shared-planning"
    request_path(state, "inflated-baseline", state.fixture.start, state.fixture.goal)
    return
  end
  continue_after_baseline(state)
end

local function planning_runtime(state)
  return {
    surface = state.surface,
    actor = state.actor,
    tick = function() return game.tick end
  }
end

function Benchmark.start(surface, actor, fixture, selected_algorithms)
  local state = {
    surface = surface,
    actor = actor,
    fixture = fixture,
    started_tick = game.tick,
    requests = {},
    request_counts = {baseline = 0, inflated = 0, alternate = 0},
    results = {},
    selected_algorithms = selected_algorithms,
    complete = false
  }

  local needs_grid = selected_algorithms == nil or algorithm_selected(state, "safe-hybrid")
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

  local needs_production_run = algorithm_selected(state, "production-local")
    or algorithm_selected(state, "safe-hybrid")
  if needs_production_run then
    local run, progress = PlanningRun.start(Profiles.default_reference(), {
      id = fixture.id,
      adapter_id = "benchmark",
      start_position = fixture.start,
      goal_position = fixture.goal,
      reason = "benchmark"
    }, planning_runtime(state))
    state.planning_run = run
    if not run then
      state.results["production-local"] = path_result(
        surface,
        actor,
        fixture,
        "production-local",
        nil,
        {status = "failed", optimization_status = progress and progress.message}
      )
      finish_benchmark(state)
    elseif progress.status ~= "pending" then
      record_shared_planning(state, progress)
    end
    return state
  end

  state.needs_engine = algorithm_selected(state, "engine")
    or algorithm_selected(state, "production-local")
    or algorithm_selected(state, "engine-alternate")
    or algorithm_selected(state, "engine-alternate-global")
    or algorithm_selected(state, "safe-hybrid")
  local needs_inflated = algorithm_selected(state, "engine-inflated")
  if needs_inflated then
    request_path(state, "inflated-baseline", fixture.start, fixture.goal)
    return state
  end
  if not state.needs_engine then
    finish_benchmark(state)
    return state
  end
  request_path(state, "baseline", fixture.start, fixture.goal)
  return state
end

function Benchmark.handle_path_result(state, event)
  if state.planning_run
      and state.planning_run.status == "running"
      and state.planning_run.pending_request_id == event.id then
    local progress = PlanningRun.handle_result(
      state.planning_run,
      event,
      planning_runtime(state)
    )
    if progress.status ~= "pending" then record_shared_planning(state, progress) end
    return true
  end

  local request = state.requests[event.id]
  state.requests[event.id] = nil
  if not request or state.complete then return false end

  if request.kind == "inflated-baseline" then
    if event.try_again_later then
      state.results["engine-inflated"] = path_result(
        state.surface,
        state.actor,
        state.fixture,
        "engine-inflated",
        nil,
        {
          status = "busy",
          request_count = state.request_counts.inflated,
          duration_ticks = game.tick - state.started_tick
        }
      )
    elseif not event.path then
      state.results["engine-inflated"] = path_result(
        state.surface,
        state.actor,
        state.fixture,
        "engine-inflated",
        nil,
        {
          request_count = state.request_counts.inflated,
          duration_ticks = game.tick - state.started_tick
        }
      )
    else
      local engine_path = PathMath.path_from_event(event)
      local path = PathSmoothing.simplify(
        state.surface,
        state.actor,
        engine_path,
        state.fixture.goal
      )
      state.results["engine-inflated"] = path_result(
        state.surface,
        state.actor,
        state.fixture,
        "engine-inflated",
        path,
        {
          raw_distance = PathMath.polyline_distance(state.fixture.start, engine_path),
          raw_waypoint_count = #engine_path,
          request_count = state.request_counts.inflated,
          duration_ticks = game.tick - state.started_tick,
          optimization_status = "inflated-trajectory-envelope"
        }
      )
    end
    if state.resume_after_inflated == "shared-planning" then
      state.resume_after_inflated = nil
      continue_after_baseline(state)
    elseif state.needs_engine then
      request_path(state, "baseline", state.fixture.start, state.fixture.goal)
    else
      finish_benchmark(state)
    end
    return true
  end

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
          request_count = state.request_counts.baseline,
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
          request_count = state.request_counts.baseline,
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
        request_count = state.request_counts.baseline,
        duration_ticks = game.tick - state.started_tick
      }
    )
    continue_after_baseline(state)
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
