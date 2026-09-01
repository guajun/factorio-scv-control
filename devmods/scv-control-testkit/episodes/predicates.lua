local Util = require("episodes.util")

local Predicates = {}
local handlers = {}

handlers["actor-progress-at-least"] = function(spec, context)
  local start = context.fixture.start
  local goal = context.fixture.goal
  local position = context.actor.position
  local dx = goal.x - start.x
  local dy = goal.y - start.y
  local length = math.sqrt(dx * dx + dy * dy)
  local progress = 0
  if length > 0 then
    progress = ((position.x - start.x) * dx + (position.y - start.y) * dy) / length
  end
  return progress >= spec.distance, {progress = progress, required = spec.distance}
end

handlers["actor-distance-to-goal-at-most"] = function(spec, context)
  local distance = Util.distance(context.actor.position, context.fixture.goal)
  return distance <= spec.distance, {distance = distance, required = spec.distance}
end

handlers["navigation-state-is"] = function(spec, context)
  return context.run.navigation.state == spec.state, {
    actual = context.run.navigation.state,
    expected = spec.state
  }
end

function Predicates.evaluate(spec, context, extensions)
  local handler = extensions and extensions[spec.type] or handlers[spec.type]
  if not handler then error("unknown episode predicate: " .. tostring(spec.type)) end
  return handler(spec, context)
end

return Predicates
