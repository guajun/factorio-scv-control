local PathRender = {}

local function show_path(player)
  return settings.get_player_settings(player)["scv-show-path"].value
end

function PathRender.draw_command_marker(player, position, queued)
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

function PathRender.clear(state)
  state.path_renderings = state.path_renderings or {}
  for _, object in pairs(state.path_renderings) do
    if object.valid then
      object.destroy()
    end
  end
  state.path_renderings = {}
end

function PathRender.draw(player, state, path)
  PathRender.clear(state)
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
    state.path_renderings[#state.path_renderings + 1] = object
    previous = waypoint
  end
end

return PathRender
