local Follower = require("__factorio-scv-control__/scripts/follower")
local PathMath = require("__factorio-scv-control__/scripts/path_math")
local PlanningRun = require("__factorio-scv-control__/scripts/navigation/planning_run")
local Policy = require("__factorio-scv-control__/scripts/navigation_policy")
local Profiles = require("__factorio-scv-control__/scripts/navigation/profiles/init")
local Util = require("episodes.util")

local Adapter = {}

Adapter.ID = "planning-run-follower-v1"

local function stop(run)
  local actor = run.navigation.actor
  if actor and actor.valid then Follower.stop(actor) end
end

local function nearest_obstacle_distance(run)
  local actor = run.navigation.actor
  if not actor or not actor.valid then return false end
  local nearest
  for _, position in ipairs(run.obstacle_positions or {}) do
    local distance = Util.distance(actor.position, position)
    nearest = nearest and math.min(nearest, distance) or distance
  end
  return nearest or false
end

local function record_stage_work(run, entry)
  local work = run.metrics.work.planning
  if entry.event == "provider-start" then
    work.provider_starts = work.provider_starts + 1
  elseif entry.event == "provider-result" then
    work.provider_results = work.provider_results + 1
  elseif entry.event == "postprocess" then
    work.postprocessors = work.postprocessors + 1
  elseif entry.event == "validate" then
    work.validators = work.validators + 1
  elseif entry.event == "score" then
    work.cost_scores = work.cost_scores + 1
  elseif entry.event == "select" then
    work.selections = work.selections + 1
  end
end

local function planning_runtime(run, context)
  local navigation = run.navigation
  return {
    surface = navigation.actor.surface,
    actor = navigation.actor,
    tick = context.tick,
    on_request = function(request_id, pending, planning_run)
      navigation.request_id = request_id
      navigation.request_started_tick = context.tick
      run.metrics.work.planning.requests = run.metrics.work.planning.requests + 1
      context.record("path-requested", {
        request_id = request_id,
        planning_run_id = planning_run.id,
        provider_id = pending.provider_id,
        request_ordinal = pending.request_ordinal,
        start = Util.copy_position(planning_run.start_position),
        goal = Util.copy_position(planning_run.goal_position)
      })
    end,
    on_trace = function(entry, planning_run)
      record_stage_work(run, entry)
      context.record("planning-trace", {
        planning_run_id = planning_run.id,
        sequence = entry.sequence,
        trace_event = entry.event,
        provider_id = entry.provider_id,
        component_id = entry.component_id,
        status = entry.status,
        reason = entry.reason,
        request_ordinal = entry.request_ordinal,
        tick_offset = entry.tick_offset
      })
    end
  }
end

local function record_planning_result(run, result)
  local navigation = run.navigation
  navigation.planning_results = navigation.planning_results or {}
  navigation.planning_results[#navigation.planning_results + 1] = {
    run_id = result.run_id,
    status = result.status,
    reason = result.reason,
    selected_provider_id = result.selected_provider_id,
    selected_source = result.selected_source,
    provider_order = result.provider_order,
    trace = PlanningRun.provider_trace(navigation.planning_run),
    metrics = result.metrics
  }
  local values = result.metrics and result.metrics.values or {}
  run.metrics.work.planning.run_ticks = run.metrics.work.planning.run_ticks
    + (values.duration_ticks or 0)
end

local function activate_route(run, fixture, result, context)
  local navigation = run.navigation
  local actor = navigation.actor
  local route = result.route
  local distance = route.predicted.distance
    or PathMath.polyline_distance(actor.position, route.points)
  local predicted_ticks = actor.character_running_speed > 0
    and math.ceil(distance / actor.character_running_speed)
    or false
  route.predicted.distance = distance
  route.predicted.travel_ticks = predicted_ticks
  navigation.route = route
  navigation.follow_state = {
    path = route.points,
    waypoint_index = 1,
    segment_start = Util.copy_position(actor.position),
    trajectory = nil,
    recovery_waypoint_index = nil,
    recovery_attempts = 0
  }
  navigation.last_position = Util.copy_position(actor.position)
  navigation.last_stuck_check = context.tick
  navigation.last_recovery_attempt = 0
  navigation.state = "moving"
  navigation.retry_tick = nil
  navigation.request_id = nil
  run.metrics.route_count = run.metrics.route_count + 1
  run.metrics.source = result.selected_source or route.source
  run.metrics.selected_provider_id = result.selected_provider_id or false
  run.metrics.provider_order = result.provider_order
  run.metrics.path_distance = distance
  run.metrics.last_predicted_travel_ticks = predicted_ticks
  if run.metrics.predicted_travel_ticks == false then
    run.metrics.predicted_travel_ticks = predicted_ticks
  end
  if run.metrics.movement_started_tick == false then
    run.metrics.movement_started_tick = context.tick
  end
  run.metrics.route_predictions[#run.metrics.route_predictions + 1] = {
    tick = context.tick,
    source = run.metrics.source,
    selected_provider_id = run.metrics.selected_provider_id,
    distance = distance,
    predicted_travel_ticks = predicted_ticks,
    waypoint_count = #route.points
  }
  context.record("route-activated", {
    planning_run_id = result.run_id,
    source = run.metrics.source,
    selected_provider_id = run.metrics.selected_provider_id,
    path = Util.copy_path(route.points),
    path_distance = distance,
    predicted_travel_ticks = predicted_ticks
  })
end

local function handle_planning_progress(run, fixture, result, context)
  if not result then
    run.navigation.state = "failed"
    run.navigation.terminal_reason = "planning-returned-no-result"
    return
  end
  if result.status == "pending" then return end
  if result.status == "stale" then
    context.record("stale-path-result", {reason = result.reason})
    return
  end

  record_planning_result(run, result)
  if result.status == "success" then
    activate_route(run, fixture, result, context)
    return
  end
  if result.status == "busy-retry" then
    run.navigation.state = "planning"
    run.navigation.retry_tick = context.tick + result.retry_after_ticks
    run.navigation.request_id = nil
    context.record("planning-retry-scheduled", {
      planning_run_id = result.run_id,
      retry_tick = run.navigation.retry_tick,
      reason = result.reason
    })
    return
  end
  if result.status == "no-path" then
    run.navigation.state = "no-path"
    run.navigation.terminal_reason = result.reason or "no-path"
    context.record("navigation-terminal", {
      state = "no-path",
      reason = run.navigation.terminal_reason
    })
    return
  end
  run.navigation.state = "failed"
  run.navigation.terminal_reason = result.reason or ("planning-" .. result.status)
end

local function begin_planning(run, fixture, context, reason, count_as_replan)
  local navigation = run.navigation
  local actor = navigation.actor
  if not actor or not actor.valid then
    navigation.state = "failed"
    navigation.terminal_reason = "invalid-actor"
    return false
  end

  stop(run)
  navigation.state = "planning"
  navigation.retry_tick = nil
  navigation.request_id = nil
  navigation.follow_state = nil
  navigation.planning_sequence = (navigation.planning_sequence or 0) + 1
  run.metrics.work.planning.runs = run.metrics.work.planning.runs + 1
  if count_as_replan then
    run.metrics.replan_count = run.metrics.replan_count + 1
    if run.metrics.replan_tick == false then
      run.metrics.replan_tick = context.tick
      run.metrics.replan_latency_ticks = run.metrics.action_tick ~= false
        and context.tick - run.metrics.action_tick
        or false
      run.metrics.obstacle_distance_at_replan = nearest_obstacle_distance(run)
    end
  end

  local profile_reference = Profiles.default_reference()
  local planning_run, progress = PlanningRun.start(profile_reference, {
    id = fixture.id .. ":" .. navigation.planning_sequence,
    adapter_id = Adapter.ID,
    start_position = Util.copy_position(actor.position),
    goal_position = Util.copy_position(fixture.goal),
    reason = reason
  }, planning_runtime(run, context))
  if not planning_run then
    navigation.state = "failed"
    navigation.terminal_reason = progress and progress.message or "planning-start-failed"
    context.record("planning-start-failed", {error = progress})
    return false
  end
  navigation.planning_run = planning_run
  handle_planning_progress(run, fixture, progress, context)
  return navigation.state ~= "failed"
end

function Adapter.issue(run, fixture, context)
  run.metrics.profile_id = Profiles.DEFAULT_ID
  run.navigation.state = "created"
  run.navigation.planning_results = {}
  return begin_planning(run, fixture, context, "episode-command", false)
end

function Adapter.handle_path_result(run, fixture, event, context)
  local navigation = run.navigation
  local planning_run = navigation.planning_run
  if not planning_run or planning_run.status ~= "running"
      or planning_run.pending_request_id ~= event.id then
    context.record("stale-path-result", {request_id = event.id})
    return false
  end

  navigation.request_id = nil
  run.metrics.work.planning.results = run.metrics.work.planning.results + 1
  run.metrics.work.planning.ticks = run.metrics.work.planning.ticks
    + (context.tick - (navigation.request_started_tick or context.tick))
  local result = PlanningRun.handle_result(
    planning_run,
    event,
    planning_runtime(run, context)
  )
  handle_planning_progress(run, fixture, result, context)
  return true
end

function Adapter.update(run, fixture, context)
  local navigation = run.navigation
  local actor = navigation.actor
  if not actor or not actor.valid then
    navigation.state = "failed"
    navigation.terminal_reason = "invalid-actor"
    return
  end
  if navigation.state == "planning" then
    if navigation.retry_tick and context.tick >= navigation.retry_tick then
      begin_planning(run, fixture, context, "pathfinder-busy-retry", false)
    end
    return
  end
  if navigation.state ~= "moving" then return end

  local progress, diagnostics = Follower.advance(
    actor,
    navigation.follow_state,
    fixture.goal
  )
  run.metrics.work.following.ticks = run.metrics.work.following.ticks + 1
  diagnostics = diagnostics or {}
  run.metrics.max_cross_track_error = math.max(
    run.metrics.max_cross_track_error,
    math.abs(diagnostics.cross_track_error or 0)
  )
  if diagnostics.switched then
    run.metrics.direction_switches = run.metrics.direction_switches + 1
  end
  local recovery_attempt = diagnostics.recovery_attempt or 0
  if recovery_attempt > (navigation.last_recovery_attempt or 0) then
    run.metrics.recovery_count = run.metrics.recovery_count + 1
  end
  navigation.last_recovery_attempt = recovery_attempt

  if progress == "arrived" then
    navigation.state = "arrived"
    navigation.terminal_reason = diagnostics.reason or "arrived"
    context.record("navigation-terminal", {
      state = "arrived",
      reason = navigation.terminal_reason,
      position = Util.copy_position(actor.position)
    })
    return
  end
  if progress == "replan" then
    begin_planning(run, fixture, context, "endpoint-correction", true)
    return
  end

  if context.tick - navigation.last_stuck_check < Policy.follower.stuck_check_interval then
    return
  end
  local moved = Util.distance(actor.position, navigation.last_position)
  if moved < Policy.follower.stuck_distance then
    navigation.stuck_retries = (navigation.stuck_retries or 0) + 1
    run.metrics.stuck_count = run.metrics.stuck_count + 1
    context.record("stuck-detected", {
      retry = navigation.stuck_retries,
      moved = moved,
      position = Util.copy_position(actor.position)
    })
    if navigation.stuck_retries > Policy.follower.max_stuck_retries then
      stop(run)
      navigation.state = "failed"
      navigation.terminal_reason = "stuck-retry-limit"
      return
    end
    begin_planning(run, fixture, context, "stuck-replan", true)
  else
    navigation.stuck_retries = 0
  end
  navigation.last_position = Util.copy_position(actor.position)
  navigation.last_stuck_check = context.tick
end

function Adapter.stop(run)
  stop(run)
  local planning_run = run.navigation.planning_run
  if planning_run and planning_run.status == "running" then
    PlanningRun.cancel(planning_run, "episode-terminal", {
      tick = game.tick
    })
  end
end

return Adapter
