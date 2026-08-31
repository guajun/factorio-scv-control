local Registry = require("scripts.navigation.registry")

return Registry.create("trajectory_adapters", {
  {
    id = "vector16-v1",
    module = "__factorio-scv-control__/scripts/trajectory",
    provides = {"native-movement-primitives"},
    requires = {"selected-route"}
  }
})
