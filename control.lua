local Follower = require("scripts.follower")
local Input = require("scripts.input")
local Logger = require("scripts.planner_logger")
local PathMath = require("scripts.path_math")
local PathRender = require("scripts.path_render")
local Planner = require("scripts.planner")
local Policy = require("scripts.navigation_policy")
local Queue = require("scripts.queue")
local State = require("scripts.state")

local start_next_command

local function stop_walking(player)
  if player.controller_type == defines.controllers.character then
    Follower.stop(player)
  end
end

local function clear_active(state)
  PathRender.clear(state)
  state.active = nil
  state.path = nil
  state.waypoint_index = 1
  state.segment_start = nil
  state.trajectory = nil
  state.recovery_waypoint_index = nil
  state.recovery_attempts = 0
  state.pending_request = nil
  state.stuck_retries = 0
  state.last_position = nil
  state.retry_tick = nil
end

local function finish_active(player, state)
  stop_walking(player)
  clear_active(state)
  start_next_command(player, state)
end

local function activate_path(player, state, path)
  state.pending_request = nil
  state.path = path
  state.waypoint_index = 1
  state.segment_start = PathMath.copy_position(player.position)
  state.trajectory = nil
  state.recovery_waypoint_index = nil
  state.recovery_attempts = 0
  state.last_position = PathMath.copy_position(player.position)
  state.last_stuck_check = game.tick
  PathRender.draw(player, state, path)
end

start_next_command = function(player, state)
  if state.active or #state.queue == 0 then return end
  state.active = Queue.pop(state)
  state.stuck_retries = 0
  state.last_position = PathMath.copy_position(player.position)
  state.last_stuck_check = game.tick
  if not Planner.request_active(player, state, "command-start") then
    player.print({"scv-control.command-unavailable"})
    clear_active(state)
    start_next_command(player, state)
  end
end

local function cancel_all(player)
  local state = State.get(player.index)
  Queue.clear(state)
  clear_active(state)
  stop_walking(player)
end

local function issue_move_command(event, queued)
  local player = game.get_player(event.player_index)
  if not player then return end

  local rejection_reason = Input.rejection_reason(player, event)
  if rejection_reason then
    Logger.write(player, "click", {
      accepted = false,
      queued = queued,
      target = PathMath.copy_position(event.cursor_position),
      reason = rejection_reason
    })
    return
  end

  local state = State.get(player.index)
  if not queued then
    cancel_all(player)
    state = State.get(player.index)
  else
    local limit = settings.get_player_settings(player)["scv-command-queue-limit"].value
    if Queue.depth(state) >= limit then
      player.print({"scv-control.queue-full", limit})
      Logger.write(player, "click", {
        accepted = false,
        queued = true,
        target = PathMath.copy_position(event.cursor_position),
        reason = "queue-full"
      })
      return
    end
  end

  local command = Input.command_from_cursor(state, event.cursor_position, player.surface.index)
  Queue.push(state, command)
  Logger.write(player, "click", {
    accepted = true,
    queued = queued,
    command_id = command.id,
    start = PathMath.copy_position(player.position),
    target = PathMath.copy_position(command.position),
    queue_depth = Queue.depth(state)
  })
  PathRender.draw_command_marker(player, command.position, queued)
  start_next_command(player, state)
end

local function update_player(player, tick)
  local state = State.get(player.index)
  local character = player.character
  if player.controller_type ~= defines.controllers.character
      or not character
      or not character.valid
      or player.vehicle then
    if state.active or #state.queue > 0 then cancel_all(player) end
    return
  end
  if not state.active then
    stop_walking(player)
    start_next_command(player, state)
    return
  end
  if state.active.surface_index ~= player.surface.index then
    cancel_all(player)
    return
  end
  if state.retry_tick and tick >= state.retry_tick then
    Planner.request_active(player, state, "pathfinder-busy-retry")
    return
  end
  if not state.path then
    stop_walking(player)
    return
  end

  local progress, diagnostics = Follower.advance(player, state, state.active.position)
  Logger.write_follower(player, state, progress, diagnostics)
  if progress == "arrived" then
    finish_active(player, state)
    return
  elseif progress == "replan" then
    Planner.request_active(player, state, "endpoint-correction")
    return
  end

  if tick - state.last_stuck_check < Policy.follower.stuck_check_interval then return end
  local stuck_distance = Policy.follower.stuck_distance
  if PathMath.squared_distance(character.position, state.last_position)
      < stuck_distance * stuck_distance then
    state.stuck_retries = state.stuck_retries + 1
    if state.stuck_retries > Policy.follower.max_stuck_retries then
      player.print({"scv-control.stuck"})
      finish_active(player, state)
    else
      Planner.request_active(player, state, "stuck-replan")
    end
  else
    state.stuck_retries = 0
  end
  state.last_position = PathMath.copy_position(character.position)
  state.last_stuck_check = tick
end

script.on_init(State.ensure_storage)
script.on_configuration_changed(State.ensure_storage)

script.on_event("scv-move-command", function(event)
  issue_move_command(event, false)
end)

script.on_event("scv-queue-move-command", function(event)
  issue_move_command(event, true)
end)

script.on_event("scv-stop-command", function(event)
  local player = game.get_player(event.player_index)
  if player then cancel_all(player) end
end)

script.on_event(defines.events.on_script_path_request_finished, function(event)
  Planner.handle_result(event, {
    activate_path = activate_path,
    finish_active = finish_active
  })
end)

script.on_event(defines.events.on_tick, function(event)
  for _, player in pairs(game.connected_players) do
    update_player(player, event.tick)
  end
end)

script.on_event({
  defines.events.on_player_died,
  defines.events.on_player_changed_surface,
  defines.events.on_player_driving_changed_state
}, function(event)
  local player = game.get_player(event.player_index)
  if player then cancel_all(player) end
end)
