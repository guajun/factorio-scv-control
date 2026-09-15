local Gates = require("calibration.gate_actions.fixtures")
local Belts = require("calibration.belt_controller.fixtures")
local Dynamic = require("episodes.fixtures.corridor")
local Trajectory = require("__factorio-scv-control__/scripts/trajectory")

local Catalog = {VERSION = 1, cases = {}}
local by_id = {}
local function point(p) return {x = p.x, y = p.y} end
local function bounds(x, y)
  return {left_top = {x = -x, y = -y}, right_bottom = {x = x, y = y}}
end
local function append(domain, fixtures, area, endpoints, profile)
  for _, fixture in ipairs(fixtures.cases) do
    assert(not by_id[fixture.id], "duplicate savebench case: " .. fixture.id)
    local start, goal = endpoints(fixture)
    local case = {id = fixture.id, domain = domain, fixture_version = fixtures.version,
      bounds = area, start = start, goal = goal, fixture = fixture,
      scope = {fixture_definition = fixture, execution_profile = profile,
        native_execution = true, production_profile_modified = false}}
    Catalog.cases[#Catalog.cases + 1], by_id[case.id] = case, case
  end
end

append("gate-actions", Gates, bounds(24, 20), function(fixture)
  return {x = fixture.start_x or -12.5, y = 0.5}, {x = 12.5, y = 0.5}
end, "authored-gate-action-production-follower")
append("dynamic", Dynamic, bounds(32, 16), function(fixture)
  return point(fixture.start), point(fixture.goal)
end, "shared-PlanningRun-corridor-Follower")
append("belt-controller", Belts, bounds(20, 20), function(fixture)
  local axis = Trajectory.direction_vector(fixture.direction)
  return {x = 0.5, y = 0.5},
    {x = 0.5 + Belts.distance * axis.x, y = 0.5 + Belts.distance * axis.y}
end, "authored-measured-uniform-control-or-production-follower")
for _, case in ipairs(Catalog.cases) do
  if case.domain == "belt-controller" then
    case.scope.execution_constraints = {corridor_half_width = Belts.corridor_half_width}
  end
end

function Catalog.get(id) return by_id[id] end
function Catalog.describe()
  local output = {}
  for _, case in ipairs(Catalog.cases) do
    output[#output + 1] = {id = case.id, domain = case.domain,
      fixture_version = case.fixture_version, bounds = case.bounds,
      start = case.start, goal = case.goal, execution_profile = case.scope.execution_profile}
  end
  return output
end

return Catalog
