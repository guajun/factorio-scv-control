local Capture = require("interchange.capture")
local Replay = require("interchange.replay")
local Imports = require("interchange.imported_plans")
local Runtime = {}

local function interactive()
  return remote.interfaces.scv_test_interactive ~= nil
    and remote.interfaces.scv_test_runner == nil
end

local function restore_player(player, state)
  if not state or not state.return_to then return end
  local old = state.return_to
  if old.character and old.character.valid then
    player.set_controller({type = defines.controllers.character, character = old.character})
  else
    player.set_controller({type = defines.controllers.spectator})
    player.teleport(old.position, old.surface)
  end
  state.return_to = nil
end

function Runtime.add_commands()
  if not interactive() then return end
  commands.add_command("scv-nav-capture", "Export static fixture or live geometry: all | fixture-id | live goal-x goal-y [padding]", function(command)
    if not command.player_index then return end
    local player = game.get_player(command.player_index)
    local parameter = command.parameter or "all"
    local bundle
    if parameter:match("^live%s") then
      local x, y, padding = parameter:match("^live%s+([%d%.%-]+)%s+([%d%.%-]+)%s*([%d%.]*)$")
      x, y, padding = tonumber(x), tonumber(y), tonumber(padding) or 8
      if not x or not y or padding < 1 or padding > 32 or not player.character then
        player.print("Usage: /scv-nav-capture live goal-x goal-y [padding 1..32]; a character is required.")
        return
      end
      local start, goal = player.character.position, {x = x, y = y}
      local bounds = {
        {math.floor(math.min(start.x, x) - padding), math.floor(math.min(start.y, y) - padding)},
        {math.ceil(math.max(start.x, x) + padding), math.ceil(math.max(start.y, y) + padding)}
      }
      local snapshot, query = Capture.live(player.surface, player.character, start, goal, bounds, {
        session_id = "gui:" .. tostring(player.index) .. ":" .. tostring(game.tick)
      })
      if not snapshot then player.print(query.code .. ": " .. query.message); return end
      bundle = {protocol = Capture.PROTOCOL, kind = "capture-bundle", cases = {{id = "live-" .. game.tick, snapshot = snapshot, query = query}}}
    else
      bundle = Capture.bundle(parameter == "all" and nil or {parameter})
    end
    local path, write_error = Capture.write(bundle, "gui-capture-" .. tostring(game.tick), player.index)
    if not path then player.print("Capture failed: " .. tostring(write_error and write_error.code)); return end
    player.print("Captured " .. #bundle.cases .. " case(s): script-output/" .. path)
    for _, item in ipairs(bundle.errors or {}) do player.print(item.id .. ": " .. item.error.code) end
  end)
  commands.add_command("scv-nav-replay", "Replay imported solver case: list | case-id | return", function(command)
    if not command.player_index then return end
    local player = game.get_player(command.player_index)
    storage.scv_interchange_gui = storage.scv_interchange_gui or {}
    local state = storage.scv_interchange_gui
    local parameter = command.parameter or "list"
    if parameter == "return" then
      if state.session and state.session.actor.valid then
        state.session.actor.walking_state = {walking = false, direction = defines.direction.north}
      end
      restore_player(player, state)
      state.session = nil
      return
    end
    if parameter == "list" then
      local ids = {}
      for _, item in ipairs(Imports.cases) do ids[#ids + 1] = item.id end
      player.print(#ids == 0 and "No imported plans. Generate interchange/imported_plans.lua and reload this save."
        or "Imported cases: " .. table.concat(ids, ", "))
      return
    end
    local selected
    for _, item in ipairs(Imports.cases) do if item.id == parameter then selected = item; break end end
    if not selected then player.print("Unknown imported case: " .. parameter); return end
    if state.player_index and state.player_index ~= player.index and state.return_to then
      player.print("Another player is using the replay surface."); return
    end
    restore_player(player, state)
    local session, replay_error = Replay.prepare(selected)
    if not session then player.print(replay_error.code .. ": " .. replay_error.message); return end
    Replay.start(session)
    Replay.draw(session, player.index)
    state.player_index = player.index
    state.return_to = {character = player.character, surface = player.surface, position = player.position}
    player.set_controller({type = defines.controllers.spectator})
    player.teleport(selected.query.start, session.surface)
    state.session, state.reported = session, false
    player.print("Orange: imported route; cyan: accepted route. /scv-nav-replay return restores your character.")
  end)
end

Runtime.events = {
  [defines.events.on_tick] = function(event)
    local state = storage.scv_interchange_gui
    if not state or not state.session then return end
    local session = state.session
    Replay.update(session, event.tick)
    if session.status ~= "moving" and not state.reported then
      state.reported = true
      local report = Replay.report(session)
      helpers.write_file("scv-control/navigation/gui-replay.json", helpers.table_to_json(report), false, state.player_index)
      local player = game.get_player(state.player_index)
      if player then player.print("Replay " .. session.status .. ": " .. (session.reason or "") .. ". Report: scv-control/navigation/gui-replay.json") end
    end
  end
}

return Runtime
