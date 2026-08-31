local Contracts = require("scripts.navigation.contracts")
local LocalPlanner = require("scripts.local_planner")

local GridAStar = {kind = "sync", required = false}

local function metrics(values)
  return {schema_version = Contracts.VERSION, values = values or {}}
end

function GridAStar.provide(context)
  local baseline = context.candidates_by_provider["engine-normal"]
  if not baseline or baseline.status ~= "success" then
    return {
      schema_version = Contracts.VERSION,
      provider_id = "grid-a-star",
      status = "no-path",
      metrics = metrics({reason = "missing-engine-baseline"})
    }
  end

  local points, search_metrics = LocalPlanner.search(
    context.surface,
    context.actor,
    context.start_position,
    context.goal_position,
    baseline.route.points
  )
  if not points then
    return {
      schema_version = Contracts.VERSION,
      provider_id = "grid-a-star",
      status = "no-path",
      metrics = metrics(search_metrics)
    }
  end
  return {
    schema_version = Contracts.VERSION,
    provider_id = "grid-a-star",
    status = "success",
    route = {
      schema_version = Contracts.VERSION,
      status = "success",
      source = "grid-a-star",
      points = points,
      corridor = {},
      actions = {},
      dependencies = {},
      predicted = {},
      world_revisions = {},
      metrics = metrics(search_metrics)
    },
    metrics = metrics(search_metrics)
  }
end

return GridAStar
