local Logger = {}
local LOG_PATH = "scv-control/planner.jsonl"

function Logger.enabled()
  local interface = remote.interfaces["scv_test_lab"]
  return interface
    and interface.planner_logging_enabled
    and remote.call("scv_test_lab", "planner_logging_enabled")
end

function Logger.write(player, event_type, fields)
  if not player or not Logger.enabled() then
    return
  end

  local record = fields or {}
  record.event = event_type
  record.tick = game.tick
  record.player_index = player.index
  record.surface = player.surface.name
  helpers.write_file(LOG_PATH, helpers.table_to_json(record) .. "\n", true, player.index)
end

function Logger.write_follower(player, state, status, diagnostics)
  local interface = remote.interfaces["scv_test_lab"]
  if not player
      or not interface
      or not interface.follower_trace_enabled
      or not remote.call("scv_test_lab", "follower_trace_enabled") then
    return
  end

  local record = diagnostics or {}
  record.event = "follower-tick"
  record.tick = game.tick
  record.player_index = player.index
  record.command_id = state.active and state.active.id or nil
  record.status = status
  helpers.write_file(
    "scv-control/follower.jsonl",
    helpers.table_to_json(record) .. "\n",
    true,
    player.index
  )
end

return Logger
