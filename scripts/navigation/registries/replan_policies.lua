local Registry = require("scripts.navigation.registry")

return Registry.create("replan_policies", {
  {
    id = "stuck-retry-v1",
    module = "__factorio-scv-control__/scripts/navigation_policy",
    provides = {"terminal-replan-policy"},
    requires = {"native-movement-primitives"}
  }
})
