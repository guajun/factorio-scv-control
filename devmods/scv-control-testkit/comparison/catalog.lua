local Fixtures = require('pathfinding.fixtures')
local Serializable = require('__factorio-scv-control__/scripts/navigation/serializable')
local Catalog = {VERSION = Fixtures.VERSION}
function Catalog.get(id)
  local fixture = Fixtures.get(id)
  if not fixture then return nil end
  local saved = assert(Serializable.copy(fixture))
  return {id = saved.id, domain = 'static', fixture_version = Catalog.VERSION,
    title = saved.title, category = saved.category, bounds = {
      left_top = {x = saved.bounds[1][1], y = saved.bounds[1][2]},
      right_bottom = {x = saved.bounds[2][1], y = saved.bounds[2][2]}},
    start = saved.start, goal = saved.goal, expected_path = saved.expected_path,
    fixture = saved, scope = {fixture_definition = saved,
      outside_navigation_bounds = 'native-out-of-map', source = 'saved-native-static-fixture'}}
end
function Catalog.describe()
  local result = {}
  for _, fixture in ipairs(Fixtures.list()) do result[#result + 1] = Catalog.get(fixture.id) end
  return result
end
return Catalog
