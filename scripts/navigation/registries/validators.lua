local Registry = require("scripts.navigation.registry")

return Registry.create("validators", {
  {
    id = "actor-collision",
    module = "__factorio-scv-control__/scripts/path_smoothing",
    provides = {"actor-collision-validation"},
    requires = {"collision-safe-route", "surface-collision-query"}
  },
  {
    id = "trajectory-envelope",
    module = "__factorio-scv-control__/scripts/path_smoothing",
    provides = {"trajectory-envelope-validation"},
    requires = {"collision-safe-route", "surface-collision-query"}
  }
})
