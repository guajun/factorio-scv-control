local Registry = require("scripts.navigation.registry")

return Registry.create("cost_models", {
  {
    id = "polyline-distance-v1",
    module = "__factorio-scv-control__/scripts/navigation/stages/polyline_distance",
    provides = {"scalar-route-cost"},
    requires = {"candidate-route"}
  }
})
