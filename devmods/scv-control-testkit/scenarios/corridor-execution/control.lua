local Fixtures = require("__scv-control-testkit__/episodes/fixtures/corridor")
local Contracts = require("__scv-control-testkit__/episodes/fixtures/corridor_contracts")
local Adapter = require("__scv-control-testkit__/episodes/adapters/corridor_follower")
local Runner = require("__scv-control-testkit__/episodes/runner")
local World = require("__scv-control-testkit__/episodes/world")
local services = require("__scv-control-testkit__/episodes/corridor_services")

remote.add_interface("scv_test_runner", {active = function() return true end})

local function collect(suite, result)
  result = services.result(result)
  suite.cases[#suite.cases + 1] = result
  if result.passed then suite.passed = suite.passed + 1 else suite.failed = suite.failed + 1 end
end

local function finish(suite)
  suite.finished = true
  helpers.write_file("scv-control/calibration/dynamic.json", helpers.table_to_json({
    schema_version = 1, fixture_version = 1, domain = "dynamic",
    factorio_version = script.active_mods.base, case_count = #suite.cases,
    passed = suite.passed, failed = suite.failed, cases = suite.cases,
    scope = {native_episodes = #Fixtures.cases, real_script_raised_entity_events = true,
      shared_planning_run = true, production_follower = true, production_integration = false,
      transient_steering = false, motion_compensation = false, optional_optimization = false}
  }), false, 0)
  log("SCV_CALIBRATION_COMPLETE domain=dynamic passed=" .. suite.passed .. " failed=" .. suite.failed)
end

script.on_init(function()
  storage.scv_corridor_execution = {cases = {}, index = 1, passed = 0, failed = 0}
end)

script.on_event(defines.events.script_raised_built, function(event)
  local suite = storage.scv_corridor_execution
  if suite and suite.active then Adapter.on_entity_event(suite.active, "script_raised_built", event) end
end)

script.on_event(defines.events.script_raised_destroy, function(event)
  local suite = storage.scv_corridor_execution
  if suite and suite.active then Adapter.on_entity_event(suite.active, "script_raised_destroy", event) end
end)

script.on_event(defines.events.on_script_path_request_finished, function(event)
  local suite = storage.scv_corridor_execution
  if suite and suite.active then
    Runner.handle_path_result(suite.active, Fixtures.cases[suite.index], services, event, game.tick)
  end
end)

script.on_event(defines.events.on_tick, function()
  local suite = storage.scv_corridor_execution
  if suite.finished then return end
  if suite.active and suite.active.result then
    collect(suite, suite.active.result)
    suite.active, suite.index = nil, suite.index + 1
    return
  end
  local fixture = Fixtures.cases[suite.index]
  if not fixture then
    for _, result in ipairs(Contracts.run()) do collect(suite, result) end
    finish(suite)
  elseif not suite.active then
    suite.active = Runner.start(fixture, World.setup(fixture), services, game.tick)
  else
    Runner.update(suite.active, fixture, services, game.tick)
  end
end)
