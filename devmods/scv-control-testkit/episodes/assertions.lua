local Util = require("episodes.util")

local Assertions = {}
local handlers = {}

handlers["terminal-state-is"] = function(spec, result)
  return result.terminal_state == spec.expected, {
    actual = result.terminal_state,
    expected = spec.expected
  }
end

handlers["metric-at-least"] = function(spec, result)
  local actual = Util.value_at_path(result.metrics, spec.path)
  return type(actual) == "number" and actual >= spec.value, {
    path = spec.path,
    actual = actual == nil and false or actual,
    minimum = spec.value
  }
end

handlers["metric-at-most"] = function(spec, result)
  local actual = Util.value_at_path(result.metrics, spec.path)
  return type(actual) == "number" and actual <= spec.value, {
    path = spec.path,
    actual = actual == nil and false or actual,
    maximum = spec.value
  }
end

handlers["metric-is"] = function(spec, result)
  local actual = Util.value_at_path(result.metrics, spec.path)
  return actual == spec.value, {
    path = spec.path,
    actual = actual == nil and false or actual,
    expected = spec.value
  }
end

handlers["action-executed"] = function(spec, result)
  for _, action in ipairs(result.actions) do
    if action.id == spec.action_id and action.status == "applied" then
      return true, {action_id = spec.action_id, tick = action.tick}
    end
  end
  return false, {action_id = spec.action_id}
end

function Assertions.evaluate(spec, result, extensions)
  local handler = extensions and extensions[spec.type] or handlers[spec.type]
  if not handler then error("unknown episode assertion: " .. tostring(spec.type)) end
  local passed, details = handler(spec, result)
  return {
    id = spec.id,
    type = spec.type,
    passed = passed == true,
    details = details
  }
end

return Assertions
