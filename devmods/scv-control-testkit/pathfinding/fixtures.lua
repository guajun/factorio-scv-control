local Fixtures = {}

Fixtures.VERSION = 2
Fixtures.AREA = {{-64, -32}, {64, 32}}

local definitions = {
  {
    id = "open-diagonal",
    title = "Open diagonal",
    category = "open",
    bounds = {{-8, -8}, {32, 24}},
    start = {x = 0, y = 0},
    goal = {x = 24, y = 14},
    expected_path = true,
    walls = {}
  },
  {
    id = "long-wall-return",
    title = "Long wall, return across top wall",
    category = "captured-regression",
    bounds = {{-48, -16}, {0, 8}},
    start = {x = -33.8984375, y = -9.01953125},
    goal = {x = -27.6796875, y = -4.16796875},
    expected_path = true,
    walls = {
      {from = {x = -42, y = -12}, to = {x = -8, y = -12}},
      {from = {x = -42, y = -6}, to = {x = -8, y = -6}}
    }
  },
  {
    id = "long-wall-enter",
    title = "Long wall, enter corridor",
    category = "captured-regression",
    bounds = {{-48, -16}, {0, 8}},
    start = {x = -28.55078125, y = -0.12109375},
    goal = {x = -30.12109375, y = -9.07421875},
    expected_path = true,
    walls = {
      {from = {x = -42, y = -12}, to = {x = -8, y = -12}},
      {from = {x = -42, y = -6}, to = {x = -8, y = -6}}
    }
  },
  {
    id = "narrow-corridor",
    title = "Straight narrow corridor",
    category = "clearance",
    bounds = {{-48, -16}, {0, 0}},
    start = {x = -40, y = -9},
    goal = {x = -10, y = -9},
    expected_path = true,
    walls = {
      {from = {x = -42, y = -12}, to = {x = -8, y = -12}},
      {from = {x = -42, y = -6}, to = {x = -8, y = -6}}
    }
  },
  {
    id = "u-trap",
    title = "U-shaped cul-de-sac",
    category = "topology",
    bounds = {{-16, -12}, {24, 12}},
    start = {x = 0, y = 0},
    goal = {x = 16, y = 0},
    expected_path = true,
    walls = {
      {from = {x = -6, y = -6}, to = {x = 6, y = -6}},
      {from = {x = -6, y = 6}, to = {x = 6, y = 6}},
      {from = {x = 6, y = -6}, to = {x = 6, y = 6}}
    }
  },
  {
    id = "slalom",
    title = "Alternating gates",
    category = "multi-obstacle",
    bounds = {{-4, -12}, {36, 12}},
    start = {x = 0, y = 0},
    goal = {x = 32, y = 0},
    expected_path = true,
    walls = {
      {from = {x = 6, y = -10}, to = {x = 6, y = 4}},
      {from = {x = 12, y = -4}, to = {x = 12, y = 10}},
      {from = {x = 18, y = -10}, to = {x = 18, y = 4}},
      {from = {x = 24, y = -4}, to = {x = 24, y = 10}}
    }
  },
  {
    id = "captured-slalom-return",
    title = "Captured reverse slalom with a late portal switch",
    category = "captured-regression",
    bounds = {{5, -15}, {42, 2}},
    start = {x = 38.2265625, y = -12.65625},
    goal = {x = 7.70703125, y = -1.51171875},
    expected_path = true,
    walls = {
      {from = {x = 12, y = -9}, to = {x = 12, y = -2}},
      {from = {x = 18, y = -12}, to = {x = 18, y = -5}},
      {from = {x = 24, y = -9}, to = {x = 24, y = -2}},
      {from = {x = 30, y = -12}, to = {x = 30, y = -5}},
      {from = {x = 36, y = -9}, to = {x = 36, y = -2}}
    }
  },
  {
    id = "gate-open",
    title = "Dynamic wall with open gate",
    category = "dynamic-static",
    bounds = {{-4, -12}, {24, 12}},
    start = {x = 0, y = 0},
    goal = {x = 20, y = 0},
    expected_path = true,
    walls = {
      {from = {x = 10, y = -8}, to = {x = 10, y = -2}},
      {from = {x = 10, y = 2}, to = {x = 10, y = 8}}
    }
  },
  {
    id = "gate-closed",
    title = "Dynamic wall after gate closes",
    category = "dynamic-static",
    bounds = {{-4, -12}, {24, 12}},
    start = {x = 0, y = 0},
    goal = {x = 20, y = 0},
    expected_path = true,
    walls = {
      {from = {x = 10, y = -8}, to = {x = 10, y = 8}}
    }
  },
  {
    id = "unreachable-box",
    title = "Fully enclosed target",
    category = "unreachable",
    bounds = {{-8, -8}, {20, 20}},
    start = {x = 0, y = 0},
    goal = {x = 10, y = 10},
    expected_path = false,
    walls = {
      {from = {x = 6, y = 6}, to = {x = 14, y = 6}},
      {from = {x = 6, y = 14}, to = {x = 14, y = 14}},
      {from = {x = 6, y = 7}, to = {x = 6, y = 13}},
      {from = {x = 14, y = 7}, to = {x = 14, y = 13}}
    }
  }
}

local by_id = {}
for _, fixture in ipairs(definitions) do by_id[fixture.id] = fixture end

local function create_wall(surface, position)
  local wall = surface.create_entity({
    name = "stone-wall",
    position = position,
    force = "neutral"
  })
  if wall then
    wall.destructible = false
    wall.minable = false
  end
end

local function each_line_position(line, callback)
  local dx = line.to.x == line.from.x and 0 or (line.to.x > line.from.x and 1 or -1)
  local dy = line.to.y == line.from.y and 0 or (line.to.y > line.from.y and 1 or -1)
  local x = line.from.x
  local y = line.from.y
  while true do
    callback({x = x, y = y})
    if x == line.to.x and y == line.to.y then return end
    x = x + dx
    y = y + dy
  end
end

function Fixtures.list()
  return definitions
end

function Fixtures.get(id)
  return by_id[id]
end

function Fixtures.clear(surface)
  for _, entity in pairs(surface.find_entities(Fixtures.AREA)) do
    entity.destroy()
  end
  surface.destroy_decoratives({area = Fixtures.AREA})
  rendering.clear()
end

function Fixtures.build(surface, fixture)
  Fixtures.clear(surface)
  local tiles = {}
  for x = Fixtures.AREA[1][1], Fixtures.AREA[2][1] - 1 do
    for y = Fixtures.AREA[1][2], Fixtures.AREA[2][2] - 1 do
      tiles[#tiles + 1] = {name = "refined-concrete", position = {x, y}}
    end
  end
  surface.set_tiles(tiles, true, false, false, false)
  for _, line in ipairs(fixture.walls) do
    each_line_position(line, function(position) create_wall(surface, position) end)
  end
end

return Fixtures
