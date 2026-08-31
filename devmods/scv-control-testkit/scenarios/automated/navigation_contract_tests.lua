local Contracts = require("__factorio-scv-control__/scripts/navigation/contracts")
local Profiles = require("__factorio-scv-control__/scripts/navigation/profiles/init")
local PlanningRun = require("__factorio-scv-control__/scripts/navigation/planning_run")
local ProfileResolver = require("__factorio-scv-control__/scripts/navigation/profile_resolver")
local Serializable = require("__factorio-scv-control__/scripts/navigation/serializable")
local LeastCostSafe = require("__factorio-scv-control__/scripts/navigation/stages/least_cost_safe")

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

local function fake_planning_runtime()
  local next_request_id = 100
  return {
    surface = {
      find_entities = function() return {} end,
      find_tiles_filtered = function() return {} end
    },
    actor = {
      name = "character",
      position = {x = 0, y = 0},
      force = "player",
      character_running_speed = 0.15,
      prototype = {
        collision_box = {
          left_top = {x = -0.2, y = -0.2},
          right_bottom = {x = 0.2, y = 0.2}
        },
        collision_mask = {layers = {}}
      }
    },
    tick = 10,
    request_path = function()
      next_request_id = next_request_id + 1
      return next_request_id
    end
  }
end

local function planning_run(adapter_id)
  local runtime = fake_planning_runtime()
  local run, progress = PlanningRun.start(Profiles.default_reference(), {
    id = 1,
    adapter_id = adapter_id,
    start_position = {x = 0, y = 0},
    goal_position = {x = 4, y = 0},
    reason = "contract-test"
  }, runtime)
  return run, progress, runtime
end

local function successful_planning_run(adapter_id)
  local run, progress, runtime = planning_run(adapter_id)
  progress = PlanningRun.handle_result(run, {
    id = progress.request_id,
    path = {
      {position = {x = 1, y = 0}},
      {position = {x = 4, y = 0}}
    }
  }, runtime)
  progress = PlanningRun.handle_result(run, {
    id = progress.request_id,
    path = {
      {position = {x = 2, y = 0}},
      {position = {x = 4, y = 0}}
    }
  }, runtime)
  return run, progress
end

local function deep_equal(first, second)
  if type(first) ~= type(second) then return false end
  if type(first) ~= "table" then return first == second end
  for key, value in pairs(first) do
    if not deep_equal(value, second[key]) then return false end
  end
  for key in pairs(second) do
    if first[key] == nil then return false end
  end
  return true
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
      name = "planning_result",
      value = {
        schema_version = Contracts.VERSION,
        status = "success",
        adapter_id = "contract-test",
        profile_id = "production-v1",
        provider_order = {"engine-normal", "engine-inflated", "grid-a-star"},
        trace = {},
        candidates = {},
        route = route,
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

  local production_run, production_result = successful_planning_run("production")
  local benchmark_run, benchmark_result = successful_planning_run("benchmark")
  local production_trace = PlanningRun.provider_trace(production_run)
  local benchmark_trace = PlanningRun.provider_trace(benchmark_run)
  expect(
    "navigation.production_and_benchmark_share_planning_transitions",
    production_result.status == "success"
      and benchmark_result.status == "success"
      and deep_equal(production_result.provider_order, benchmark_result.provider_order)
      and deep_equal(production_trace, benchmark_trace)
      and production_trace[1].provider_id == "engine-normal"
      and production_trace[4].provider_id == "engine-inflated"
      and production_trace[7].provider_id == "grid-a-star"
      and production_trace[#production_trace].status == "success",
    {production = production_trace, benchmark = benchmark_trace}
  )

  local no_path_run, no_path_progress, no_path_runtime = planning_run("contract-no-path")
  local no_path = PlanningRun.handle_result(no_path_run, {
    id = no_path_progress.request_id
  }, no_path_runtime)
  local busy_run, busy_progress, busy_runtime = planning_run("contract-busy")
  local busy = PlanningRun.handle_result(busy_run, {
    id = busy_progress.request_id,
    try_again_later = true
  }, busy_runtime)
  expect(
    "navigation.planning_run_structured_terminal_states",
    no_path.status == "no-path"
      and busy.status == "busy-retry"
      and busy.retry_after_ticks > 0,
    {no_path = no_path, busy = busy}
  )

  local optional_busy_run, optional_busy_progress, optional_busy_runtime = planning_run(
    "contract-optional-busy"
  )
  optional_busy_progress = PlanningRun.handle_result(optional_busy_run, {
    id = optional_busy_progress.request_id,
    path = {
      {position = {x = 1, y = 0}},
      {position = {x = 4, y = 0}}
    }
  }, optional_busy_runtime)
  local optional_busy = PlanningRun.handle_result(optional_busy_run, {
    id = optional_busy_progress.request_id,
    try_again_later = true
  }, optional_busy_runtime)
  expect(
    "navigation.optional_provider_busy_continues_to_safe_fallback",
    optional_busy.status == "success"
      and optional_busy.selected_provider_id == "engine-normal"
      and optional_busy_run.candidates[2].provider_id == "engine-inflated"
      and optional_busy_run.candidates[2].status == "busy"
      and optional_busy_run.candidates[3].provider_id == "grid-a-star",
    {result = optional_busy}
  )

  local unsafe_selection, unsafe_selection_reason = LeastCostSafe.select({}, {
    {
      candidate = {status = "success", provider_id = "engine-normal"},
      validator_results = {
        {status = "fail"},
        {status = "fail"}
      },
      cost_result = {status = "success", value = 1}
    },
    {
      candidate = {status = "success", provider_id = "engine-inflated"},
      validator_results = {
        {status = "pass"},
        {status = "fail"}
      },
      cost_result = {status = "success", value = 2}
    }
  })
  expect(
    "navigation.least_cost_safe_rejects_all_unsafe_candidates",
    unsafe_selection == nil and unsafe_selection_reason == "no-safe-candidate",
    {selected = unsafe_selection, reason = unsafe_selection_reason}
  )

  local unsafe_run, unsafe_progress, unsafe_runtime = planning_run("contract-unsafe")
  unsafe_runtime.surface.find_entities = function()
    return {{
      valid = true,
      prototype = {collision_mask = {layers = {player = true}}}
    }}
  end
  unsafe_runtime.actor.prototype.collision_mask.layers.player = true
  unsafe_progress = PlanningRun.handle_result(unsafe_run, {
    id = unsafe_progress.request_id,
    path = {{position = {x = 4, y = 0}}}
  }, unsafe_runtime)
  local unsafe_result = PlanningRun.handle_result(unsafe_run, {
    id = unsafe_progress.request_id,
    path = {{position = {x = 4, y = 0}}}
  }, unsafe_runtime)
  expect(
    "navigation.planning_run_never_activates_all_unsafe_candidates",
    unsafe_result.status == "failed"
      and unsafe_result.reason == "no-safe-candidate"
      and unsafe_result.route == nil
      and unsafe_result.selected_provider_id == nil,
    {result = unsafe_result}
  )

  local failed_run, failed_progress, failed_runtime = planning_run("contract-failed")
  failed_runtime.surface.find_entities = function() error("forced-component-failure") end
  local failed = PlanningRun.handle_result(failed_run, {
    id = failed_progress.request_id,
    path = {{position = {x = 4, y = 0}}}
  }, failed_runtime)
  expect(
    "navigation.component_errors_become_failed_terminal_results",
    failed.status == "failed"
      and failed.reason:find("forced%-component%-failure") ~= nil
      and failed.route == nil,
    {result = failed}
  )

  local cancelled_run, pending, cancelled_runtime = planning_run("contract-cancel")
  local stale_before_cancel = PlanningRun.handle_result(cancelled_run, {
    id = pending.request_id + 1000,
    path = {{position = {x = 4, y = 0}}}
  }, cancelled_runtime)
  local cancelled = PlanningRun.cancel(cancelled_run, "contract-cancelled", cancelled_runtime)
  local stale_after_cancel = PlanningRun.handle_result(cancelled_run, {
    id = pending.request_id,
    path = {{position = {x = 4, y = 0}}}
  }, cancelled_runtime)
  expect(
    "navigation.cancelled_and_stale_results_cannot_activate_route",
    stale_before_cancel.status == "stale"
      and cancelled.status == "cancelled"
      and cancelled.route == nil
      and stale_after_cancel.status == "stale"
      and stale_after_cancel.route == nil
      and cancelled_run.status == "cancelled",
    {
      stale_before_cancel = stale_before_cancel,
      cancelled = cancelled,
      stale_after_cancel = stale_after_cancel
    }
  )
end

return NavigationContractTests
