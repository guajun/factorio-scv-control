local Boundary = require("__factorio-scv-control__/scripts/navigation/solver_boundary")
local Canonical = require("__factorio-scv-control__/scripts/navigation/canonical")
local Follower = require("__factorio-scv-control__/scripts/follower")
local PathMath = require("__factorio-scv-control__/scripts/path_math")
local PlanningRun = require("__factorio-scv-control__/scripts/navigation/planning_run")
local Capture = require("__scv-control-testkit__/interchange/capture")

local Replay = {PROFILE_ID = "interchange-distance-v1"}
local SURFACE = "scv-navigation-replay"

local function copy_position(point) return {x = point.x, y = point.y} end

local function failure(code, message)
  return nil, {code = code, message = message}
end

function Replay.prepare(case, options)
  options = options or {}
  if type(case) ~= "table" or not case.snapshot or not case.query or not case.result then
    return failure("invalid-replay-case", "Replay needs captured snapshot, query and solver result.")
  end
  local snapshot, query = case.snapshot, case.query
  local valid, validation_error = Boundary.validate_snapshot(snapshot)
  if not valid then return nil, validation_error end
  valid, validation_error = Boundary.validate_query(query)
  if not valid then return nil, validation_error end
  if query.objective.id ~= "distance" then
    return failure("unsupported-replay-objective", "Native replay currently supports static distance only.")
  end
  local hash = Canonical.hash(snapshot)
  if hash ~= query.data_ref.snapshot_hash then
    return failure("snapshot-hash-mismatch", "Snapshot does not match the pinned query.")
  end
  if snapshot.exporter and snapshot.exporter.factorio_version ~= script.active_mods.base then
    return failure("factorio-version-mismatch", "Replay requires the captured Factorio version.")
  end
  local surface_name = options.surface_name or SURFACE
  if surface_name ~= SURFACE and not surface_name:match("^scv-navigation-replay%-") then
    return failure("invalid-replay-surface", "Replay surfaces must use the dedicated scv-navigation-replay name prefix.")
  end
  local surface = Capture.ensure_surface(surface_name)
  local bounds = snapshot.coverage.bounds
  for cx = math.floor(bounds.left_top.x / 32), math.floor(bounds.right_bottom.x / 32) do
    for cy = math.floor(bounds.left_top.y / 32), math.floor(bounds.right_bottom.y / 32) do
      surface.request_to_generate_chunks({x = cx * 32 + 16, y = cy * 32 + 16}, 0)
    end
  end
  surface.force_generate_chunk_requests()
  -- This surface is owned by interchange replay, never a player's ordinary surface.
  for _, entity in pairs(surface.find_entities()) do entity.destroy() end
  for _, object in pairs(rendering.get_all_objects()) do
    if object.surface == surface then object.destroy() end
  end
  local tiles = {}
  for x = math.floor(bounds.left_top.x) - 2, math.ceil(bounds.right_bottom.x) + 1 do
    for y = math.floor(bounds.left_top.y) - 2, math.ceil(bounds.right_bottom.y) + 1 do
      tiles[#tiles + 1] = {name = "out-of-map", position = {x = x, y = y}}
    end
  end
  surface.set_tiles(tiles, true, false, false, false)
  tiles = {}
  for _, tile in ipairs(snapshot.geometry.tiles) do
    if not prototypes.tile[tile.name] then return failure("missing-tile-prototype", tile.name) end
    tiles[#tiles + 1] = {name = tile.name, position = copy_position(tile.position)}
  end
  surface.set_tiles(tiles, true, false, false, false)
  for _, fact in ipairs(snapshot.geometry.entities) do
    if not Capture.supports_entity_type(fact.type) then
      return failure("unsupported-world-semantics", "Static replay cannot reconstruct " .. tostring(fact.type) .. ".")
    end
    if not prototypes.entity[fact.name] or not game.forces[fact.force] then
      return failure("missing-entity-prototype-or-force", fact.name)
    end
    local entity = surface.create_entity({
      name = fact.name, position = fact.position, direction = fact.direction, force = fact.force
    })
    if not entity then return failure("entity-reconstruction-failed", fact.id) end
  end
  local actor = surface.create_entity({name = snapshot.actor.name, position = query.start, force = snapshot.actor.force})
  if not actor then return failure("actor-reconstruction-failed", case.id) end
  if Canonical.hash(Boundary.actor_descriptor(actor)) ~= query.data_ref.actor_hash then
    actor.destroy()
    return failure("actor-configuration-mismatch", "Replay cannot reconstruct this actor's modifiers.")
  end
  return {surface = surface, actor = actor, case_id = case.id, snapshot = snapshot,
    query = query, result = case.result, status = "prepared", started_tick = game.tick,
    max_ticks = options.max_ticks or 3600, actual_distance = 0, direction_switches = 0,
    max_cross_track_error = 0, last_position = copy_position(actor.position)}
end

function Replay.start(session)
  local run, result = PlanningRun.start({schema_version = 1, profile_id = Replay.PROFILE_ID, values = {}}, {
    id = session.query.query_id, command_id = session.query.command_id,
    adapter_id = "offline-interchange-replay-v1", reason = "offline-replay",
    start_position = session.query.start, goal_position = session.query.goal,
    navigation_query = session.query
  }, {
    surface = session.surface, actor = session.actor, tick = game.tick,
    solver_result = session.result, navigation_data_ref = session.query.data_ref,
    navigation_snapshot = session.snapshot
  })
  return Replay.activate(session, run, result)
end

-- Both offline import and the live external-provider completion use this adapter.
-- PlanningRun owns admission/validation; this only activates its accepted route.
function Replay.activate(session, run, result)
  session.planning_run, session.planning_result = run, result
  session.execution_arrival_tolerance = Follower.tolerance(session.actor)
  if session.query.execution and session.query.execution.arrival_tolerance ~= session.execution_arrival_tolerance then
    session.status, session.reason = "rejected", "execution-contract-mismatch"
    Follower.stop(session.actor)
    return session
  end
  if not run or not result or result.status ~= "success" then
    session.status = "rejected"
    session.reason = result and (result.reason or result.message or result.status) or "planning-start-failed"
    Follower.stop(session.actor)
    return session
  end
  session.status = "moving"
  session.command_direction_changes, session.issued_direction_samples = 0, 0
  session.last_command_direction = nil
  session.follow_state = {path = result.route.points, waypoint_index = 1,
    segment_start = copy_position(session.actor.position), recovery_attempts = 0}
  session.movement_started_tick = game.tick
  return session
end

function Replay.update(session, tick)
  if session.status ~= "moving" then return session.status end
  local actor = session.actor
  if not actor or not actor.valid then session.status, session.reason = "failed", "actor-invalid"; return session.status end
  session.actual_distance = session.actual_distance + PathMath.distance(actor.position, session.last_position)
  session.last_position = copy_position(actor.position)
  local status, diagnostics = Follower.advance(actor, session.follow_state, session.query.goal)
  diagnostics = diagnostics or {}
  session.max_cross_track_error = math.max(session.max_cross_track_error, math.abs(diagnostics.cross_track_error or 0))
  if diagnostics.switched then session.direction_switches = session.direction_switches + 1 end
  -- Trajectory state resets at each waypoint, so its `switched` flag counts
  -- only changes within that segment. Observe the direction actually issued by
  -- Follower across segment boundaries too. Reading walking_state immediately
  -- after assignment can expose the previous native state in this event.
  if status == "moving" and diagnostics.selected_direction ~= nil then
    local direction = diagnostics.selected_direction
    if session.last_command_direction ~= nil and direction ~= session.last_command_direction then
      session.command_direction_changes = (session.command_direction_changes or 0) + 1
    end
    session.last_command_direction = direction
    session.issued_direction_samples = (session.issued_direction_samples or 0) + 1
  end
  if status == "arrived" then
    session.arrival_error = PathMath.distance(actor.position, session.query.goal)
    session.status = session.arrival_error <= session.execution_arrival_tolerance
      and "arrived" or "failed"
    session.reason = session.status == "arrived" and "within-arrival-bound" or "arrival-outside-bound"
  elseif status == "replan" then
    session.status, session.reason = "failed", "follower-requested-replan"
  elseif tick - (session.movement_started_tick or session.started_tick) > session.max_ticks then
    session.status, session.reason = "failed", "replay-tick-guard"
  end
  if session.status ~= "moving" then
    Follower.stop(actor)
    session.finished_tick, session.actual_travel_ticks = tick, tick - session.movement_started_tick
  end
  return session.status
end

function Replay.report(session)
  return {
    id = session.case_id, query_id = session.query.query_id, query_hash = session.query.query_hash,
    data_ref = session.query.data_ref, outcome = session.status, reason = session.reason,
    raw_result = session.result, final_result = session.planning_result,
    actual_travel_ticks = session.actual_travel_ticks, actual_distance = session.actual_distance,
    arrival_error = session.arrival_error, direction_switches = session.direction_switches,
    direction_switches_scope = "within-trajectory-segment-hysteresis-switches",
    command_direction_changes = session.command_direction_changes or 0,
    command_direction_changes_scope = "consecutive-issued-walking-directions-including-waypoint-transitions",
    issued_direction_samples = session.issued_direction_samples or 0,
    execution_arrival_tolerance = session.execution_arrival_tolerance,
    max_cross_track_error = session.max_cross_track_error
  }
end

function Replay.draw(session, player_index)
  local function draw(points, color, width)
    if type(points) ~= "table" or #points > session.query.budget.max_points then return end
    local bounds = session.snapshot.coverage.bounds
    for _, p in ipairs(points) do
      if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number"
          or p.x ~= p.x or p.y ~= p.y
          or p.x < bounds.left_top.x or p.x > bounds.right_bottom.x
          or p.y < bounds.left_top.y or p.y > bounds.right_bottom.y then return end
    end
    for index = 2, #(points or {}) do
      rendering.draw_line({surface = session.surface, from = points[index - 1], to = points[index],
        color = color, width = width, players = player_index and {player_index} or nil, draw_on_ground = true})
    end
  end
  draw(session.result.points, {r = 1, g = 0.6, b = 0.1, a = 0.9}, 2)
  if session.planning_result and session.planning_result.route then
    draw(session.planning_result.route.points, {r = 0.1, g = 0.8, b = 1, a = 1}, 4)
  end
end

return Replay
