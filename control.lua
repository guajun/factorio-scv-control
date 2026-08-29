local ARRIVAL_DISTANCE = 0.25
local MIN_WAYPOINT_DISTANCE = 0.3
local SPEED_DISTANCE_MULTIPLIER = 1.5
local STUCK_CHECK_INTERVAL = 30
local STUCK_DISTANCE = 0.05
local MAX_STUCK_RETRIES = 3

local function ensure_storage()
  storage.players = storage.players or {}
  storage.path_requests = storage.path_requests or {}
end

local function player_state(player_index)
  ensure_storage()

  local state = storage.players[player_index]
  if state then
    return state
  end

  state = {
    queue = {},
    active = nil,
    path = nil,
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

local function draw_path(player, path)
  if not show_path(player) then
    return
  end

  local previous = player.position
  for _, waypoint in ipairs(path) do
    rendering.draw_line({
      color = {r = 0.2, g = 0.85, b = 1, a = 0.65},
      width = 2,
      from = previous,
      to = waypoint,
      surface = player.surface,
      players = {player.index},
      time_to_live = 180,
      draw_on_ground = true
    })
    previous = waypoint
  end
end

local start_next_command

local function clear_active(state)
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

local function request_active_path(player, state)
  local character = player.character
  if not character or not character.valid or not state.active then
    return false
  end

  if state.active.surface_index ~= player.surface.index then
    return false
  end

  local prototype = character.prototype
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
    command_id = state.active.id
  }
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

  if not request_active_path(player, state) then
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

local function can_accept_ground_command(player, event)
  return not event.in_gui
    and player.controller_type == defines.controllers.character
    and player.character
    and player.character.valid
    and not player.vehicle
    and player.opened == nil
    and player.is_cursor_empty()
    and player.selected == nil
end

local function issue_move_command(event, queued)
  local player = game.get_player(event.player_index)
  if not player or not can_accept_ground_command(player, event) then
    return
  end

  local state = player_state(player.index)
  if not queued then
    cancel_all(player)
    state = player_state(player.index)
  elseif #state.queue + (state.active and 1 or 0) >= queue_limit(player) then
    player.print({"scv-control.queue-full", queue_limit(player)})
    return
  end

  local command = {
    id = state.next_command_id,
    position = {x = event.cursor_position.x, y = event.cursor_position.y},
    surface_index = player.surface.index
  }
  state.next_command_id = state.next_command_id + 1
  table.insert(state.queue, command)

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
    return
  end

  state.pending_request = nil
  if event.try_again_later then
    state.retry_tick = game.tick + 30
    return
  end

  if not event.path then
    player.print({"scv-control.no-path"})
    finish_active(player, state)
    return
  end

  state.path = {}
  for _, waypoint in ipairs(event.path) do
    table.insert(state.path, {
      x = waypoint.position.x,
      y = waypoint.position.y
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
  draw_path(player, state.path)
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
    request_active_path(player, state)
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
      request_active_path(player, state)
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
      request_active_path(player, state)
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
