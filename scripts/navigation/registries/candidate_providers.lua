local Registry = require("scripts.navigation.registry")

return Registry.create("candidate_providers", {
  {
    id = "engine-normal",
    module = "__factorio-scv-control__/scripts/planner",
    provides = {"candidate-route", "engine-path-request", "gate-aware-engine-request"},
    requires = {"surface-collision-query"}
  },
  {
    id = "engine-inflated",
    module = "__factorio-scv-control__/scripts/planner",
    provides = {"candidate-route", "engine-path-request", "inflated-actor-envelope"},
    requires = {"surface-collision-query"}
  },
  {
    id = "grid-a-star",
    module = "__factorio-scv-control__/scripts/local_planner",
    provides = {"candidate-route", "conservative-local-search"},
    requires = {"local-collision-grid"}
  }
})
