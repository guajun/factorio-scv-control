local Boundary = require("__factorio-scv-control__/scripts/navigation/solver_boundary")
local Canonical = require("__factorio-scv-control__/scripts/navigation/canonical")
local Data = require("__factorio-scv-control__/scripts/navigation/navigation_data")
local PlanningRun = require("__factorio-scv-control__/scripts/navigation/planning_run")
local Profiles = require("__factorio-scv-control__/scripts/navigation/profiles/init")
local Resolver = require("__factorio-scv-control__/scripts/navigation/profile_resolver")
local Serializable = require("__factorio-scv-control__/scripts/navigation/serializable")

local Tests = {}
local function copy(value) return assert(Serializable.copy(value)) end

local function fixture()
  local actor = {
    name = "character", position = {x = 0, y = 0}, force = "player", character_running_speed = 0.15,
    prototype = {collision_box = {left_top = {x = -0.2, y = -0.2}, right_bottom = {x = 0.2, y = 0.2}},
      collision_mask = {layers = {}}}
  }
  local snapshot = {
    protocol = Boundary.PROTOCOL, kind = "world-snapshot", snapshot_id = "s1",
    world_id = "test", surface_id = "1", captured_tick = 1,
    actor = Boundary.actor_descriptor(actor), revisions = {topology = 0, motion = 0},
    coverage = {bounds = {left_top = {x = -2, y = -2}, right_bottom = {x = 8, y = 2}}, unknown = "blocked"},
    geometry = {entities = {}, tiles = {}},
    graph = {nodes = {{id = "start", position = {x = 0, y = 0}}, {id = "goal", position = {x = 4, y = 0}}},
      edges = {{from = "start", to = "goal", distance = 4}}}
  }
  local data = assert(Data.new({backend_id = "reference-graph-v1", backend_version = "1", session_id = "session"}))
  local ref = assert(Data.load_world(data, snapshot))
  local query = {
    protocol = Boundary.PROTOCOL, kind = "navigation-query", query_id = "query", session_id = "session",
    command_id = "1", attempt_id = "1", snapshot_id = "s1", data_ref = ref,
    start = {x = 0, y = 0}, goal = {x = 4, y = 0}, start_node = "start", goal_node = "goal",
    goal_tolerance = 0.1, objective = {id = "distance", units = "tiles"},
    required_capabilities = {"directed-graph-v1", "distance", "finite-bounds"},
    budget = {max_expansions = 10, max_points = 10}
  }
  query.query_hash = assert(Boundary.hash_query(query))
  local result = {
    protocol = Boundary.PROTOCOL, kind = "solver-result", query_id = query.query_id,
    session_id = query.session_id, command_id = query.command_id, attempt_id = query.attempt_id,
    snapshot_id = query.snapshot_id, query_hash = query.query_hash, data_ref = copy(ref),
    outcome = "complete", objective = copy(query.objective), solver = {id = "fixture", version = "1"},
    points = {copy(query.start), copy(query.goal)}, predicted = {distance = 4},
    coverage = copy(snapshot.coverage), metrics = {}
  }
  result.coverage.scope = "bounded-graph"
  local runtime = {
    actor = actor, surface = {find_entities = function() return {} end, find_tiles_filtered = function() return {} end},
    tick = 1, solver_result = result, navigation_data_ref = ref, navigation_snapshot = snapshot,
    request_solver = function() return "external-token" end
  }
  return query, result, runtime, data
end

local function start(query, runtime, profile)
  return PlanningRun.start({schema_version = 1, profile_id = profile or "interchange-distance-v1", values = {}}, {
    id = "run", command_id = query.command_id, adapter_id = "boundary-test",
    start_position = query.start, goal_position = query.goal, navigation_query = query
  }, runtime)
end

function Tests.run(expect)
  local query, result, runtime = fixture()
  local run, progress = start(query, runtime)
  expect("boundary.import_uses_shared_validation_and_score", run and progress.status == "success"
    and #progress.candidates[1].validator_results == 2 and progress.route.predicted.distance == 4
    and progress.route.values.scored_objective.units == "tiles", progress)

  local bad = copy(query)
  bad.goal.x = 5
  local valid, detail = Boundary.validate_query(bad)
  expect("boundary.query_content_binding", not valid and detail.code == "query-hash-mismatch", detail)

  for _, key in ipairs({"query_id", "session_id", "command_id", "attempt_id", "snapshot_id", "query_hash"}) do
    bad = copy(result); bad[key] = "wrong"
    valid, detail = Boundary.validate_result(bad, query)
    expect("boundary.reject_identity." .. key, not valid and detail.code == "result-identity-mismatch", detail)
  end
  bad = copy(result); bad.points[2].x = 3
  valid, detail = Boundary.validate_result(bad, query)
  expect("boundary.reject_incomplete_endpoint", not valid and detail.code == "incomplete-endpoint", detail)
  bad = copy(result); bad.points[2].x = math.huge
  valid, detail = Boundary.validate_result(bad, query)
  expect("boundary.reject_nonfinite", not valid, detail)
  bad = copy(result); bad.objective.units = "ticks"
  valid, detail = Boundary.validate_result(bad, query)
  expect("boundary.reject_wrong_units", not valid, detail)
  bad = copy(result); bad.actions = {{type = "request-gate-open"}}
  valid, detail = Boundary.validate_result(bad, query)
  expect("boundary.reject_unimplemented_actions", not valid, detail)

  local profile = Profiles.get("interchange-distance-v1")
  profile.candidate_providers = {"imported-route", "engine-normal"}
  local preflight
  preflight, detail = Resolver.preflight_profile(profile)
  expect("boundary.capabilities_checked_per_provider", not preflight
    and detail.code == "unsupported-provider-objective" and detail.component_id == "engine-normal", detail)
  bad = copy(query); bad.required_capabilities[#bad.required_capabilities + 1] = "gate-actions"
  bad.query_hash = assert(Boundary.hash_query(bad))
  run, detail = start(bad, runtime)
  expect("boundary.reject_missing_query_capability", not run and detail.code == "unsupported-capability", detail)
  bad = copy(query); bad.objective = {id = "travel-time", units = "ticks"}
  bad.query_hash = assert(Boundary.hash_query(bad))
  run, detail = start(bad, runtime)
  expect("boundary.reject_time_without_calibrated_profile", not run and detail.code == "profile-objective-mismatch", detail)

  for _, outcome in ipairs({"partial", "no-path", "budget-exhausted", "cancelled", "unsupported", "error"}) do
    query, result, runtime = fixture()
    result.outcome = outcome; result.points = {}; result.predicted = {}
    run, progress = start(query, runtime)
    local expected = outcome == "no-path" and "no-path" or outcome == "cancelled" and "cancelled" or "failed"
    expect("boundary.explicit_outcome." .. outcome, run and progress.status == expected
      and progress.values.solver_outcome == outcome and not progress.route, progress)
  end

  query, result, runtime = fixture()
  runtime.navigation_data_ref = copy(runtime.navigation_data_ref)
  runtime.navigation_data_ref.revisions.topology = 1
  run, progress = start(query, runtime)
  expect("boundary.reject_changed_world", progress.status == "failed" and progress.reason == "solver-stale-world", progress)
  query, result, runtime = fixture(); runtime.actor.position.x = 0.25
  run, progress = start(query, runtime)
  expect("boundary.reject_moved_actor", progress.status == "failed"
    and progress.values.detail == "actor-moved", progress)

  query, result, runtime = fixture()
  run, progress = start(query, runtime, "external-distance-v1")
  if not run then error("External profile preflight failed: " .. helpers.table_to_json(progress)) end
  expect("boundary.external_pending_is_serializable", progress.status == "pending"
    and Serializable.validate(run), progress)
  progress = PlanningRun.handle_result(run, {id = "external-token", path = {}}, runtime)
  expect("boundary.engine_cannot_complete_external", progress.status == "stale" and run.status == "running", progress)
  progress = PlanningRun.handle_solver_result(run, {id = "wrong", provider_id = "external-route", result = result}, runtime)
  expect("boundary.wrong_token_keeps_request_pending", progress.status == "stale" and run.status == "running", progress)
  progress = PlanningRun.handle_solver_result(run, {id = "external-token", provider_id = "external-route", result = result}, runtime)
  expect("boundary.external_complete_uses_same_pipeline", progress.status == "success" and progress.route.predicted.distance == 4, progress)
  progress = PlanningRun.handle_solver_result(run, {id = "external-token", provider_id = "external-route", result = result}, runtime)
  expect("boundary.duplicate_cannot_reactivate", progress.status == "stale" and run.status == "success", progress)

  query, result, runtime = fixture(); run = start(query, runtime, "external-distance-v1")
  PlanningRun.cancel(run, "superseded", runtime)
  progress = PlanningRun.handle_solver_result(run, {id = "external-token", provider_id = "external-route", result = result}, runtime)
  expect("boundary.cancelled_answer_cannot_reactivate", progress.status == "stale" and run.status == "cancelled", progress)
  query, result, runtime = fixture(); run = start(query, runtime, "external-distance-v1")
  progress = PlanningRun.fail_pending(run, "solver-watchdog-timeout", runtime)
  expect("boundary.transport_timeout_is_not_no_path", progress.status == "failed" and progress.reason == "solver-watchdog-timeout", progress)
end

return Tests
