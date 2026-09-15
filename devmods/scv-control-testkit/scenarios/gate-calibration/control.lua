local Fixtures = require("__scv-control-testkit__/calibration/gates/fixtures")
local Probe = require("__scv-control-testkit__/calibration/gates/probe")

remote.add_interface("scv_test_runner", {active = function() return true end})

local function finish(suite)
  suite.finished = true
  helpers.write_file("scv-control/calibration/gates.json", helpers.table_to_json({
    schema_version = 1, domain = "gates", fixture_version = Fixtures.version,
    case_count = #suite.cases, passed = suite.passed, failed = suite.failed,
    cases = suite.cases, duration_ticks = game.tick - suite.started_tick,
    factorio_version = script.active_mods.base,
    scope = {real_gate_entities = true, native_character = true, planner = false,
      route_actions = false, circuit_control = false, force_relations = "same-force-and-enemy-only"}
  }), false, 0)
  log("SCV_CALIBRATION_COMPLETE domain=gates passed=" .. suite.passed .. " failed=" .. suite.failed)
end

script.on_init(function()
  storage.scv_gate_calibration = {started_tick = game.tick, cases = {}, passed = 0, failed = 0, index = 1}
end)

script.on_event(defines.events.on_tick, function()
  local suite = storage.scv_gate_calibration
  if suite.finished then return end
  if not suite.probe then
    suite.probe = Probe.start(Fixtures.cases[1], 1)
    return
  end
  local result = Probe.on_tick(suite.probe)
  if not result then return end
  suite.cases[#suite.cases + 1] = result
  if result.passed then suite.passed = suite.passed + 1 else suite.failed = suite.failed + 1 end
  suite.index = suite.index + 1
  if suite.index > #Fixtures.cases then finish(suite) else suite.probe = Probe.start(Fixtures.cases[suite.index], suite.index) end
end)
