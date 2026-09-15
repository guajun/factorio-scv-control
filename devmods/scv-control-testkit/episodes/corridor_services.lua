local Adapter = require("episodes.adapters.corridor_follower")
local Actions = require("episodes.actions")
local Assertions = require("episodes.assertions")
local Predicates = require("episodes.predicates")

-- The generated calibration and saved-world replay share the same actions,
-- event notifications, assertions and PlanningRun/Follower adapter.
local Services = {navigation = Adapter, predicates = Predicates, actions = Actions,
  assertions = Assertions, action_extensions = {}}

Services.action_extensions["raise-wall-line"] = function(spec, context)
  local positions, expected = {}, 0
  Actions.each_line_position(spec, function(position)
    expected = expected + 1
    local entity = context.surface.create_entity({name = "stone-wall", position = position,
      force = "neutral", raise_built = true})
    if entity then
      entity.destructible, entity.minable = false, false
      positions[#positions + 1] = {x = entity.position.x, y = entity.position.y}
    end
  end)
  return {status = #positions == expected and "applied" or "failed", created_entities = #positions,
    obstacle_positions = positions, revision_tick = game.tick}
end

Services.action_extensions["raise-remove-walls"] = function(_, context)
  local removed = 0
  for _, entity in ipairs(context.surface.find_entities_filtered({name = "stone-wall"})) do
    if entity.destroy({raise_destroy = true}) then removed = removed + 1 end
  end
  return {status = removed == 7 and "applied" or "failed", removed_entities = removed,
    revision_tick = game.tick}
end

Services.action_extensions["raise-forward-belts"] = function(spec, context)
  local created = 0
  Actions.each_line_position(spec, function(position)
    if context.surface.create_entity({name = "transport-belt", position = position,
        force = "player", direction = defines.direction.east, raise_built = true}) then
      created = created + 1
    end
  end)
  return {status = created == 4 and "applied" or "failed", created_entities = created,
    revision_tick = game.tick}
end

function Services.result(result)
  if not result.trace then return result end
  result.timeline = result.trace
  result.reason = result.terminal_reason
  result.assertions[#result.assertions + 1] = {
    id = "shared-terminal-contract", passed = result.terminal_contract_error == false
  }
  result.assertions[#result.assertions + 1] = {
    id = "expected-terminal", passed = result.terminal_state == result.expected_terminal
  }
  result.passed = true
  for _, assertion in ipairs(result.assertions) do
    if not assertion.passed then result.passed = false end
  end
  return result
end

return Services
