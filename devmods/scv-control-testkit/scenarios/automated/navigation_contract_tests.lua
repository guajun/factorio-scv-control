local Contracts = require("__factorio-scv-control__/scripts/navigation/contracts")
local Profiles = require("__factorio-scv-control__/scripts/navigation/profiles/init")
local ProfileResolver = require("__factorio-scv-control__/scripts/navigation/profile_resolver")
local Serializable = require("__factorio-scv-control__/scripts/navigation/serializable")

local NavigationContractTests = {}
local implementations_loaded, implementation_error = ProfileResolver.load_implementations()
if not implementations_loaded then
  error(implementation_error.message .. " " .. tostring(implementation_error.cause))
end

local function copy(value)
  local result, copy_error = Serializable.copy(value)
  if not result then error(copy_error.message) end
  return result
end

function NavigationContractTests.run(expect)
  local reference, reference_error = ProfileResolver.reference("production-v1", {
    command = {queued = false}
  })
  local reference_ok, serializable_error = Serializable.validate(reference)
  expect(
    "navigation.profile_reference_round_trip",
    reference ~= nil
      and reference_error == nil
      and reference_ok
      and copy(reference).profile_id == "production-v1",
    {error = reference_error or serializable_error}
  )

  local preflight, preflight_error = ProfileResolver.preflight(reference)
  expect(
    "navigation.production_v1_preflight",
    preflight ~= nil
      and preflight_error == nil
      and #preflight.stages.candidate_providers == 3
      and preflight.stages.trajectory_adapter.id == "vector16-v1"
      and preflight.stages.replan_policy.id == "stuck-retry-v1",
    {error = preflight_error}
  )

  local resolved, resolution_error = ProfileResolver.resolve(reference)
  expect(
    "navigation.production_v1_resolves_all_stages",
    resolved ~= nil
      and resolution_error == nil
      and resolved.stages.world_model.implementation ~= nil
      and #resolved.stages.candidate_providers == 3
      and #resolved.stages.postprocessors == 1
      and #resolved.stages.validators == 2
      and resolved.stages.cost_model.implementation ~= nil
      and resolved.stages.selector.implementation ~= nil
      and resolved.stages.trajectory_adapter.implementation ~= nil
      and resolved.stages.replan_policy.implementation ~= nil,
    {error = resolution_error}
  )

  local metrics = {
    schema_version = Contracts.VERSION,
    values = {expanded_nodes = 4, duration_ticks = 2}
  }
  local action = {
    schema_version = Contracts.VERSION,
    type = "request-gate-open",
    at_point_index = 2,
    values = {unit_number = 42}
  }
  local dependency = {
    schema_version = Contracts.VERSION,
    kind = "gate",
    unit_number = 42,
    revision = 3
  }
  local route = {
    schema_version = Contracts.VERSION,
    status = "success",
    source = "engine-normal",
    points = {{x = 0, y = 0}, {x = 1, y = 1}},
    corridor = {{from_point_index = 1, to_point_index = 2}},
    actions = {action},
    dependencies = {dependency},
    predicted = {distance = 1.5, travel_ticks = 10},
    world_revisions = {topology = 3, motion = 1},
    metrics = metrics
  }
  local contract_examples = {
    {name = "route_action", value = action},
    {name = "dependency", value = dependency},
    {name = "metrics", value = metrics},
    {name = "route", value = route},
    {
      name = "candidate",
      value = {
        schema_version = Contracts.VERSION,
        provider_id = "engine-normal",
        status = "success",
        route = route,
        metrics = metrics
      }
    },
    {
      name = "validator_result",
      value = {
        schema_version = Contracts.VERSION,
        validator_id = "actor-collision",
        status = "pass",
        metrics = metrics
      }
    },
    {
      name = "cost_result",
      value = {
        schema_version = Contracts.VERSION,
        cost_model_id = "polyline-distance-v1",
        status = "success",
        value = 1.5,
        components = {distance = 1.5},
        metrics = metrics
      }
    },
    {
      name = "terminal_result",
      value = {
        schema_version = Contracts.VERSION,
        status = "arrived",
        route = route,
        metrics = metrics
      }
    }
  }
  local examples_valid = true
  local example_error
  for _, example in ipairs(contract_examples) do
    local valid, validation_error = Contracts.validate(example.name, example.value)
    if not valid then
      examples_valid = false
      example_error = validation_error
      break
    end
  end
  expect(
    "navigation.versioned_result_contracts",
    examples_valid,
    {error = example_error}
  )

  local _, unknown_profile_error = ProfileResolver.preflight({
    schema_version = Contracts.VERSION,
    profile_id = "unknown-profile",
    values = {}
  })
  expect(
    "navigation.unknown_profile_is_structured_error",
    unknown_profile_error
      and unknown_profile_error.kind == "profile-resolution-error"
      and unknown_profile_error.code == "unknown-profile",
    {error = unknown_profile_error}
  )

  local _, invalid_reference_error = ProfileResolver.preflight(true)
  local _, expanded_reference_error = ProfileResolver.preflight({
    schema_version = Contracts.VERSION,
    profile_id = "production-v1",
    values = {},
    world_model = "must-not-be-stored"
  })
  expect(
    "navigation.profile_reference_is_id_and_values_only",
    invalid_reference_error
      and invalid_reference_error.code == "invalid-profile-reference"
      and expanded_reference_error
      and expanded_reference_error.code == "invalid-profile-reference"
      and expanded_reference_error.contract_error.code == "unexpected-field",
    {invalid = invalid_reference_error, expanded = expanded_reference_error}
  )

  local unknown_component_profile = Profiles.get("production-v1")
  unknown_component_profile.candidate_providers[1] = "unknown-provider"
  local _, unknown_component_error = ProfileResolver.preflight_profile(unknown_component_profile)
  expect(
    "navigation.unknown_component_is_rejected",
    unknown_component_error
      and unknown_component_error.code == "unknown-component"
      and unknown_component_error.stage == "candidate_providers"
      and unknown_component_error.component_id == "unknown-provider",
    {error = unknown_component_error}
  )

  local missing_capability_profile = Profiles.get("production-v1")
  missing_capability_profile.validators = {"actor-collision"}
  local _, missing_capability_error = ProfileResolver.preflight_profile(missing_capability_profile)
  expect(
    "navigation.missing_capability_is_rejected",
    missing_capability_error
      and missing_capability_error.code == "missing-capability"
      and missing_capability_error.stage == "selector"
      and missing_capability_error.missing_capabilities[1] == "trajectory-envelope-validation",
    {error = missing_capability_error}
  )

  local invalid_combination_profile = Profiles.get("production-v1")
  invalid_combination_profile.candidate_providers = {}
  local _, combination_error = ProfileResolver.preflight_profile(invalid_combination_profile)
  expect(
    "navigation.invalid_stage_combination_is_rejected",
    combination_error
      and combination_error.code == "invalid-stage-combination"
      and combination_error.stage == "candidate_providers",
    {error = combination_error}
  )

  local ok_candidate, candidate_error = Contracts.validate("candidate", {
    schema_version = Contracts.VERSION,
    provider_id = "engine-normal",
    status = "success"
  })
  expect(
    "navigation.contract_rejects_success_without_route",
    not ok_candidate and candidate_error.code == "missing-route",
    {error = candidate_error}
  )
end

return NavigationContractTests
