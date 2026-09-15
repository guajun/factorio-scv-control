local Registry = require("scripts.navigation.registry")

return Registry.create("validators", {
  {
    id = "actor-collision",
    module = "__factorio-scv-control__/scripts/navigation/stages/actor_collision",
    provides = {"actor-collision-validation"},
    requires = {"candidate-route", "surface-collision-query"}
  },
  {
    id = "trajectory-envelope",
    module = "__factorio-scv-control__/scripts/navigation/stages/trajectory_envelope",
    provides = {"trajectory-envelope-validation"},
    requires = {"candidate-route", "surface-collision-query"}
  }
})
