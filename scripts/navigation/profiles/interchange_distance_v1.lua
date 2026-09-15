return {
  schema_version = 1, id = "interchange-distance-v1",
  world_model = "live-surface-local-grid-v1",
  candidate_providers = {"imported-route"},
  -- Keep the exact imported graph route for comparison; geometry is validated live.
  postprocessors = {}, validators = {"actor-collision", "trajectory-envelope"},
  cost_model = "polyline-distance-v1", selector = "least-cost-safe",
  trajectory = "vector16-v1", replan_policy = "stuck-retry-v1",
  requirements = {"candidate-route", "selected-route", "native-movement-primitives"},
  config = {navigation_query = {required = true, objective = "distance"}}
}
