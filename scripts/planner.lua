local LocalPlanner = require("scripts.local_planner")
local Logger = require("scripts.planner_logger")
local PathMath = require("scripts.path_math")
local PathRender = require("scripts.path_render")
local PathSmoothing = require("scripts.path_smoothing")
local Policy = require("scripts.navigation_policy")
local State = require("scripts.state")

local Planner = {}
local PREVIEW_INTERFACE = "scv_pathfinding_preview"

local function request_engine_path(player, state, kind, start_position, goal_position, reason)
  local character = player.character
  local prototype = character.prototype
  local bounding_box = prototype.collision_box
  if kind == "inflated-baseline" then
    bounding_box = PathSmoothing.collision_box(
      character,
      PathSmoothing.clearance_margin(character)
    )
  end
  local request_id = player.surface.request_path({
    bounding_box = bounding_box,
    collision_mask = prototype.collision_mask,
    start = start_position,
    goal = goal_position,
    force = player.force,
    radius = PathMath.ARRIVAL_DISTANCE,
    pathfind_flags = {prefer_straight_paths = true, cache = false},
    can_open_gates = true,
    entity_to_ignore = character
  })
  state.pending_request = request_id
  storage.path_requests[request_id] = {
    kind = kind,
    player_index = player.index,
    command_id = state.active.id,
    start_position = PathMath.copy_position(start_position),
    goal_position = PathMath.copy_position(goal_position),
    reason = reason
  }
  Logger.write(player, "path-request", {
    request_id = request_id,
    request_kind = kind,
    command_id = state.active.id,
    reason = reason,
    start = start_position,
    goal = goal_position,
    direct_distance = PathMath.distance(start_position, goal_position),
    running_speed = player.character_running_speed
  })
  return request_id
end

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
  local start_position = PathMath.copy_position(character.position)
  local goal_position = PathMath.copy_position(state.active.position)
  state.pending_local_comparison = nil
  state.path = nil
  state.retry_tick = nil
  request_engine_path(
    player,
    state,
    "baseline",
    start_position,
    goal_position,
    reason or "unspecified"
  )
  return true
end

local function finish_local_comparison(player, state, inflated_result, callbacks)
  local pending = state.pending_local_comparison
  if not pending then return false end
  state.pending_local_comparison = nil

  local candidates = {}
  if inflated_result.path then
    candidates[1] = {
      source = "engine-inflated",
      path = inflated_result.path
    }
  end
  local comparison = LocalPlanner.compare(
    player.surface,
    player.character,
    pending.start_position,
    pending.goal_position,
    pending.baseline_path,
    candidates
  )

  Logger.write(player, "path-local-comparison", {
    command_id = pending.command_id,
    selected = comparison.source,
    selected_distance = comparison.distance,
    baseline_safe = comparison.baseline_safe,
    baseline_distance = comparison.baseline_distance,
    inflated_status = inflated_result.status,
    inflated_safe = inflated_result.safe,
    inflated_distance = inflated_result.distance,
    inflated_path = inflated_result.path,
    additional_results = comparison.additional_results,
    grid_safe = comparison.grid_safe,
    grid_distance = comparison.grid_distance,
    grid_path = comparison.grid_path,
    grid_resolution = comparison.grid_resolution,
    search_bounds = comparison.search_bounds,
    expanded_nodes = comparison.expanded_nodes,
    generated_nodes = comparison.generated_nodes,
    line_checks = comparison.line_checks,
    sampled_nodes = comparison.sampled_nodes
  })

  callbacks.activate_path(player, state, comparison.path)
  notify_preview(
    player,
    pending.command_id,
    pending.start_position,
    pending.goal_position,
    comparison.path,
    "success"
  )
  return true
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

  if (request.kind ~= "baseline" and request.kind ~= "inflated-baseline")
      or state.pending_request ~= event.id then
    Logger.write(player, "path-result", {
      request_id = event.id,
      command_id = request.command_id,
      status = "stale"
    })
    return
  end

  state.pending_request = nil
  if event.try_again_later and request.kind == "baseline" then
    Logger.write(player, "path-result", {
      request_id = event.id,
      command_id = request.command_id,
      status = "busy"
    })
    state.retry_tick = game.tick + Policy.path_request.busy_retry_ticks
    return
  end
  if not event.path and request.kind == "baseline" then
    Logger.write(player, "path-result", {
      request_id = event.id,
      command_id = request.command_id,
      status = "no-path"
    })
    notify_preview(
      player,
      request.command_id,
      request.start_position,
      request.goal_position,
      nil,
      "no-path"
    )
    player.print({"scv-control.no-path"})
    callbacks.finish_active(player, state)
    return
  end

  if request.kind == "inflated-baseline" then
    local result = {
      status = event.try_again_later and "busy" or (event.path and "success" or "no-path")
    }
    local engine_path
    local logged_path
    if event.path then
      engine_path, logged_path = PathMath.path_from_event(event)
      result.path = PathSmoothing.simplify(
        player.surface,
        player.character,
        engine_path,
        request.goal_position
      )
      result.distance = PathMath.polyline_distance(request.start_position, result.path)
      result.safe = PathSmoothing.path_is_clear(
        player.surface,
        player.character,
        request.start_position,
        result.path
      )
    end
    Logger.write(player, "path-inflated-result", {
      request_id = event.id,
      command_id = request.command_id,
      status = result.status,
      start = request.start_position,
      goal = request.goal_position,
      waypoint_count = event.path and #event.path or nil,
      engine_path = logged_path,
      smoothed_path = result.path,
      path_distance = result.distance,
      trajectory_clearance_safe = result.safe
    })
    finish_local_comparison(player, state, result, callbacks)
    return
  end

  local request_start = request.start_position
  local request_goal = request.goal_position
  local engine_path, logged_path = PathMath.path_from_event(event)
  local baseline_path = PathSmoothing.simplify(
    player.surface,
    player.character,
    engine_path,
    request_goal
  )
  local engine_path_distance = PathMath.polyline_distance(request_start, engine_path)
  local baseline_distance = PathMath.polyline_distance(request_start, baseline_path)
  local direct_distance = PathMath.distance(request_start, request_goal)

  Logger.write(player, "path-result", {
    request_id = event.id,
    command_id = request.command_id,
    status = "success",
    reason = request.reason,
    start = request_start,
    goal = request_goal,
    waypoint_count = #event.path,
    engine_path_distance = engine_path_distance,
    path_distance = baseline_distance,
    direct_distance = direct_distance,
    detour_ratio = direct_distance > 0 and baseline_distance / direct_distance or 1,
    engine_path = logged_path,
    smoothed_path = baseline_path,
    removed_waypoints = #engine_path - #baseline_path,
    engine_turns = PathMath.turn_metrics(engine_path),
    smoothed_turns = PathMath.turn_metrics(baseline_path)
  })
  state.pending_local_comparison = {
    command_id = request.command_id,
    start_position = request_start,
    goal_position = request_goal,
    baseline_path = baseline_path
  }
  request_engine_path(
    player,
    state,
    "inflated-baseline",
    request_start,
    request_goal,
    request.reason
  )
end

return Planner
