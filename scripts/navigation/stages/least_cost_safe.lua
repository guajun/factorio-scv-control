local LeastCostSafe = {}

local function validation_safe(evaluation)
  for _, result in ipairs(evaluation.validator_results) do
    if result.status ~= "pass" then return false end
  end
  return true
end

function LeastCostSafe.select(context, evaluations)
  local selected
  for _, evaluation in ipairs(evaluations) do
    if evaluation.candidate.status == "success"
        and evaluation.cost_result.status == "success"
        and validation_safe(evaluation) then
      if not selected
          or evaluation.cost_result.value < selected.cost_result.value then
        selected = evaluation
      end
    end
  end
  if not selected then return nil, "no-safe-candidate" end
  return selected
end

return LeastCostSafe
