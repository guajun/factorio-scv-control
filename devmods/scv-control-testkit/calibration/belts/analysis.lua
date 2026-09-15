-- Native fixed-point resolution bounds rotation/effect assertions. This is not
-- a production motion model: fitting the measured data remains an experiment.
local Analysis = {}
function Analysis.apply(cases)
  local ground = {}
  for _, case in ipairs(cases) do
    if case.metrics.belt == "none" then ground[case.metrics.direction] = case.metrics.mean_displacement end
  end
  for _, case in ipairs(cases) do
    local m = case.metrics
    if m.belt ~= "none" then
      local base = ground[m.direction]
      local effect = {x = m.mean_displacement.x - base.x, y = m.mean_displacement.y - base.y}
      local projection = effect.x * m.belt_axis.x + effect.y * m.belt_axis.y
      local lateral = math.abs(effect.x * m.belt_axis.y - effect.y * m.belt_axis.x)
      m.measured_ground_displacement, m.measured_belt_effect = base, effect
      m.additive_prototype_model_residual = {
        x = effect.x - m.prototype_belt_speed * m.belt_axis.x,
        y = effect.y - m.prototype_belt_speed * m.belt_axis.y}
      local checks = {
        {name = "belt-changes-native-displacement-forward", passed = projection > 1 / 256},
        {name = "belt-effect-aligned-with-declared-direction", passed = lateral <= 1 / 256}
      }
      for _, check in ipairs(checks) do
        case.assertions[#case.assertions + 1] = check
        case.passed = case.passed and check.passed
      end
    end
  end
end
return Analysis
