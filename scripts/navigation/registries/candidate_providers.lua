local Registry = require("scripts.navigation.registry")

return Registry.create("candidate_providers", {
  {
    id = "engine-normal",
    module = "__factorio-scv-control__/scripts/navigation/candidate_providers/engine_normal",
    provides = {"candidate-route", "engine-path-request", "gate-aware-engine-request"},
    requires = {"surface-collision-query"}
  },
  {
    id = "engine-inflated",
    module = "__factorio-scv-control__/scripts/navigation/candidate_providers/engine_inflated",
    provides = {"candidate-route", "engine-path-request", "inflated-actor-envelope"},
    requires = {"surface-collision-query"}
  },
  {
    id = "grid-a-star",
    module = "__factorio-scv-control__/scripts/navigation/candidate_providers/grid_a_star",
    provides = {"candidate-route", "conservative-local-search"},
    requires = {"local-collision-grid"}
  },
  {
    id = "imported-route",
    module = "__factorio-scv-control__/scripts/navigation/candidate_providers/imported_route",
    provides = {"candidate-route"}, requires = {"surface-collision-query"},
    query_support = {
      objectives = {"distance"},
      backends = {"factorio-captured-grid-v1", "reference-graph-v1", "extremity-source-polygons-v1"},
      capabilities = {"directed-graph-v1", "distance", "directed-edge-costs", "finite-bounds"}
    }
  },
  {
    id = "external-route",
    module = "__factorio-scv-control__/scripts/navigation/candidate_providers/external_route",
    provides = {"candidate-route"}, requires = {"surface-collision-query"},
    query_support = {
      objectives = {"distance"},
      backends = {"factorio-captured-grid-v1", "reference-graph-v1"},
      capabilities = {"directed-graph-v1", "distance", "directed-edge-costs", "finite-bounds"}
    }
  }
})
