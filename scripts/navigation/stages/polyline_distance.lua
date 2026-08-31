local Contracts = require("scripts.navigation.contracts")
local PathMath = require("scripts.path_math")

local PolylineDistance = {}

function PolylineDistance.score(context, route)
  local distance = PathMath.polyline_distance(context.start_position, route.points)
  return {
    schema_version = Contracts.VERSION,
    cost_model_id = "polyline-distance-v1",
    status = "success",
    value = distance,
    components = {distance = distance},
    metrics = {schema_version = Contracts.VERSION, values = {}}
  }
end

return PolylineDistance
