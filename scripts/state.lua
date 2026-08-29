local State = {}

function State.ensure_storage()
  storage.players = storage.players or {}
  storage.path_requests = storage.path_requests or {}
end

function State.get(player_index)
  State.ensure_storage()
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
    pending_optimization = nil,
    next_command_id = 1,
    stuck_retries = 0,
    last_position = nil,
    last_stuck_check = 0,
    retry_tick = nil
  }
  storage.players[player_index] = state
  return state
end

return State
