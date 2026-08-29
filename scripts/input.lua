local Input = {}

function Input.command_from_cursor(state, cursor_position, surface_index)
  local command = {
    id = state.next_command_id,
    position = {x = cursor_position.x, y = cursor_position.y},
    surface_index = surface_index
  }
  state.next_command_id = state.next_command_id + 1
  return command
end

function Input.rejection_reason(player, event)
  if event.in_gui then return "cursor-in-gui" end
  if player.controller_type ~= defines.controllers.character then return "not-character-controller" end
  if not player.character or not player.character.valid then return "no-valid-character" end
  if player.vehicle then return "driving" end
  if player.opened ~= nil then return "gui-open" end
  if not player.is_cursor_empty() then return "cursor-not-empty" end
  if player.selected ~= nil then return "entity-selected" end
  return nil
end

return Input
