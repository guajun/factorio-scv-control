local Actions = require("episodes.actions")
local Util = require("episodes.util")

local World = {}
local SURFACE_NAME = "scv-navigation-episodes"
local AREA = {{-32, -16}, {32, 16}}

local function ensure_surface()
  local surface = game.get_surface(SURFACE_NAME)
  if not surface then
    surface = game.create_surface(SURFACE_NAME, {
      autoplace_controls = {},
      default_enable_all_autoplace_controls = false
    })
  end
  surface.request_to_generate_chunks({0, 0}, 3)
  surface.force_generate_chunk_requests()
  surface.freeze_daytime = true
  surface.daytime = 0
  surface.always_day = true
  surface.peaceful_mode = true
  return surface
end

local function reset_surface(surface)
  for _, entity in pairs(surface.find_entities(AREA)) do
    entity.destroy()
  end
  surface.destroy_decoratives({area = AREA})
  local tiles = {}
  for x = AREA[1][1], AREA[2][1] - 1 do
    for y = AREA[1][2], AREA[2][2] - 1 do
      tiles[#tiles + 1] = {name = "refined-concrete", position = {x, y}}
    end
  end
  surface.set_tiles(tiles, true, false, false, false)
end

function World.setup(fixture)
  local surface = ensure_surface()
  reset_surface(surface)
  for _, line in ipairs(fixture.world and fixture.world.walls or {}) do
    Actions.each_line_position(line, function(position)
      Actions.create_entity(surface, {
        name = "stone-wall",
        position = position,
        force = "neutral"
      })
    end)
  end
  for _, entity in ipairs(fixture.world and fixture.world.entities or {}) do
    Actions.create_entity(surface, entity)
  end
  local actor = surface.create_entity({
    name = "character",
    position = fixture.start,
    force = "player"
  })
  if not actor then error("failed to create episode actor for " .. fixture.id) end
  return {
    surface = surface,
    actor = actor,
    start = Util.copy_position(actor.position)
  }
end

function World.surface_name()
  return SURFACE_NAME
end

return World
