-- Frozen native-motion measurements. No planner/cost-model policy is tested here.
local Fixtures = {version = 1, progress_distance = 6, guard_ticks = 1200, cases = {}}
local axes = {
  {name = "east", x = 1, y = 0, direction = 4},
  {name = "south", x = 0, y = 1, direction = 8},
  {name = "west", x = -1, y = 0, direction = 12},
  {name = "north", x = 0, y = -1, direction = 0}
}
local commands = {{name = "with", offset = 0}, {name = "against", offset = 8},
  {name = "across", offset = 4}, {name = "diagonal", offset = 2}}
for direction = 0, 14, 2 do
  local angle = direction * math.pi / 8
  Fixtures.cases[#Fixtures.cases + 1] = {id = "ground-direction-" .. direction,
    belt = "none", belt_direction = 0, belt_axis = {x = 0, y = 0}, command = "ground",
    direction = direction, command_axis = {x = math.sin(angle), y = -math.cos(angle)}}
end
for _, axis in ipairs(axes) do
  for _, belt in ipairs({"transport-belt", "fast-transport-belt", "express-transport-belt"}) do
    for _, command in ipairs(commands) do
      local direction = (axis.direction + command.offset) % 16
      local angle = direction * math.pi / 8
      Fixtures.cases[#Fixtures.cases + 1] = {
        id = belt .. "-" .. axis.name .. "-" .. command.name,
        belt = belt, belt_direction = axis.direction, belt_axis = {x = axis.x, y = axis.y},
        command = command.name, direction = direction,
        command_axis = {x = math.sin(angle), y = -math.cos(angle)}
      }
    end
  end
end
return Fixtures
