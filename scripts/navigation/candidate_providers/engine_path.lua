local Contracts = require("scripts.navigation.contracts")
local PathMath = require("scripts.path_math")
local PathSmoothing = require("scripts.path_smoothing")

local EnginePath = {}

local function metrics(values)
  return {
    schema_version = Contracts.VERSION,
    values = values or {}
  }
end

local function route(source, points, event)
  local raw_distance = PathMath.polyline_distance(event.start_position, points)
  return {
    schema_version = Contracts.VERSION,
    status = "success",
    source = source,
    points = points,
    corridor = {},
    actions = {},
    dependencies = {},
    predicted = {},
    world_revisions = {},
    metrics = metrics({
      raw_distance = raw_distance,
      raw_waypoint_count = #points,
      engine_path = event.logged_path
    })
  }
end

function EnginePath.request(context, inflated)
  local actor = context.actor
  local prototype = actor.prototype
  local bounding_box = prototype.collision_box
  if inflated then
    bounding_box = PathSmoothing.collision_box(
      actor,
      PathSmoothing.clearance_margin(actor)
    )
  end

  local config = context.profile.config.engine_requests
  local specification = {
    bounding_box = bounding_box,
    collision_mask = prototype.collision_mask,
    start = context.start_position,
    goal = context.goal_position,
    force = actor.force,
    radius = PathMath.ARRIVAL_DISTANCE,
    pathfind_flags = {
      prefer_straight_paths = config.prefer_straight_paths,
      cache = config.cache
    },
    can_open_gates = config.can_open_gates,
    entity_to_ignore = actor
  }
  if context.request_path then return context.request_path(specification) end
  return context.surface.request_path(specification)
end

function EnginePath.result(context, event, provider_id, source)
  if event.try_again_later then
    return {
      schema_version = Contracts.VERSION,
      provider_id = provider_id,
      status = "busy",
      metrics = metrics()
    }
  end
  if not event.path then
    return {
      schema_version = Contracts.VERSION,
      provider_id = provider_id,
      status = "no-path",
      metrics = metrics()
    }
  end

  local points, logged_path = PathMath.path_from_event(event)
  return {
    schema_version = Contracts.VERSION,
    provider_id = provider_id,
    status = "success",
    route = route(source, points, {
      start_position = context.start_position,
      logged_path = logged_path
    }),
    metrics = metrics({waypoint_count = #event.path})
  }
end

return EnginePath
