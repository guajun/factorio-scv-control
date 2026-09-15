local Contract = require('comparison.contract')
local Runtime = require('comparison.runtime')
local Replay = require('interchange.replay')
local Boundary = require('__factorio-scv-control__/scripts/navigation/solver_boundary')
local Canonical = require('__factorio-scv-control__/scripts/navigation/canonical')
local Data = require('__factorio-scv-control__/scripts/navigation/navigation_data')
local Serializable = require('__factorio-scv-control__/scripts/navigation/serializable')
local Tests = {}
local function copy(value) return assert(Serializable.copy(value)) end
local function fixture()
  local actor = {name = 'character', force = 'player', character_running_speed = 0.15,
    prototype = {collision_box = {left_top = {x = -0.2, y = -0.2}, right_bottom = {x = 0.2, y = 0.2}},
      collision_mask = {layers = {}}}}
  local snapshot = {protocol = Boundary.PROTOCOL, kind = 'world-snapshot', snapshot_id = 'source',
    world_id = 'world', surface_id = '1', captured_tick = 0, actor = Boundary.actor_descriptor(actor),
    revisions = {topology = 0, motion = 0}, coverage = {
      bounds = {left_top = {x = -2, y = -2}, right_bottom = {x = 8, y = 2}}, unknown = 'blocked'},
    geometry = {entities = {}, tiles = {}}, graph = {
      nodes = {{id = 'start', position = {x = 0, y = 0}}, {id = 'goal', position = {x = 4, y = 0}}},
      edges = {{from = 'start', to = 'goal', distance = 4}}}}
  local data = assert(Data.new({backend_id = 'reference-graph-v1', backend_version = '1', session_id = 'session'}))
  local ref = assert(Data.load_world(data, snapshot))
  local query = {protocol = Boundary.PROTOCOL, kind = 'navigation-query', query_id = 'query',
    session_id = 'session', command_id = '1', attempt_id = '1', snapshot_id = 'source', data_ref = ref,
    start = {x = 0, y = 0}, goal = {x = 4, y = 0}, start_node = 'start', goal_node = 'goal',
    goal_tolerance = 0.1, objective = {id = 'distance', units = 'tiles'},
    required_capabilities = {'directed-graph-v1', 'distance', 'finite-bounds'},
    budget = {max_expansions = 10, max_points = 10}}
  query.query_hash = assert(Boundary.hash_query(query))
  local result = {protocol = Boundary.PROTOCOL, kind = 'solver-result', query_id = query.query_id,
    session_id = query.session_id, command_id = query.command_id, attempt_id = query.attempt_id,
    snapshot_id = query.snapshot_id, query_hash = query.query_hash, data_ref = copy(ref),
    outcome = 'complete', objective = copy(query.objective), solver = {id = 'python-graph-astar', version = '1'},
    points = {copy(query.start), copy(query.goal)}, predicted = {distance = 4},
    coverage = copy(snapshot.coverage), metrics = {algorithm = 'astar'}}
  result.coverage.scope = 'bounded-graph'
  return {snapshot = snapshot, query = query}, {source_facts_hash = 'facts',
    source_snapshot_hash = ref.snapshot_hash, source_query_hash = query.query_hash, result = result}
end
local function polygon(resident, payload)
  payload = copy(payload)
  local snapshot, query = copy(resident.snapshot), copy(resident.query)
  local backend = 'extremity-source-polygons-v1'
  snapshot.snapshot_id = snapshot.snapshot_id .. ':' .. backend
  snapshot.graph.representation = {id = backend, version = 1}
  snapshot.source_input = {snapshot_id = resident.snapshot.snapshot_id,
    snapshot_hash = resident.query.data_ref.snapshot_hash, query_hash = resident.query.query_hash}
  query.snapshot_id, query.query_id = snapshot.snapshot_id, query.query_id .. ':' .. backend
  query.data_ref.backend_id, query.data_ref.generation_id = backend, query.data_ref.generation_id .. ':' .. backend
  query.data_ref.config_hash = assert(Canonical.hash({version = 1}))
  query.data_ref.snapshot_id, query.data_ref.snapshot_hash = snapshot.snapshot_id, assert(Canonical.hash(snapshot))
  query.query_hash = assert(Boundary.hash_query(query))
  payload.derived = {snapshot_id = snapshot.snapshot_id, source_input = snapshot.source_input,
    graph = snapshot.graph, query = query}
  payload.result.solver.id = 'extremitypathfinder'
  for _, name in ipairs({'query_id', 'snapshot_id', 'query_hash', 'data_ref'}) do payload.result[name] = copy(query[name]) end
  return payload
end

function Tests.run(expect)
  expect('comparison.ordinary-save-cannot-enable-service', Runtime.dispatch({protocol = Contract.PROTOCOL,
    operation = 'catalog'}).reason == 'comparison-map-required')
  local resident, payload = fixture()
  local admitted = Contract.admission(resident, payload, 'grid-astar', 'facts')
  expect('comparison.grid-uses-resident-source', admitted ~= nil and admitted.snapshot == resident.snapshot)
  local mislabeled = copy(payload); mislabeled.result.solver.id = 'python-graph-dijkstra'
  local _, mislabeled_reason = Contract.admission(resident, mislabeled, 'grid-astar', 'facts')
  expect('comparison-search-algorithm-label-must-match-result', mislabeled_reason == 'solver-algorithm-identity-mismatch')
  local changed = copy(payload); changed.source_facts_hash = 'old-facts'
  local _, reason = Contract.admission(resident, changed, 'grid-astar', 'facts')
  expect('comparison.stale-source-facts-rejected', reason == 'source-facts-identity-mismatch')
  changed = copy(payload); changed.source_snapshot_hash = 'another-save'
  _, reason = Contract.admission(resident, changed, 'grid-astar', 'facts')
  expect('comparison.stale-capture-rejected', reason == 'source-capture-identity-mismatch')
  changed = copy(payload); changed.result.points[2].x = 100
  admitted = Contract.admission(resident, changed, 'grid-astar', 'facts')
  expect('comparison.result-still-uses-boundary-validation', admitted == nil)
  local derived = polygon(resident, payload)
  admitted = Contract.admission(resident, derived, 'source-polygons', 'facts')
  expect('comparison.compact-derived-admission-preserves-geometry', admitted ~= nil
    and Canonical.encode(admitted.snapshot.geometry) == Canonical.encode(resident.snapshot.geometry))
  changed = copy(derived); changed.derived.geometry = {entities = {}, tiles = {}}
  _, reason = Contract.admission(resident, changed, 'source-polygons', 'facts')
  expect('comparison.geometry-upload-rejected', reason == 'invalid-derived-fields')
  changed = copy(derived); changed.derived.query.goal.x = 5
  changed.derived.query.query_hash = assert(Boundary.hash_query(changed.derived.query))
  _, reason = Contract.admission(resident, changed, 'source-polygons', 'facts')
  expect('comparison-derived-command-cannot-change', reason == 'derived-command-changed')
  changed = copy(derived); changed.derived.query.budget.max_expansions = 999
  _, reason = Contract.admission(resident, changed, 'source-polygons', 'facts')
  expect('comparison-derived-budget-cannot-change', reason == 'derived-command-changed')
  changed = copy(derived); changed.derived.graph.nodes[2].position.x = 5
  _, reason = Contract.admission(resident, changed, 'source-polygons', 'facts')
  expect('comparison-derived-graph-hash-verified', reason == 'derived-content-hash-mismatch')
  changed = copy(derived); changed.derived.query.data_ref.revisions.topology = 2
  _, reason = Contract.admission(resident, changed, 'source-polygons', 'facts')
  expect('comparison-derived-world-revision-cannot-change', reason == 'derived-world-identity-changed')
  changed = copy(derived); changed.derived.query.data_ref.backend_id = 'some-other-backend'
  _, reason = Contract.admission(resident, changed, 'source-polygons', 'facts')
  expect('comparison-derived-backend-cannot-be-mislabelled', reason == 'derived-backend-identity-mismatch')
  changed = copy(derived); changed.derived.graph.representation.version = 2
  _, reason = Contract.admission(resident, changed, 'source-polygons', 'facts')
  expect('comparison-derived-config-hash-verified', reason == 'derived-config-hash-mismatch')
  changed = copy(derived); changed.derived.query.data_ref = 1
  local safe, value = pcall(Contract.admission, resident, changed, 'source-polygons', 'facts')
  expect('comparison-malformed-input-rejects-without-throwing', safe and value == nil)
  expect('comparison-actor-origin-is-exact', not Contract.source_position({valid = true,
    position = {x = 0.001, y = 0}}, {x = 0, y = 0}))
  local upload = {}
  local ok = Contract.upload(upload, {index = 2, text = '{}', reset = true})
  expect('comparison-upload-reset-needs-first-index', ok == nil)
  ok = Contract.upload(upload, {index = 1, text = '{', reset = true})
  local duplicate, detail = Contract.upload(upload, {index = 1, text = '{'})
  expect('comparison-upload-idempotent-retry', ok == true and duplicate == true and detail == 'duplicate'
    and upload.upload_bytes == 1 and upload.upload_next == 2)
  ok = Contract.upload(upload, {index = 1, text = '{}'})
  expect('comparison-upload-conflicting-retry-rejected', ok == nil and upload.upload_bytes == 1)
  ok = Contract.upload(upload, {index = 3, text = '}'})
  expect('comparison-upload-out-of-order-rejected', ok == nil and upload.upload_next == 2)

  -- This checks instrumentation through the real Follower, not a duplicate
  -- controller. Positions are supplied observations; native movement remains
  -- covered by the saved slalom/U-trap arrivals and their metric assertions.
  local actor = {valid = true, position = {x = 0, y = 0}, character_running_speed = 0.1}
  local goal = {x = 4, y = 2}
  local session = {actor = actor, query = {goal = goal}, actual_distance = 0,
    direction_switches = 0, max_cross_track_error = 0, last_position = copy(actor.position), max_ticks = 100}
  Replay.activate(session, {}, {status = 'success', route = {points = {
    {x = 2, y = 0}, {x = 2, y = 2}, copy(goal)}}})
  for index, observation in ipairs({{x = 0, y = 0}, {x = 1, y = 0}, {x = 2, y = 0},
      {x = 2, y = 1}, {x = 2, y = 2}}) do
    actor.position = observation
    Replay.update(session, game.tick + index)
  end
  expect('comparison-issued-directions-count-waypoint-turns', session.command_direction_changes == 2
    and session.issued_direction_samples == 5 and session.direction_switches == 0)
  actor.position = copy(goal)
  Replay.update(session, game.tick + 6)
  local metrics = Replay.report(session)
  expect('comparison-direction-count-excludes-arrival-stop', session.status == 'arrived'
    and metrics.command_direction_changes == 2 and metrics.issued_direction_samples == 5
    and metrics.direction_switches_scope == 'within-trajectory-segment-hysteresis-switches')
end
return Tests
