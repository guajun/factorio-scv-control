local Adapters = require("savebench.adapters")
local Fixtures = require("calibration.gate_actions.fixtures")
local PathSmoothing = require("__factorio-scv-control__/scripts/path_smoothing")
local Contract = {}

function Contract.run(source)
  local saved = {fixture = source.fixture, actor = source.actor, gate = source.gate, wall = source.wall,
    surface = source.surface, start = source.start, goal = source.goal,
    assertions = {{name = "production-validator-remains-conservative-on-closed-gate", passed = true}},
    metrics = {running_speed = 999}, timeline = {{details = {opening_calibration = {opening_ticks = 999}}}},
    finished = true, result = {passed = true}, action = {opening_ticks = 999}}
  local validator, calibration = PathSmoothing.path_is_clear, Fixtures.opening
  local calls = 0
  -- Simulate a changed implementation against the SAME native gate. It now
  -- returns the opposite validation answer; replay must expose that failure,
  -- never report the previously stored passing boolean. Restore before any
  -- movement occurs, including if arm throws.
  PathSmoothing.path_is_clear = function() calls = calls + 1; return true end
  Fixtures.opening = {factorio_version = calibration.factorio_version,
    prototype = calibration.prototype, opening_ticks = calibration.opening_ticks + 3}
  local prepared = {descriptor = {domain = "gate-actions", start = source.start, goal = source.goal},
    probe = saved, actor = source.actor, surface = source.surface}
  local ok, detail = pcall(Adapters.begin, prepared, game.tick)
  PathSmoothing.path_is_clear, Fixtures.opening = validator, calibration
  if not ok then error(detail) end
  local fresh = prepared.probe
  local current_verdict
  for _, assertion in ipairs(fresh.assertions) do
    if assertion.name == "production-validator-remains-conservative-on-closed-gate" then
      current_verdict = assertion.passed
    end
  end
  return {
    {name = "replay-current-validator-failure-cannot-inherit-saved-pass", passed = calls == 1 and current_verdict == false},
    {name = "replay-evidence-uses-current-opening-calibration",
      passed = fresh.action.opening_ticks == calibration.opening_ticks + 3
        and fresh.timeline[1].details.opening_calibration.opening_ticks == fresh.action.opening_ticks},
    {name = "replay-clears-stale-terminal-and-derived-metrics",
      passed = fresh.result == nil and fresh.finished == nil and fresh.metrics.running_speed == source.actor.character_running_speed},
    {name = "replay-evidence-refresh-keeps-native-objects-and-task",
      passed = fresh.gate == source.gate and fresh.actor == source.actor and fresh.surface == source.surface
        and fresh.start.x == source.start.x and fresh.goal.x == source.goal.x}
  }
end

return Contract
