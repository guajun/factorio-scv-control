local ARRIVAL_DISTANCE = 0.25
local MIN_WAYPOINT_DISTANCE = 0.3
local SPEED_DISTANCE_MULTIPLIER = 1.5
local STUCK_CHECK_INTERVAL = 30
local STUCK_DISTANCE = 0.05
local MAX_STUCK_RETRIES = 3
local PLANNER_LOG_PATH = "scv-control/planner.jsonl"

local function ensure_storage()
  storage.players = storage.players or {}
  storage.path_requests = storage.path_requests or {}
end

local function player_state(player_index)
  ensure_storage()

  local state = storage.players[player_index]
  if state then
    state.path_renderings = state.path_renderings or {}
    return state
  end

  state = {
    queue = {},
    active = nil,
    path = nil,
    path_renderings = {},
    waypoint_index = 1,
    segment_start = nil,
    pending_request = nil,
    next_command_id = 1,
    stuck_retries = 0,
    last_position = nil,
    last_stuck_check = 0,
    retry_tick = nil
  }
  storage.players[player_index] = state
  return state
end

local function squared_distance(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

local function copy_position(position)
  return {x = position.x, y = position.y}
end

local function distance(a, b)
  return math.sqrt(squared_distance(a, b))
end

local function polyline_distance(start_position, points)
  local total = 0
  local previous = start_position
  for _, point in ipairs(points) do
    total = total + distance(previous, point)
    previous = point
  end
  return total
end

local function planner_logging_enabled()
  local interface = remote.interfaces["scv_test_lab"]
  return interface
    and interface.planner_logging_enabled
    and remote.call("scv_test_lab", "planner_logging_enabled")
end

local function planner_log(player, event_type, fields)
  if not player or not planner_logging_enabled() then
    return
  end

  local record = fields or {}
  record.event = event_type
  record.tick = game.tick
  record.player_index = player.index
  record.surface = player.surface.name
  helpers.write_file(
    PLANNER_LOG_PATH,
    helpers.table_to_json(record) .. "\n",
    true,
    player.index
  )
end

local function stop_walking(player)
  if player.controller_type == defines.controllers.character then
    player.walking_state = {walking = false, direction = defines.direction.north}
  end
end

local function direction_towards(from, to)
  local dx = to.x - from.x
  local dy = to.y - from.y
  local orientation = math.atan2(dx, -dy) / (2 * math.pi) % 1
  local direction_index = math.floor(orientation * 16 + 0.5) % 16
  return direction_index
end

local function movement_tolerance(player)
  return math.max(MIN_WAYPOINT_DISTANCE, player.character_running_speed * SPEED_DISTANCE_MULTIPLIER)
end

local function passed_waypoint(position, segment_start, waypoint)
  if not segment_start then
    return false
  end

  local segment_x = waypoint.x - segment_start.x
  local segment_y = waypoint.y - segment_start.y
  if segment_x == 0 and segment_y == 0 then
    return true
  end

  local beyond_x = position.x - waypoint.x
  local beyond_y = position.y - waypoint.y
  return beyond_x * segment_x + beyond_y * segment_y >= 0
end

local function queue_limit(player)
  return settings.get_player_settings(player)["scv-command-queue-limit"].value
end

local function show_path(player)
  return settings.get_player_settings(player)["scv-show-path"].value
end

local function draw_command_marker(player, position, queued)
  rendering.draw_circle({
    color = queued and {r = 0.2, g = 0.85, b = 1} or {r = 0.2, g = 1, b = 0.35},
    radius = 0.35,
    width = 3,
    filled = false,
    target = position,
    surface = player.surface,
    players = {player.index},
    time_to_live = 90,
    draw_on_ground = true
  })
end

local function clear_path_renderings(state)
  state.path_renderings = state.path_renderings or {}
  for _, object in pairs(state.path_renderings) do
    if object.valid then
      object.destroy()
    end
  end
  state.path_renderings = {}
end

local function draw_path(player, state, path)
  clear_path_renderings(state)
  if not show_path(player) then
    return
  end

  local previous = player.position
  for _, waypoint in ipairs(path) do
    local object = rendering.draw_line({
      color = {r = 0.2, g = 0.85, b = 1, a = 0.65},
      width = 2,
      from = previous,
      to = waypoint,
      surface = player.surface,
      players = {player.index},
      draw_on_ground = true
    })
    table.insert(state.path_renderings, object)
    previous = waypoint
  end
end

local start_next_command

local function clear_active(state)
  clear_path_renderings(state)
  state.active = nil
  state.path = nil
  state.waypoint_index = 1
  state.segment_start = nil
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

local function request_active_path(player, state, reason)
  local character = player.character
  if not character or not character.valid or not state.active then
    return false
  end

  if state.active.surface_index ~= player.surface.index then
    return false
  end

  clear_path_renderings(state)
  local prototype = character.prototype
  local start_position = copy_position(character.position)
  local goal_position = copy_position(state.active.position)
  local request_id = player.surface.request_path({
    bounding_box = prototype.collision_box,
    collision_mask = prototype.collision_mask,
    start = character.position,
    goal = state.active.position,
    force = player.force,
    radius = ARRIVAL_DISTANCE,
    pathfind_flags = {
      prefer_straight_paths = true,
      cache = false
    },
    can_open_gates = true,
    entity_to_ignore = character
  })

  state.pending_request = request_id
  state.path = nil
  state.retry_tick = nil
  storage.path_requests[request_id] = {
    player_index = player.index,
    command_id = state.active.id,
    start_position = start_position,
    goal_position = goal_position,
    reason = reason or "unspecified"
  }
  planner_log(player, "path-request", {
    request_id = request_id,
    command_id = state.active.id,
    reason = reason or "unspecified",
    start = start_position,
    goal = goal_position,
    direct_distance = distance(start_position, goal_position),
    running_speed = player.character_running_speed
  })
  return true
end

start_next_command = function(player, state)
  if state.active or #state.queue == 0 then
    return
  end

  state.active = table.remove(state.queue, 1)
  state.stuck_retries = 0
  state.last_position = {x = player.position.x, y = player.position.y}
  state.last_stuck_check = game.tick

  if not request_active_path(player, state, "command-start") then
    player.print({"scv-control.command-unavailable"})
    clear_active(state)
    start_next_command(player, state)
  end
end

local function cancel_all(player)
  local state = player_state(player.index)
  state.queue = {}
  clear_active(state)
  stop_walking(player)
end

local function command_rejection_reason(player, event)
  if event.in_gui then return "cursor-in-gui" end
  if player.controller_type ~= defines.controllers.character then return "not-character-controller" end
  if not player.character or not player.character.valid then return "no-valid-character" end
  if player.vehicle then return "driving" end
  if player.opened ~= nil then return "gui-open" end
  if not player.is_cursor_empty() then return "cursor-not-empty" end
  if player.selected ~= nil then return "entity-selected" end
  return nil
end

local function issue_move_command(event, queued)
  local player = game.get_player(event.player_index)
  if not player then
    return
  end

  local rejection_reason = command_rejection_reason(player, event)
  if rejection_reason then
    planner_log(player, "click", {
      accepted = false,
      queued = queued,
      target = copy_position(event.cursor_position),
      reason = rejection_reason
    })
    return
  end

  local state = player_state(player.index)
  if not queued then
    cancel_all(player)
    state = player_state(player.index)
  elseif #state.queue + (state.active and 1 or 0) >= queue_limit(player) then
    player.print({"scv-control.queue-full", queue_limit(player)})
    planner_log(player, "click", {
      accepted = false,
      queued = true,
      target = copy_position(event.cursor_position),
      reason = "queue-full"
    })
    return
  end

  local command = {
    id = state.next_command_id,
    position = {x = event.cursor_position.x, y = event.cursor_position.y},
    surface_index = player.surface.index
  }
  state.next_command_id = state.next_command_id + 1
  table.insert(state.queue, command)

  planner_log(player, "click", {
    accepted = true,
    queued = queued,
    command_id = command.id,
    start = copy_position(player.position),
    target = copy_position(command.position),
    queue_depth = #state.queue + (state.active and 1 or 0)
  })

  draw_command_marker(player, command.position, queued)
  start_next_command(player, state)
end

script.on_init(ensure_storage)
script.on_configuration_changed(ensure_storage)

script.on_event("scv-move-command", function(event)
  issue_move_command(event, false)
end)

script.on_event("scv-queue-move-command", function(event)
  issue_move_command(event, true)
end)

script.on_event("scv-stop-command", function(event)
  local player = game.get_player(event.player_index)
  if player then
    cancel_all(player)
  end
end)

script.on_event(defines.events.on_script_path_request_finished, function(event)
  ensure_storage()
  local request = storage.path_requests[event.id]
  storage.path_requests[event.id] = nil
  if not request then
    return
  end

  local player = game.get_player(request.player_index)
  local state = storage.players[request.player_index]
  if not player or not state or not state.active
      or state.active.id ~= request.command_id
      or state.pending_request ~= event.id then
    if player then
      planner_log(player, "path-result", {
        request_id = event.id,
        command_id = request.command_id,
        status = "stale"
      })
    end
    return
  end

  state.pending_request = nil
  if event.try_again_later then
    planner_log(player, "path-result", {
      request_id = event.id,
      command_id = request.command_id,
      status = "busy"
    })
    state.retry_tick = game.tick + 30
    return
  end

  if not event.path then
    planner_log(player, "path-result", {
      request_id = event.id,
      command_id = request.command_id,
      status = "no-path"
    })
    player.print({"scv-control.no-path"})
    finish_active(player, state)
    return
  end

  state.path = {}
  local logged_path = {}
  for _, waypoint in ipairs(event.path) do
    local point = {
      x = waypoint.position.x,
      y = waypoint.position.y
    }
    table.insert(state.path, point)
    table.insert(logged_path, {
      x = point.x,
      y = point.y,
      needs_destroy_to_reach = waypoint.needs_destroy_to_reach
    })
  end
  table.insert(state.path, {
    x = state.active.position.x,
    y = state.active.position.y
  })
  state.waypoint_index = 1
  state.segment_start = {x = player.position.x, y = player.position.y}
  state.last_position = {x = player.position.x, y = player.position.y}
  state.last_stuck_check = game.tick
  local request_start = request.start_position or copy_position(player.position)
  local request_goal = request.goal_position or copy_position(state.active.position)
  local path_distance = polyline_distance(request_start, state.path)
  local direct_distance = distance(request_start, request_goal)
  planner_log(player, "path-result", {
    request_id = event.id,
    command_id = request.command_id,
    status = "success",
    reason = request.reason,
    start = request_start,
    goal = request_goal,
    waypoint_count = #event.path,
    path_distance = path_distance,
    direct_distance = direct_distance,
    detour_ratio = direct_distance > 0 and path_distance / direct_distance or 1,
    path = logged_path
  })
  draw_path(player, state, state.path)
end)

local function update_player(player, tick)
  local state = player_state(player.index)
  local character = player.character

  if player.controller_type ~= defines.controllers.character
      or not character
      or not character.valid
      or player.vehicle then
    if state.active or #state.queue > 0 then
      cancel_all(player)
    end
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
    request_active_path(player, state, "pathfinder-busy-retry")
    return
  end

  if not state.path then
    stop_walking(player)
    return
  end

  local tolerance = movement_tolerance(player)
  local waypoint = state.path[state.waypoint_index]
  while waypoint do
    local is_final_waypoint = state.waypoint_index == #state.path
    local reached = squared_distance(character.position, waypoint) <= tolerance * tolerance
    local passed = not is_final_waypoint
      and passed_waypoint(character.position, state.segment_start, waypoint)
    if not reached and not passed then
      break
    end

    state.segment_start = {x = waypoint.x, y = waypoint.y}
    state.waypoint_index = state.waypoint_index + 1
    waypoint = state.path[state.waypoint_index]
  end

  if not waypoint then
    local arrival_distance = math.max(ARRIVAL_DISTANCE, tolerance)
    if squared_distance(character.position, state.active.position) <= arrival_distance * arrival_distance then
      finish_active(player, state)
    else
      request_active_path(player, state, "endpoint-correction")
    end
    return
  end

  player.walking_state = {
    walking = true,
    direction = direction_towards(character.position, waypoint)
  }

  if tick - state.last_stuck_check < STUCK_CHECK_INTERVAL then
    return
  end

  if squared_distance(character.position, state.last_position) < STUCK_DISTANCE * STUCK_DISTANCE then
    state.stuck_retries = state.stuck_retries + 1
    if state.stuck_retries > MAX_STUCK_RETRIES then
      player.print({"scv-control.stuck"})
      finish_active(player, state)
    else
      request_active_path(player, state, "stuck-replan")
    end
  else
    state.stuck_retries = 0
  end

  state.last_position = {x = character.position.x, y = character.position.y}
  state.last_stuck_check = tick
end

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
  if player then
    cancel_all(player)
  end
end)
