local Registry = require("scripts.navigation.registry")

return Registry.create("postprocessors", {
  {
    id = "safe-string-pull",
    module = "__factorio-scv-control__/scripts/navigation/stages/safe_string_pull",
    provides = {"collision-safe-route"},
    requires = {"candidate-route", "surface-collision-query"}
  }
})
