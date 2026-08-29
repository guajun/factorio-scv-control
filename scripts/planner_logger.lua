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

return Logger
