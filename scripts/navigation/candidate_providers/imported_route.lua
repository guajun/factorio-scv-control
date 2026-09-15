local Boundary = require("scripts.navigation.solver_boundary")
local Canonical = require("scripts.navigation.canonical")
local Serializable = require("scripts.navigation.serializable")

local Imported = {kind = "sync", required = true}

local function failure(provider_id, outcome, reason)
  return {
    schema_version = 1, provider_id = provider_id, status = "error",
    values = {solver_outcome = outcome, reason = reason},
    metrics = {schema_version = 1, values = {solver_outcome = outcome, reason = reason}}
  }
end

function Imported.adapt(context, result, provider_id)
  provider_id = provider_id or "imported-route"
  local query = context.navigation_query
  local valid, detail = Boundary.admit(result, query, context.navigation_data_ref)
  if not valid then return failure(provider_id, detail.code == "stale-world" and "stale-world" or "invalid-query", detail.code) end
  local snapshot = context.navigation_snapshot
  valid, detail = Boundary.validate_snapshot(snapshot)
  if not valid then return failure(provider_id, "invalid-query", detail.code) end
  if Canonical.hash(snapshot) ~= query.data_ref.snapshot_hash
      or Canonical.hash(snapshot.actor) ~= query.data_ref.actor_hash
      or Canonical.encode(snapshot.coverage.bounds) ~= Canonical.encode(result.coverage.bounds) then
    return failure(provider_id, "stale-world", "snapshot-content-mismatch")
  end
  if Canonical.hash(Boundary.actor_descriptor(context.actor)) ~= query.data_ref.actor_hash then
    return failure(provider_id, "stale-world", "actor-configuration-changed")
  end
  if context.actor.position.x ~= query.start.x or context.actor.position.y ~= query.start.y then
    return failure(provider_id, "stale-world", "actor-moved")
  end
  if result.outcome ~= "complete" then
    return failure(provider_id, result.outcome, "solver-" .. result.outcome)
  end
  local points = assert(Serializable.copy(result.points))
  return {
    schema_version = 1, provider_id = provider_id, status = "success",
    values = {solver_outcome = result.outcome},
    route = {
      schema_version = 1, status = "success", source = result.solver.id,
      points = points, corridor = {}, actions = {}, dependencies = {},
      predicted = assert(Serializable.copy(result.predicted)),
      world_revisions = assert(Serializable.copy(query.data_ref.revisions)),
      values = {
        solver_result = assert(Serializable.copy(result)),
        navigation_query = assert(Serializable.copy(query)),
        coverage = assert(Serializable.copy(snapshot.coverage)),
        dependency_scope = "whole-snapshot"
      },
      metrics = {schema_version = 1, values = {solver = assert(Serializable.copy(result.metrics))}}
    },
    metrics = {schema_version = 1, values = {solver_outcome = result.outcome}}
  }
end

function Imported.provide(context)
  return Imported.adapt(context, context.solver_result)
end

return Imported
