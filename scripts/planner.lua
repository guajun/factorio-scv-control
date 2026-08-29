local Logger = require("scripts.planner_logger")
local PathMath = require("scripts.path_math")
local PathRender = require("scripts.path_render")
local State = require("scripts.state")

local Planner = {}
local OPTIMIZE_DETOUR_THRESHOLD = 2

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

local function request_candidate_segment(player, state, optimization, segment, start_position, goal_position)
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
    segment = segment,
    start_position = PathMath.copy_position(start_position),
    goal_position = PathMath.copy_position(goal_position)
  }
  optimization.request_ids[request_id] = true
end

local function start_optimization(player, state, request, baseline_path, baseline_distance, direct_distance)
  local via = PathMath.alternate_via(
    player.surface,
    player.character.name,
    request.start_position,
    request.goal_position,
    baseline_path
  )
  if not via then return false end

  local optimization = {
    command_id = request.command_id,
    start_position = PathMath.copy_position(request.start_position),
    goal_position = PathMath.copy_position(request.goal_position),
    via = PathMath.copy_position(via),
    baseline_path = baseline_path,
    baseline_distance = baseline_distance,
    direct_distance = direct_distance,
    segments = {},
    request_ids = {}
  }
  state.pending_request = nil
  state.pending_optimization = optimization
  request_candidate_segment(player, state, optimization, 1, request.start_position, via)
  request_candidate_segment(player, state, optimization, 2, via, request.goal_position)
  Logger.write(player, "path-optimization-request", {
    command_id = request.command_id,
    baseline_distance = baseline_distance,
    direct_distance = direct_distance,
    baseline_detour_ratio = baseline_distance / direct_distance,
    via = PathMath.copy_position(via)
  })
  return true
end

local function finish_optimization(player, state, callbacks)
  local optimization = state.pending_optimization
  if not optimization
      or optimization.segments[1] == nil
      or optimization.segments[2] == nil then
    return
  end

  local candidate_path = nil
  local candidate_distance = nil
  if optimization.segments[1] and optimization.segments[2] then
    candidate_path = PathMath.combine_paths(optimization.segments[1], optimization.segments[2])
    candidate_distance = PathMath.polyline_distance(optimization.start_position, candidate_path)
  end
  local use_candidate = candidate_distance
    and candidate_distance + 0.01 < optimization.baseline_distance
  local selected_path = use_candidate and candidate_path or optimization.baseline_path
  Logger.write(player, "path-optimization-result", {
    command_id = optimization.command_id,
    status = candidate_path and "success" or "candidate-failed",
    via = optimization.via,
    baseline_distance = optimization.baseline_distance,
    candidate_distance = candidate_distance,
    selected = use_candidate and "candidate" or "baseline",
    improvement_ratio = candidate_distance
      and (optimization.baseline_distance - candidate_distance) / optimization.baseline_distance
      or 0,
    candidate_path = candidate_path
  })
  callbacks.activate_path(player, state, selected_path)
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
    if not optimization or optimization.command_id ~= request.command_id then
      Logger.write(player, "path-candidate-result", {
        request_id = event.id,
        command_id = request.command_id,
        segment = request.segment,
        status = "stale"
      })
      return
    end

    optimization.request_ids[event.id] = nil
    if event.try_again_later or not event.path then
      optimization.segments[request.segment] = false
      Logger.write(player, "path-candidate-result", {
        request_id = event.id,
        command_id = request.command_id,
        segment = request.segment,
        status = event.try_again_later and "busy" or "no-path"
      })
    else
      local segment_path = PathMath.path_from_event(event, request.goal_position)
      optimization.segments[request.segment] = segment_path
      Logger.write(player, "path-candidate-result", {
        request_id = event.id,
        command_id = request.command_id,
        segment = request.segment,
        status = "success",
        start = request.start_position,
        goal = request.goal_position,
        path_distance = PathMath.polyline_distance(request.start_position, segment_path),
        path = segment_path
      })
    end
    finish_optimization(player, state, callbacks)
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
    state.retry_tick = game.tick + 30
    return
  end
  if not event.path then
    Logger.write(player, "path-result", {
      request_id = event.id,
      command_id = request.command_id,
      status = "no-path"
    })
    player.print({"scv-control.no-path"})
    callbacks.finish_active(player, state)
    return
  end

  local request_start = request.start_position or PathMath.copy_position(player.position)
  local request_goal = request.goal_position or PathMath.copy_position(state.active.position)
  request.start_position = request_start
  request.goal_position = request_goal
  local baseline_path, logged_path = PathMath.path_from_event(event, request_goal)
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
    path_distance = path_distance,
    direct_distance = direct_distance,
    detour_ratio = detour_ratio,
    optimization_eligible = detour_ratio > OPTIMIZE_DETOUR_THRESHOLD,
    path = logged_path
  })

  if detour_ratio > OPTIMIZE_DETOUR_THRESHOLD
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
end

return Planner
