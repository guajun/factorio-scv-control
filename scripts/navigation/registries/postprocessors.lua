local Registry = require("scripts.navigation.registry")

return Registry.create("postprocessors", {
  {
    id = "safe-string-pull",
    module = "__factorio-scv-control__/scripts/path_smoothing",
    provides = {"collision-safe-route"},
    requires = {"candidate-route", "surface-collision-query"}
  }
})
