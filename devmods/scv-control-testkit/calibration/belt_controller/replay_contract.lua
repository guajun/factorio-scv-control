local Probe = require("calibration.belt_controller.probe")
local Motion = require("__factorio-scv-control__/scripts/navigation/motion/measured_uniform")
local Contract = {}

function Contract.run(source)
  local saved = {fixture = source.fixture, actor = source.actor, surface = source.surface,
    field = {id = "stale-model"}, assertions = {{name = "stale-pass", passed = true}},
    timeline = {{tick = 999, event = "stale"}}, samples = 999,
    metrics = {model_id = "stale-model", actor_profile = "stale-profile"}, result = {passed = true}}
  local id, calibration = Motion.id, Motion.calibration_id
  Motion.id, Motion.calibration_id = "current-replay-regression-model", "current-replay-regression-calibration"
  local command = {start = {x = 0.5, y = 0.5}, goal = {x = 0.5, y = 8.5}, corridor_half_width = 0.3}
  local ok, fresh = pcall(Probe.arm, saved, game.tick, command)
  Motion.id, Motion.calibration_id = id, calibration
  if not ok then error(fresh) end
  return {
    {name = "replay-model-provenance-comes-from-current-field",
      passed = fresh.metrics.model_id == fresh.field.id and fresh.metrics.model_id == "current-replay-regression-model"
        and fresh.metrics.calibration_id == "current-replay-regression-calibration"
        and fresh.metrics.actor_profile == fresh.field.spec.actor_profile
        and fresh.metrics.model_spec.running_speed == source.actor.character_running_speed},
    {name = "replay-discards-stored-verdicts-samples-and-terminal",
      passed = #fresh.assertions == 0 and #fresh.timeline == 0 and fresh.samples == 0 and fresh.result == nil},
    {name = "replay-refresh-keeps-native-objects-and-source-constraint",
      passed = fresh.actor == source.actor and fresh.surface == source.surface
        and fresh.saved_command.goal.y == 8.5 and fresh.metrics.corridor_half_width == 0.3}
  }
end

return Contract
