local Fixtures = require("__scv-control-testkit__/calibration/belt_controller/fixtures")
local Probe = require("__scv-control-testkit__/calibration/belt_controller/probe")
local ModelTests = require("__scv-control-testkit__/calibration/belt_controller/model_tests")
remote.add_interface("scv_test_runner", {active = function() return true end})

local function finish(suite)
  suite.finished = true
  local pairs_by_id = {}
  for _, case in ipairs(suite.cases) do
    local pair = case.metrics.pair
    if pair then
      pairs_by_id[pair] = pairs_by_id[pair] or {}
      pairs_by_id[pair][case.metrics.mode] = case
    end
  end
  for _, pair in pairs(pairs_by_id) do
    local baseline, controlled = pair["production-follower"], pair.compensated
    local reduced = controlled.metrics.max_cross_track_error < baseline.metrics.max_cross_track_error
    controlled.assertions[#controlled.assertions + 1] = {name = "same-geometry-less-drift-than-production-follower", passed = reduced}
    controlled.passed = controlled.passed and reduced
    controlled.metrics.baseline = {id = baseline.id, actual_travel_ticks = baseline.metrics.actual_travel_ticks,
      max_cross_track_error = baseline.metrics.max_cross_track_error, endpoint_error = baseline.metrics.endpoint_error,
      direction_switches = baseline.metrics.direction_switches}
  end
  local passed, failed = 0, 0
  for _, case in ipairs(suite.cases) do
    if case.passed then passed = passed + 1 else failed = failed + 1 end
  end
  helpers.write_file("scv-control/calibration/belt-controller.json", helpers.table_to_json({
    schema_version = 1, fixture_version = Fixtures.version, domain = "belt-controller",
    factorio_version = script.active_mods.base, calibration_id = "uniform-belt-controller-v1",
    case_count = #suite.cases, passed = passed, failed = failed, cases = suite.cases,
    duration_ticks = game.tick - suite.started_tick, active_mods = script.active_mods,
    scope = {uniform_field = true, native_cross_belt = true, current_follower_control = true,
      native_aligned_and_opposed = true, directed_cost_model = true, cost_aware_search = false,
      entry_exit = false, dynamic_belt_changes = false, immunity = false, turns_splitters = false,
      production_profile = false, stationary_goal_holding = false}
  }), false, 0)
  log("SCV_CALIBRATION_COMPLETE domain=belt-controller passed=" .. passed .. " failed=" .. failed)
end

script.on_init(function()
  game.speed = 8
  storage.scv_belt_controller = {started_tick = game.tick, index = 1, cases = ModelTests.run()}
  storage.scv_belt_controller.probe = Probe.start(Fixtures.cases[1])
end)
script.on_event(defines.events.on_tick, function()
  local suite = storage.scv_belt_controller
  if suite.finished then return end
  local result = Probe.on_tick(suite.probe)
  if not result then return end
  suite.cases[#suite.cases + 1] = result
  suite.index = suite.index + 1
  if suite.index > #Fixtures.cases then finish(suite)
  else suite.probe = Probe.start(Fixtures.cases[suite.index]) end
end)
