local Contracts = require("scripts.navigation.contracts")
local PathMath = require("scripts.path_math")
local PathSmoothing = require("scripts.path_smoothing")

local SafeStringPull = {}

function SafeStringPull.process(context, route)
  local raw_points = route.points
  local points = PathSmoothing.simplify(
    context.surface,
    context.actor,
    raw_points,
    context.goal_position
  )
  route.points = points
  route.metrics = route.metrics or {
    schema_version = Contracts.VERSION,
    values = {}
  }
  route.metrics.values.removed_waypoints = #raw_points - #points
  route.metrics.values.engine_turns = PathMath.turn_metrics(raw_points)
  route.metrics.values.smoothed_turns = PathMath.turn_metrics(points)
  return route
end

return SafeStringPull
