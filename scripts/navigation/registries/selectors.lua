local Registry = require("scripts.navigation.registry")

return Registry.create("selectors", {
  {
    id = "least-cost-safe",
    module = "__factorio-scv-control__/scripts/navigation/stages/least_cost_safe",
    provides = {"selected-route"},
    requires = {
      "actor-collision-validation",
      "scalar-route-cost",
      "trajectory-envelope-validation"
    }
  }
})
