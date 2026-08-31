local Logger = require("scripts.planner_logger")
local PathMath = require("scripts.path_math")
local PathRender = require("scripts.path_render")
local PlanningRun = require("scripts.navigation.planning_run")
local ProfileResolver = require("scripts.navigation.profile_resolver")
local State = require("scripts.state")

local Planner = {}
local PREVIEW_INTERFACE = "scv_pathfinding_preview"

local function request_kind(provider_id)
  if provider_id == "engine-normal" then return "baseline" end
  if provider_id == "engine-inflated" then return "inflated-baseline" end
  return provider_id
end

local function notify_preview(player, run, result)
  local interface = remote.interfaces[PREVIEW_INTERFACE]
  if not interface or not interface.preview_plan then return end
  local ok, message = pcall(remote.call, PREVIEW_INTERFACE, "preview_plan", player.index, {
    command_id = run.command_id,
    surface_index = player.surface.index,
    start_position = PathMath.copy_position(run.start_position),
    goal_position = PathMath.copy_position(run.goal_position),
    production_path = result.route and result.route.points or nil,
    production_status = result.status,
    production_provider_order = result.provider_order,
    production_trace = PlanningRun.provider_trace(run),
    production_selected_source = result.selected_source
  })
  if not ok then log("SCV preview failed: " .. tostring(message)) end
end

local function runtime(player, state)
  return {
    surface = player.surface,
    actor = player.character,
    tick = function() return game.tick end,
    on_request = function(request_id, pending, run)
      storage.path_requests[request_id] = {
        player_index = player.index,
        command_id = state.active.id,
        run_id = run.id,
        provider_id = pending.provider_id,
        request_ordinal = pending.request_ordinal
      }
      Logger.write(player, "path-request", {
        request_id = request_id,
        request_kind = request_kind(pending.provider_id),
        provider_id = pending.provider_id,
        request_ordinal = pending.request_ordinal,
        command_id = state.active.id,
        planning_run_id = run.id,
        reason = run.reason,
        start = run.start_position,
        goal = run.goal_position,
        direct_distance = PathMath.distance(run.start_position, run.goal_position),
        running_speed = player.character_running_speed
      })
    end,
    on_trace = function(entry, run)
      Logger.write(player, "planning-trace", {
        command_id = run.command_id,
        planning_run_id = run.id,
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

local function log_terminal(player, run, result)
  Logger.write(player, "planning-terminal", {
    command_id = run.command_id,
    planning_run_id = run.id,
    status = result.status,
    reason = result.reason,
    provider_id = result.provider_id,
    selected_provider_id = result.selected_provider_id,
    selected_source = result.selected_source,
    provider_order = result.provider_order,
    trace = result.trace,
    candidates = result.candidates,
    metrics = result.metrics
  })
end

local function handle_terminal(player, state, run, result, callbacks)
  log_terminal(player, run, result)
  if result.status == "success" then
    callbacks.activate_path(player, state, result.route.points)
    notify_preview(player, run, result)
    return true
  end
  if result.status == "busy-retry" then
    state.retry_tick = game.tick + result.retry_after_ticks
    return true
  end
  if result.status == "no-path" then
    notify_preview(player, run, result)
    player.print({"scv-control.no-path"})
    callbacks.finish_active(player, state)
    return true
  end
  if result.status == "failed" then
    player.print({"scv-control.command-unavailable"})
    callbacks.finish_active(player, state)
    return true
  end
  return false
end

function Planner.request_active(player, state, reason)
  local character = player.character
  if not character or not character.valid or not state.active then return false end
  if state.active.surface_index ~= player.surface.index then return false end

  State.ensure_storage()
  local _, profile_error = ProfileResolver.preflight(storage.navigation_profile)
  if profile_error then
    Logger.write(player, "profile-rejected", profile_error)
    return false, profile_error
  end

  if state.planning_run and state.planning_run.status == "running" then
    local cancelled = PlanningRun.cancel(
      state.planning_run,
      "superseded",
      runtime(player, state)
    )
    log_terminal(player, state.planning_run, cancelled)
  end

  PathRender.clear(state)
  state.path = nil
  state.retry_tick = nil
  state.next_planning_run_id = (state.next_planning_run_id or 0) + 1
  local run, progress = PlanningRun.start(storage.navigation_profile, {
    id = state.next_planning_run_id,
    command_id = state.active.id,
    adapter_id = "production",
    start_position = PathMath.copy_position(character.position),
    goal_position = PathMath.copy_position(state.active.position),
    reason = reason or "unspecified"
  }, runtime(player, state))
  if not run then
    Logger.write(player, "planning-start-failed", progress)
    return false, progress
  end
  state.planning_run = run
  if progress and progress.status == "pending" then return true end
  if progress and progress.status == "failed" then
    log_terminal(player, run, progress)
    return false, progress
  end
  return run.status == "running"
end

function Planner.handle_result(event, callbacks)
  State.ensure_storage()
  local request = storage.path_requests[event.id]
  storage.path_requests[event.id] = nil
  if not request then return false end

  local player = game.get_player(request.player_index)
  local state = storage.players[request.player_index]
  local run = state and state.planning_run or nil
  if not player or not state or not state.active
      or state.active.id ~= request.command_id
      or not run or run.id ~= request.run_id then
    if player then
      Logger.write(player, "planning-stale-result", {
        request_id = event.id,
        command_id = request.command_id,
        planning_run_id = request.run_id,
        provider_id = request.provider_id,
        status = "stale"
      })
    end
    return false
  end

  local result = PlanningRun.handle_result(run, event, runtime(player, state))
  if result.status == "pending" then return true end
  if result.status == "stale" then
    Logger.write(player, "planning-stale-result", {
      request_id = event.id,
      command_id = request.command_id,
      planning_run_id = request.run_id,
      provider_id = request.provider_id,
      status = "stale",
      reason = result.reason
    })
    return false
  end
  return handle_terminal(player, state, run, result, callbacks)
end

function Planner.cancel(player, state, reason)
  local run = state and state.planning_run or nil
  if not run or run.status ~= "running" then return nil end
  local result = PlanningRun.cancel(run, reason or "cancelled", runtime(player, state))
  log_terminal(player, run, result)
  return result
end

return Planner
