return {
  schema_version = 1,
  id = "production-v1",
  world_model = "live-surface-local-grid-v1",
  candidate_providers = {
    "engine-normal",
    "engine-inflated",
    "grid-a-star"
  },
  postprocessors = {"safe-string-pull"},
  validators = {"actor-collision", "trajectory-envelope"},
  cost_model = "polyline-distance-v1",
  selector = "least-cost-safe",
  trajectory = "vector16-v1",
  replan_policy = "stuck-retry-v1",
  requirements = {
    "gate-aware-engine-request",
    "native-movement-primitives",
    "selected-route",
    "terminal-replan-policy"
  },
  config = {
    engine_requests = {
      cache = false,
      can_open_gates = true,
      order = "serial",
      prefer_straight_paths = true
    },
    selection = {
      cost = "polyline-distance",
      require_collision_safe = true,
      require_strict_improvement = true
    }
  }
}
