local Fixtures = require("__scv-control-testkit__/calibration/belts/fixtures")
local Probe = require("__scv-control-testkit__/calibration/belts/probe")
local Analysis = require("__scv-control-testkit__/calibration/belts/analysis")
remote.add_interface("scv_test_runner", {active = function() return true end})

local function finish(suite)
  suite.finished = true
  Analysis.apply(suite.cases)
  suite.passed, suite.failed = 0, 0
  for _, case in ipairs(suite.cases) do
    if case.passed then suite.passed = suite.passed + 1 else suite.failed = suite.failed + 1 end
  end
  helpers.write_file("scv-control/calibration/belts.json", helpers.table_to_json({
    schema_version = 1, domain = "belts", fixture_version = Fixtures.version,
    calibration_id = "factorio-native-uniform-belts-v1", factorio_version = script.active_mods.base,
    case_count = #suite.cases, passed = suite.passed, failed = suite.failed, cases = suite.cases,
    duration_ticks = game.tick - suite.started_tick, active_mods = script.active_mods,
    scope = {native_character = true, uniform_motion_field = true, belt_tiers = 3, belt_directions = 4,
      commands_per_field = 4, planner = false, follower = false, equipment_immunity = false,
      entry_exit = false, dynamic_belt_changes = false}
  }), false, 0)
  log("SCV_CALIBRATION_COMPLETE domain=belts passed=" .. suite.passed .. " failed=" .. suite.failed)
end

script.on_init(function()
  game.speed = 8 -- Accelerates wall-clock execution only; measurements use simulation ticks.
  storage.scv_belt_calibration = {started_tick = game.tick, cases = {}, passed = 0, failed = 0, index = 1}
  storage.scv_belt_calibration.probe = Probe.start(Fixtures.cases[1])
end)

script.on_event(defines.events.on_tick, function()
  local suite = storage.scv_belt_calibration
  if suite.finished then return end
  local result = Probe.on_tick(suite.probe)
  if not result then return end
  suite.cases[#suite.cases + 1] = result
  if result.passed then suite.passed = suite.passed + 1 else suite.failed = suite.failed + 1 end
  suite.index = suite.index + 1
  if suite.index > #Fixtures.cases then finish(suite)
  else suite.probe = Probe.start(Fixtures.cases[suite.index]) end
end)
