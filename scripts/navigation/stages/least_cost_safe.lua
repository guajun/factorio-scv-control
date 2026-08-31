local LeastCostSafe = {}

local function validation_safe(evaluation)
  for _, result in ipairs(evaluation.validator_results) do
    if result.status ~= "pass" then return false end
  end
  return true
end

function LeastCostSafe.select(context, evaluations)
  local selected
  local selected_safe = false
  for _, evaluation in ipairs(evaluations) do
    if evaluation.candidate.status == "success"
        and evaluation.cost_result.status == "success" then
      local safe = validation_safe(evaluation)
      if not selected then
        selected = evaluation
        selected_safe = safe
      elseif safe and (not selected_safe
          or evaluation.cost_result.value < selected.cost_result.value) then
        selected = evaluation
        selected_safe = true
      end
    end
  end
  if not selected then return nil, "no-successful-candidate" end
  return selected
end

return LeastCostSafe
