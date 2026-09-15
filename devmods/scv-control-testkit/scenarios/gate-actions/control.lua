local Fixtures = require("__scv-control-testkit__/calibration/gate_actions/fixtures")
local Probe = require("__scv-control-testkit__/calibration/gate_actions/probe")

remote.add_interface("scv_test_runner", {active = function() return true end})
script.on_init(function()
  storage.scv_gate_actions = {started_tick = game.tick, cases = {}, passed = 0, failed = 0, index = 1}
end)
script.on_event(defines.events.on_tick, function()
  local suite = storage.scv_gate_actions
  if suite.finished then return end
  if not suite.probe then suite.probe = Probe.start(Fixtures.cases[1], 1); return end
  local result = Probe.on_tick(suite.probe)
  if not result then return end
  suite.cases[#suite.cases + 1] = result
  if result.passed then suite.passed = suite.passed + 1 else suite.failed = suite.failed + 1 end
  suite.index = suite.index + 1
  if suite.index <= #Fixtures.cases then suite.probe = Probe.start(Fixtures.cases[suite.index], suite.index); return end
  suite.finished = true
  helpers.write_file("scv-control/calibration/gate-actions.json", helpers.table_to_json({
    schema_version = 1, fixture_version = Fixtures.version, domain = "gate-actions",
    factorio_version = script.active_mods.base, case_count = #suite.cases,
    passed = suite.passed, failed = suite.failed, cases = suite.cases,
    duration_ticks = game.tick - suite.started_tick,
    scope = {real_gate_entities = true, native_follower = true, route_actions = true,
      planner = false, production_validator_support = false, circuit_support = "explicit-rejection",
      force_relations = "same-force-only", geometry = "single-gate-cardinal-crossing"}
  }), false, 0)
  log("SCV_CALIBRATION_COMPLETE domain=gate-actions passed=" .. suite.passed .. " failed=" .. suite.failed)
end)
