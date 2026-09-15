local Fixtures = {version = 1, distance = 8, corridor_half_width = 0.25, guard_ticks = 1200, cases = {}}
local axes = {{name = "east", direction = 4}, {name = "south", direction = 8},
  {name = "west", direction = 12}, {name = "north", direction = 0}}
for _, belt in ipairs({"transport-belt", "fast-transport-belt", "express-transport-belt"}) do
  for _, axis in ipairs(axes) do
    for _, mode in ipairs({"production-follower", "compensated"}) do
      Fixtures.cases[#Fixtures.cases + 1] = {id = belt .. "-" .. axis.name .. "-cross-" .. mode,
        belt = belt, belt_direction = axis.direction, direction = (axis.direction + 4) % 16,
        mode = mode, relationship = "cross", pair = belt .. "-" .. axis.name .. "-cross"}
    end
  end
  for _, relationship in ipairs({"with", "against"}) do
    Fixtures.cases[#Fixtures.cases + 1] = {id = belt .. "-east-" .. relationship .. "-compensated",
      belt = belt, belt_direction = 4, direction = relationship == "with" and 4 or 12,
      mode = "compensated", relationship = relationship}
  end
end
return Fixtures
