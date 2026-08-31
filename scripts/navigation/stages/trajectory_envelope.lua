local Contracts = require("scripts.navigation.contracts")
local PathSmoothing = require("scripts.path_smoothing")

local TrajectoryEnvelope = {}

function TrajectoryEnvelope.validate(context, route)
  local safe = PathSmoothing.path_is_clear(
    context.surface,
    context.actor,
    context.start_position,
    route.points
  )
  return {
    schema_version = Contracts.VERSION,
    validator_id = "trajectory-envelope",
    status = safe and "pass" or "fail",
    reason = safe and nil or "trajectory-envelope",
    metrics = {schema_version = Contracts.VERSION, values = {safe = safe}}
  }
end

return TrajectoryEnvelope
