local Tests = require("__scv-control-testkit__/scenarios/automated/interchange_tests")

remote.add_interface("scv_test_runner", {active = function() return true end})

local function expect(name, condition, details)
  local suite = storage.scv_interchange_suite
  local passed = condition == true
  suite.results[#suite.results + 1] = {name = name, passed = passed, details = details}
  if passed then suite.passed = suite.passed + 1 else suite.failed = suite.failed + 1 end
end

local function finish()
  local suite = storage.scv_interchange_suite
  suite.finished = true
  helpers.write_file("scv-control/navigation/interchange-results.json", helpers.table_to_json({
    schema_version = 1, passed = suite.passed, failed = suite.failed, results = suite.results,
    duration_ticks = game.tick - suite.started_tick
  }), false, 0)
  log("SCV_INTERCHANGE_COMPLETE passed=" .. suite.passed .. " failed=" .. suite.failed)
end

script.on_init(function()
  storage.scv_interchange_suite = {started_tick = game.tick, results = {}, passed = 0, failed = 0}
  storage.scv_interchange_suite.done = Tests.start(expect)
end)

script.on_event(defines.events.on_tick, function(event)
  local suite = storage.scv_interchange_suite
  if suite.finished then return end
  if suite.done or Tests.on_tick(expect, event.tick) then finish() end
  -- Each replay already has its own failure guard. This only catches broken scheduling.
  if not suite.finished and event.tick - suite.started_tick > 50000 then
    expect("interchange.scheduler-guard", false, {reason = "suite-did-not-terminate"})
    finish()
  end
end)
