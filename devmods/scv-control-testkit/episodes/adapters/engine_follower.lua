local Follower = require("__factorio-scv-control__/scripts/follower")
local PathMath = require("__factorio-scv-control__/scripts/path_math")
local PathSmoothing = require("__factorio-scv-control__/scripts/path_smoothing")
local Policy = require("__factorio-scv-control__/scripts/navigation_policy")
local Util = require("episodes.util")

local Adapter = {}

Adapter.ID = "episode-engine-follower-v1"

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

local function request_path(run, fixture, context, reason, count_as_replan)
  local navigation = run.navigation
  local actor = navigation.actor
  if not actor or not actor.valid then
    navigation.state = "failed"
    navigation.terminal_reason = "invalid-actor"
    return false
  end

  stop(run)
  local request_id = actor.surface.request_path({
    bounding_box = actor.prototype.collision_box,
    collision_mask = actor.prototype.collision_mask,
    start = actor.position,
    goal = fixture.goal,
    force = actor.force,
    radius = PathMath.ARRIVAL_DISTANCE,
    pathfind_flags = {prefer_straight_paths = true, cache = false},
    can_open_gates = true,
    entity_to_ignore = actor
  })
  navigation.request_id = request_id
  navigation.request_started_tick = context.tick
  navigation.state = "planning"
  navigation.retry_tick = nil
  navigation.follow_state = nil
  run.metrics.work.planning.requests = run.metrics.work.planning.requests + 1

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
  context.record("path-requested", {
    request_id = request_id,
    reason = reason,
    replan = count_as_replan == true,
    start = Util.copy_position(actor.position),
    goal = Util.copy_position(fixture.goal)
  })
  return true
end

function Adapter.issue(run, fixture, context)
  run.metrics.profile_id = Adapter.ID
  run.navigation.state = "created"
  return request_path(run, fixture, context, "episode-command", false)
end

function Adapter.handle_path_result(run, fixture, event, context)
  local navigation = run.navigation
  if navigation.request_id ~= event.id then
    context.record("stale-path-result", {request_id = event.id})
    return false
  end

  navigation.request_id = nil
  run.metrics.work.planning.results = run.metrics.work.planning.results + 1
  run.metrics.work.planning.ticks = run.metrics.work.planning.ticks
    + (context.tick - navigation.request_started_tick)
  if event.try_again_later then
    navigation.retry_tick = context.tick + Policy.path_request.busy_retry_ticks
    navigation.state = "planning"
    run.metrics.work.planning.busy_results = run.metrics.work.planning.busy_results + 1
    context.record("path-result", {status = "busy"})
    return true
  end
  if not event.path then
    navigation.state = "no-path"
    navigation.terminal_reason = run.metrics.route_count > 0
      and "replan-no-path"
      or "initial-no-path"
    context.record("path-result", {status = "no-path"})
    return true
  end

  local actor = navigation.actor
  local engine_path = PathMath.path_from_event(event)
  local path = PathSmoothing.simplify(
    actor.surface,
    actor,
    engine_path,
    fixture.goal
  )
  local distance = PathMath.polyline_distance(actor.position, path)
  local predicted_ticks = actor.character_running_speed > 0
    and math.ceil(distance / actor.character_running_speed)
    or false
  navigation.route = Util.copy_path(path)
  navigation.follow_state = {
    path = path,
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
  run.metrics.route_count = run.metrics.route_count + 1
  run.metrics.source = "engine-smoothed"
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
    distance = distance,
    predicted_travel_ticks = predicted_ticks,
    waypoint_count = #path
  }
  context.record("path-result", {
    status = "success",
    source = run.metrics.source,
    path = Util.copy_path(path),
    path_distance = distance,
    predicted_travel_ticks = predicted_ticks
  })
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
      request_path(run, fixture, context, "pathfinder-busy-retry", false)
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
    request_path(run, fixture, context, "endpoint-correction", true)
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
    request_path(run, fixture, context, "stuck-replan", true)
  else
    navigation.stuck_retries = 0
  end
  navigation.last_position = Util.copy_position(actor.position)
  navigation.last_stuck_check = context.tick
end

function Adapter.stop(run)
  stop(run)
end

return Adapter
