local Contracts = require("scripts.navigation.contracts")
local PathSmoothing = require("scripts.path_smoothing")

local ActorCollision = {}

function ActorCollision.validate(context, route)
  local safe = PathSmoothing.path_is_clear(
    context.surface,
    context.actor,
    context.start_position,
    route.points,
    0
  )
  return {
    schema_version = Contracts.VERSION,
    validator_id = "actor-collision",
    status = safe and "pass" or "fail",
    reason = safe and nil or "actor-collision",
    metrics = {schema_version = Contracts.VERSION, values = {safe = safe}}
  }
end

return ActorCollision
