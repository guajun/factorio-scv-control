local Registry = require("scripts.navigation.registry")

return Registry.create("world_models", {
  {
    id = "live-surface-local-grid-v1",
    module = "__factorio-scv-control__/scripts/navigation_grid",
    provides = {"surface-collision-query", "local-collision-grid"},
    requires = {}
  }
})
