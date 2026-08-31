local Registries = {}

Registries.STAGES = {
  {
    profile_key = "world_model",
    resolved_key = "world_model",
    registry = require("scripts.navigation.registries.world_models"),
    cardinality = "one"
  },
  {
    profile_key = "candidate_providers",
    resolved_key = "candidate_providers",
    registry = require("scripts.navigation.registries.candidate_providers"),
    cardinality = "many",
    minimum = 1
  },
  {
    profile_key = "postprocessors",
    resolved_key = "postprocessors",
    registry = require("scripts.navigation.registries.postprocessors"),
    cardinality = "many"
  },
  {
    profile_key = "validators",
    resolved_key = "validators",
    registry = require("scripts.navigation.registries.validators"),
    cardinality = "many",
    minimum = 1
  },
  {
    profile_key = "cost_model",
    resolved_key = "cost_model",
    registry = require("scripts.navigation.registries.cost_models"),
    cardinality = "one"
  },
  {
    profile_key = "selector",
    resolved_key = "selector",
    registry = require("scripts.navigation.registries.selectors"),
    cardinality = "one"
  },
  {
    profile_key = "trajectory",
    resolved_key = "trajectory_adapter",
    registry = require("scripts.navigation.registries.trajectory_adapters"),
    cardinality = "one"
  },
  {
    profile_key = "replan_policy",
    resolved_key = "replan_policy",
    registry = require("scripts.navigation.registries.replan_policies"),
    cardinality = "one"
  }
}

return Registries
