local Baseline = require("episodes.fixtures.baseline")

local Catalog = {}
local fixtures = {}
local by_id = {}

local function add_module(module)
  for _, fixture in ipairs(module.fixtures or {}) do
    fixtures[#fixtures + 1] = fixture
    by_id[fixture.id] = fixture
  end
end

add_module(Baseline)

function Catalog.list()
  return fixtures
end

function Catalog.get(id)
  return by_id[id]
end

return Catalog
