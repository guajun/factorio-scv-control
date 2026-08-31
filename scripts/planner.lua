local Logger = require("scripts.planner_logger")
local PathMath = require("scripts.path_math")
local PathRender = require("scripts.path_render")
local PathSmoothing = require("scripts.path_smoothing")
local Policy = require("scripts.navigation_policy")
local State = require("scripts.state")

local Planner = {}
local PREVIEW_INTERFACE = "scv_pathfinding_preview"

local function notify_preview(player, command_id, start_position, goal_position, path, status)
  local interface = remote.interfaces[PREVIEW_INTERFACE]
  if not interface or not interface.preview_plan then return end
  local ok, message = pcall(remote.call, PREVIEW_INTERFACE, "preview_plan", player.index, {
    command_id = command_id,
    surface_index = player.surface.index,
    start_position = PathMath.copy_position(start_position),
    goal_position = PathMath.copy_position(goal_position),
    production_path = path,
    production_status = status
  })
  if not ok then log("SCV preview failed: " .. tostring(message)) end
end

function Planner.request_active(player, state, reason)
  local character = player.character
  if not character or not character.valid or not state.active then return false end
  if state.active.surface_index ~= player.surface.index then return false end

  PathRender.clear(state)
  local prototype = character.prototype
  local start_position = PathMath.copy_position(character.position)
  local goal_position = PathMath.copy_position(state.active.position)
  local request_id = player.surface.request_path({
    bounding_box = prototype.collision_box,
    collision_mask = prototype.collision_mask,
    start = character.position,
    goal = state.active.position,
    force = player.force,
    radius = PathMath.ARRIVAL_DISTANCE,
    pathfind_flags = {prefer_straight_paths = true, cache = false},
    can_open_gates = true,
    entity_to_ignore = character
  })

  state.pending_request = request_id
  state.pending_optimization = nil
  state.path = nil
  state.retry_tick = nil
  storage.path_requests[request_id] = {
    kind = "baseline",
    player_index = player.index,
    command_id = state.active.id,
    start_position = start_position,
    goal_position = goal_position,
    reason = reason or "unspecified"
  }
  Logger.write(player, "path-request", {
    request_id = request_id,
    command_id = state.active.id,
    reason = reason or "unspecified",
    start = start_position,
    goal = goal_position,
    direct_distance = PathMath.distance(start_position, goal_position),
    running_speed = player.character_running_speed
  })
  return true
end

local function request_candidate_segment(
    player,
    state,
    optimization,
    candidate_index,
    segment,
    start_position,
    goal_position
)
  local character = player.character
  local prototype = character.prototype
  local request_id = player.surface.request_path({
    bounding_box = prototype.collision_box,
    collision_mask = prototype.collision_mask,
    start = start_position,
    goal = goal_position,
    force = player.force,
    radius = PathMath.ARRIVAL_DISTANCE,
    pathfind_flags = {prefer_straight_paths = false, cache = false},
    can_open_gates = true,
    entity_to_ignore = character
  })

  storage.path_requests[request_id] = {
    kind = "candidate",
    player_index = player.index,
    command_id = state.active.id,
    candidate_index = candidate_index,
    segment = segment,
    start_position = PathMath.copy_position(start_position),
    goal_position = PathMath.copy_position(goal_position)
  }
  optimization.request_ids[request_id] = true
end

local function start_candidate(player, state, optimization, candidate_index)
  local candidate = optimization.candidates[candidate_index]
  if not candidate then return false end

  candidate.segments = {}
  optimization.active_candidate_index = candidate_index
  request_candidate_segment(
    player,
    state,
    optimization,
    candidate_index,
    1,
    optimization.start_position,
    candidate.via
  )
  request_candidate_segment(
    player,
    state,
    optimization,
    candidate_index,
    2,
    candidate.via,
    optimization.goal_position
  )
  Logger.write(player, "path-optimization-candidate-request", {
    command_id = optimization.command_id,
    candidate_index = candidate_index,
    fraction = candidate.fraction,
    via = candidate.via
  })
  return true
end

local function start_optimization(player, state, request, baseline_path, baseline_distance, direct_distance)
  local via_specs = PathMath.alternate_vias(
    player.surface,
    player.character.name,
    request.start_position,
    request.goal_position,
    baseline_path
  )
  if #via_specs == 0 then return false end

  local optimization = {
    command_id = request.command_id,
    start_position = PathMath.copy_position(request.start_position),
    goal_position = PathMath.copy_position(request.goal_position),
    baseline_path = baseline_path,
    baseline_distance = baseline_distance,
    direct_distance = direct_distance,
    candidates = {},
    request_ids = {}
  }
  for index, spec in ipairs(via_specs) do
    optimization.candidates[index] = {
      fraction = spec.fraction,
      via = PathMath.copy_position(spec.position)
    }
  end
  state.pending_request = nil
  state.pending_optimization = optimization
  Logger.write(player, "path-optimization-request", {
    command_id = request.command_id,
    baseline_distance = baseline_distance,
    direct_distance = direct_distance,
    baseline_detour_ratio = baseline_distance / direct_distance,
    candidates = via_specs
  })
  return start_candidate(player, state, optimization, 1)
end

local function finish_optimization(player, state, callbacks)
  local optimization = state.pending_optimization
  if not optimization then return end

  local candidate_results = {}
  for index, candidate in ipairs(optimization.candidates) do
    candidate_results[index] = {
      fraction = candidate.fraction,
      via = candidate.via,
      status = candidate.path and "success" or "failed",
      distance = candidate.distance,
      path = candidate.path
    }
  end
  local selected_path, selected_distance, selected_candidate_index = PathMath.select_shortest_path(
    optimization.baseline_path,
    optimization.baseline_distance,
    optimization.candidates
  )
  Logger.write(player, "path-optimization-result", {
    command_id = optimization.command_id,
    status = selected_candidate_index and "success" or "baseline-retained",
    baseline_distance = optimization.baseline_distance,
    candidates = candidate_results,
    selected = selected_candidate_index and "candidate" or "baseline",
    selected_candidate_index = selected_candidate_index,
    selected_distance = selected_distance,
    improvement_ratio = (optimization.baseline_distance - selected_distance)
      / optimization.baseline_distance
  })
  callbacks.activate_path(player, state, selected_path)
  notify_preview(
    player,
    optimization.command_id,
    optimization.start_position,
    optimization.goal_position,
    selected_path,
    "success"
  )
end

local function advance_optimization(player, state, callbacks)
  local optimization = state.pending_optimization
  if not optimization then return end
  local candidate_index = optimization.active_candidate_index
  local candidate = candidate_index and optimization.candidates[candidate_index] or nil
  if not candidate
      or candidate.segments[1] == nil
      or candidate.segments[2] == nil then
    return
  end

  PathMath.complete_alternate_candidate(optimization.start_position, candidate)
  Logger.write(player, "path-optimization-candidate-result", {
    command_id = optimization.command_id,
    candidate_index = candidate_index,
    fraction = candidate.fraction,
    via = candidate.via,
    status = candidate.path and "success" or "failed",
    distance = candidate.distance,
    path = candidate.path
  })

  optimization.active_candidate_index = nil
  if start_candidate(player, state, optimization, candidate_index + 1) then return end
  finish_optimization(player, state, callbacks)
end

function Planner.handle_result(event, callbacks)
  State.ensure_storage()
  local request = storage.path_requests[event.id]
  storage.path_requests[event.id] = nil
  if not request then return end

  local player = game.get_player(request.player_index)
  local state = storage.players[request.player_index]
  if not player or not state or not state.active or state.active.id ~= request.command_id then
    if player then
      Logger.write(player, "path-result", {
        request_id = event.id,
        command_id = request.command_id,
        status = "stale"
      })
    end
    return
  end

  if request.kind == "candidate" then
    local optimization = state.pending_optimization
    if not optimization
        or optimization.command_id ~= request.command_id
        or optimization.active_candidate_index ~= request.candidate_index then
      Logger.write(player, "path-candidate-result", {
        request_id = event.id,
        command_id = request.command_id,
        candidate_index = request.candidate_index,
        segment = request.segment,
        status = "stale"
      })
      return
    end

    optimization.request_ids[event.id] = nil
    local candidate = optimization.candidates[request.candidate_index]
    if event.try_again_later or not event.path then
      candidate.segments[request.segment] = false
      Logger.write(player, "path-candidate-result", {
        request_id = event.id,
        command_id = request.command_id,
        candidate_index = request.candidate_index,
        fraction = candidate.fraction,
        segment = request.segment,
        status = event.try_again_later and "busy" or "no-path"
      })
    else
      local engine_path = PathMath.path_from_event(event)
      local segment_path = PathSmoothing.simplify(
        player.surface,
        player.character,
        engine_path,
        request.goal_position
      )
      candidate.segments[request.segment] = segment_path
      Logger.write(player, "path-candidate-result", {
        request_id = event.id,
        command_id = request.command_id,
        candidate_index = request.candidate_index,
        fraction = candidate.fraction,
        segment = request.segment,
        status = "success",
        start = request.start_position,
        goal = request.goal_position,
        path_distance = PathMath.polyline_distance(request.start_position, segment_path),
        engine_path = engine_path,
        smoothed_path = segment_path,
        engine_turns = PathMath.turn_metrics(engine_path),
        smoothed_turns = PathMath.turn_metrics(segment_path)
      })
    end
    advance_optimization(player, state, callbacks)
    return
  end

  if state.pending_request ~= event.id then
    Logger.write(player, "path-result", {
      request_id = event.id,
      command_id = request.command_id,
      status = "stale"
    })
    return
  end

  state.pending_request = nil
  if event.try_again_later then
    Logger.write(player, "path-result", {
      request_id = event.id,
      command_id = request.command_id,
      status = "busy"
    })
    state.retry_tick = game.tick + Policy.path_request.busy_retry_ticks
    return
  end
  if not event.path then
    Logger.write(player, "path-result", {
      request_id = event.id,
      command_id = request.command_id,
      status = "no-path"
    })
    notify_preview(
      player,
      request.command_id,
      request.start_position or player.position,
      request.goal_position or state.active.position,
      nil,
      "no-path"
    )
    player.print({"scv-control.no-path"})
    callbacks.finish_active(player, state)
    return
  end

  local request_start = request.start_position or PathMath.copy_position(player.position)
  local request_goal = request.goal_position or PathMath.copy_position(state.active.position)
  request.start_position = request_start
  request.goal_position = request_goal
  local engine_path, logged_path = PathMath.path_from_event(event)
  local baseline_path = PathSmoothing.simplify(
    player.surface,
    player.character,
    engine_path,
    request_goal
  )
  local engine_path_distance = PathMath.polyline_distance(request_start, engine_path)
  local path_distance = PathMath.polyline_distance(request_start, baseline_path)
  local direct_distance = PathMath.distance(request_start, request_goal)
  local detour_ratio = direct_distance > 0 and path_distance / direct_distance or 1
  Logger.write(player, "path-result", {
    request_id = event.id,
    command_id = request.command_id,
    status = "success",
    reason = request.reason,
    start = request_start,
    goal = request_goal,
    waypoint_count = #event.path,
    engine_path_distance = engine_path_distance,
    path_distance = path_distance,
    direct_distance = direct_distance,
    detour_ratio = detour_ratio,
    optimization_eligible = detour_ratio > Policy.optimization.detour_ratio,
    engine_path = logged_path,
    smoothed_path = baseline_path,
    removed_waypoints = #engine_path - #baseline_path,
    engine_turns = PathMath.turn_metrics(engine_path),
    smoothed_turns = PathMath.turn_metrics(baseline_path)
  })

  if detour_ratio > Policy.optimization.detour_ratio
      and start_optimization(
        player,
        state,
        request,
        baseline_path,
        path_distance,
        direct_distance
      ) then
    return
  end
  callbacks.activate_path(player, state, baseline_path)
  notify_preview(
    player,
    request.command_id,
    request_start,
    request_goal,
    baseline_path,
    "success"
  )
end

return Planner
