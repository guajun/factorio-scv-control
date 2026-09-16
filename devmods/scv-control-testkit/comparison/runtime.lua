local Catalog = require('comparison.catalog')
local Contract = require('comparison.contract')
local Facts = require('savebench.facts')
local Fixtures = require('pathfinding.fixtures')
local Capture = require('interchange.capture')
local Replay = require('interchange.replay')
local Clock = require('debug.clock')
local PlanningRun = require('__factorio-scv-control__/scripts/navigation/planning_run')
local Follower = require('__factorio-scv-control__/scripts/follower')
local PathMath = require('__factorio-scv-control__/scripts/path_math')
local Canonical = require('__factorio-scv-control__/scripts/navigation/canonical')
local Serializable = require('__factorio-scv-control__/scripts/navigation/serializable')
local WireJson = require('__factorio-scv-control__/scripts/navigation/wire_json')
local Boundary = require('__factorio-scv-control__/scripts/navigation/solver_boundary')
local NavigationData = require('__factorio-scv-control__/scripts/navigation/navigation_data')

local Runtime = {PROTOCOL = Contract.PROTOCOL}
local ROOT = 'scv-control/comparison/'
local RESULT_PATH, FACTS_PATH, WORK_PATH = ROOT .. 'result.json', ROOT .. 'facts.json', ROOT .. 'work.json'
local PERFORMANCE_PATH = ROOT .. 'performance.jsonl'
local loaded_from_save, runtime_build_calls = false, 0 -- diagnostic only; never govern synchronized state
local profiles = {}
local function lab_enabled() return remote.interfaces.scv_unified_lab ~= nil end
local function enabled() return remote.interfaces.scv_navigation_comparison ~= nil or lab_enabled() end
local function state() return storage.scv_navigation_comparison end
local function point(value) return {x = value.x, y = value.y} end
local function copy(value) return assert(Serializable.copy(value)) end
local function json(value) return assert(WireJson.encode(value)) end
local function error_reply(reason) return {ok = false, protocol = Runtime.PROTOCOL, reason = reason} end

local function profile(name, callback)
  local timer = game.create_profiler()
  local ok, value = pcall(callback)
  timer.stop()
  local aggregate = profiles[name]
  if not aggregate then aggregate = {timer = game.create_profiler(true), count = 0}; profiles[name] = aggregate end
  aggregate.timer.add(timer); aggregate.count = aggregate.count + 1
  helpers.write_file(PERFORMANCE_PATH, {'', '{"kind":"hook","hook":"', name,
    '","tick":', game.tick, ',"duration":"', timer, '"}\n'}, true, 0)
  if not ok then error(value) end
  return value
end

local function finish_profiles()
  local names = {}
  for name in pairs(profiles) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local item = profiles[name]
    helpers.write_file(PERFORMANCE_PATH, {'', '{"kind":"aggregate","hook":"', name,
      '","count":', item.count, ',"duration":"', item.timer, '"}\n'}, true, 0)
  end
end

local function status()
  local s = state()
  local actor = s and s.actor
  return {ok = true, protocol = Runtime.PROTOCOL, phase = s and s.phase or 'idle',
    case_id = s and s.case and s.case.id or false, fixture_version = s and s.case and s.case.fixture_version or false,
    loaded_from_save = loaded_from_save, runtime_build_calls = runtime_build_calls,
    actor_position = actor and actor.valid and point(actor.position) or false,
    actor_unit_number = actor and actor.valid and actor.unit_number or false,
    source_facts_hash = s and s.source_facts_hash or false, source_verified = s and s.source_verified == true,
    game_tick = game.tick, paused = game.tick_paused, ticks_to_run = game.ticks_to_run,
    expected_path = s and s.case and s.case.expected_path == true,
    algorithm = s and s.algorithm or false, pass = s and s.pass or false,
    plan_count = s and s.plans and #s.plans or 0,
    planning_outcome = s and s.planning_result and s.planning_result.status or false,
    reason = s and s.reason or false, report_path = s and s.report_available and RESULT_PATH or false,
    performance_path = PERFORMANCE_PATH, capture_path = s and s.capture and WORK_PATH or false,
    passed = s and s.report_passed == true}
end

local function capture_facts(s)
  return Facts.capture(s.surface, s.actor, s.facts_bounds, {
    case_id = s.case.id, domain = 'static', fixture_version = s.case.fixture_version,
    start = s.case.start, goal = s.case.goal, state_key = 'baseline',
    scenario = 'navigation-comparison', scope = s.case.scope})
end

local function verify_source(s)
  if not s.actor or not s.actor.valid or not s.surface or not s.surface.valid
    or s.actor.surface ~= s.surface then return nil, 'source-actor-or-surface-missing' end
  if not Contract.source_position(s.actor, s.actor_origin) then return nil, 'source-actor-origin-changed' end
  if not game.tick_paused or game.ticks_to_run ~= 0 then return nil, 'source-must-be-paused' end
  local captured = profile('source_check', function()
    local facts, detail = capture_facts(s)
    return {facts = facts, detail = detail}
  end)
  if not captured.facts then return nil, captured.detail.code end
  if captured.facts.facts_hash ~= s.source_facts_hash then return nil, 'source-facts-changed' end
  s.source_verified = true
  return true
end

local function report(s, terminal)
  local native = s.session and Replay.report(s.session) or {outcome = terminal or s.phase,
    actual_travel_ticks = 0, actual_distance = 0, direction_switches = 0,
    direction_switches_scope = 'within-trajectory-segment-hysteresis-switches',
    command_direction_changes = 0, issued_direction_samples = 0,
    command_direction_changes_scope = 'consecutive-issued-walking-directions-including-waypoint-transitions',
    arrival_error = false, reason = s.reason or false}
  if terminal == 'no-path' then native.outcome, native.reason = 'no-path', 'planner-bounded-no-path' end
  local expected_outcome = s.case.expected_path and 'arrived' or 'no-path'
  local assertions = {
    {name = 'source-facts-verified', passed = s.source_verified == true},
    {name = 'expected-native-outcome', passed = native.outcome == expected_outcome,
      expected = expected_outcome, actual = native.outcome},
    {name = 'planning-cold-repeat-consistent', passed = #s.plans <= 1 or
      (s.plans[1].outcome == s.plans[2].outcome and
       Canonical.encode(s.plans[1].final_path) == Canonical.encode(s.plans[2].final_path))}
  }
  if s.case.id == 'slalom' or s.case.id == 'captured-slalom-return' or s.case.id == 'u-trap' then
    assertions[#assertions + 1] = {name = 'native-detour-command-turns-observed',
      passed = native.outcome == 'arrived' and (native.command_direction_changes or 0) > 0,
      command_direction_changes = native.command_direction_changes or 0,
      issued_direction_samples = native.issued_direction_samples or 0}
  end
  local passed = true
  for _, assertion in ipairs(assertions) do passed = passed and assertion.passed end
  return {protocol = Runtime.PROTOCOL, schema_version = 1, case_id = s.case.id,
    fixture_version = s.case.fixture_version, algorithm = s.algorithm or false,
    source_facts_hash = s.source_facts_hash, source_verified = s.source_verified == true,
    loaded_from_save = loaded_from_save, runtime_build_calls = runtime_build_calls,
    factorio_version = script.active_mods.base, expected_path = s.case.expected_path,
    source_snapshot_hash = s.capture and s.capture.query.data_ref.snapshot_hash or false,
    source_query_hash = s.capture and s.capture.query.query_hash or false,
    source_prepared_tick = s.prepared_tick, completed_tick = game.tick,
    plans = s.plans, native = native, passed = passed, assertions = assertions,
    reference_playback = s.reference_playback == true, not_fresh_solver = s.reference_playback == true,
    reference_provenance = s.reference_provenance or false,
    performance_path = PERFORMANCE_PATH, paused_solver_correctness = s.algorithm ~= 'production-v1'}
end

local function publish(s, terminal)
  -- Process-local provenance belongs only in diagnostics, never in storage:
  -- a joining peer has run on_load even when the authoring server has not.
  local value = report(s, terminal)
  s.report_available, s.report_passed = true, value.passed
  helpers.write_file(RESULT_PATH, json(value), false, 0)
end

local function finish(s, outcome, reason)
  if s.actor and s.actor.valid then Follower.stop(s.actor) end
  s.phase, s.reason = 'complete', reason
  game.tick_paused, game.ticks_to_run = true, 0
  publish(s, outcome)
  finish_profiles()
  log('SCV_COMPARE_COMPLETE case=' .. s.case.id .. ' algorithm=' .. tostring(s.algorithm)
    .. ' outcome=' .. outcome .. ' passed=' .. tostring(s.report_passed))
end

local function fail(s, reason)
  if not s or not s.case then return error_reply(reason) end
  finish(s, 'failed', reason)
  s.phase = 'failed'
  return status()
end

local function watch(player)
  -- The unified hub owns its spectator/free-control lifecycle and camera.
  if lab_enabled() then return end
  local s = state()
  if not s or not s.actor or not s.actor.valid then return end
  player.set_controller({type = defines.controllers.spectator})
  player.teleport(s.actor.position, s.surface)
  player.zoom = 0.9
  player.force.chart(s.surface, s.case.bounds)
  player.print('Saved static comparison: ' .. s.case.id .. '. /scv-compare plan previews production-v1;'
    .. ' /scv-compare run executes it. The map starts paused. Reload the ZIP to restore its source.')
end

local function prepare(s, id)
  if s.phase ~= 'idle' then return error_reply('prepare-requires-fresh-marker-map') end
  local case = Catalog.get(id)
  if not case then return error_reply('unknown-case') end
  game.tick_paused, game.ticks_to_run = true, 0
  local surface = Capture.ensure_surface('scv-navigation-comparison-source')
  if lab_enabled() then
    -- A previous scene's out-of-map tiles erase the substrate. Reapplying
    -- concrete directly would look right but omit its hidden grass layer and
    -- fail the original source-facts identity. Restore real native substrate
    -- before the shared fixture authoring step; never mask this difference in
    -- the facts hash or modify an authoritative ZIP during replay.
    local substrate = {}
    for x = Fixtures.AREA[1][1], Fixtures.AREA[2][1] - 1 do
      for y = Fixtures.AREA[1][2], Fixtures.AREA[2][2] - 1 do
        substrate[#substrate + 1] = {name = 'grass-1', position = {x, y}}
      end
    end
    surface.set_tiles(substrate, true, false, false, false)
  end
  -- The fixture builder is called only while authoring. Saved replays never use
  -- Fixtures.build, Capture.fixture or Replay.prepare.
  Fixtures.build(surface, case.fixture)
  runtime_build_calls = runtime_build_calls + 1
  local tiles = {}
  for x = Fixtures.AREA[1][1], Fixtures.AREA[2][1] - 1 do
    for y = Fixtures.AREA[1][2], Fixtures.AREA[2][2] - 1 do
      if x < case.bounds.left_top.x or x >= case.bounds.right_bottom.x
        or y < case.bounds.left_top.y or y >= case.bounds.right_bottom.y then
        tiles[#tiles + 1] = {name = 'out-of-map', position = {x, y}}
      end
    end
  end
  surface.set_tiles(tiles, true, false, false, false)
  local actor = assert(surface.create_entity({name = 'character', position = case.start, force = 'player'}))
  Follower.stop(actor)
  s.case, s.surface, s.actor, s.actor_origin = case, surface, actor, point(actor.position)
  s.facts_bounds = {left_top = {x = case.bounds.left_top.x - 2, y = case.bounds.left_top.y - 2},
    right_bottom = {x = case.bounds.right_bottom.x + 2, y = case.bounds.right_bottom.y + 2}}
  local facts, detail = capture_facts(s)
  if not facts then return fail(s, 'source-capture:' .. detail.code) end
  s.source_facts_hash, s.prepared_tick, s.phase, s.plans = facts.facts_hash, game.tick, 'prepared', {}
  for _, marker in ipairs({{point = case.start, label = 'START', color = {r = 0.2, g = 1, b = 0.4}},
      {point = case.goal, label = 'GOAL', color = {r = 0.2, g = 0.8, b = 1}}}) do
    rendering.draw_circle({surface = surface, target = marker.point, color = marker.color, radius = 0.55, width = 3})
    rendering.draw_text({surface = surface, target = {x = marker.point.x, y = marker.point.y - 1.2},
      color = marker.color, text = marker.label, alignment = 'center'})
  end
  rendering.draw_text({surface = surface, target = {x = case.bounds.left_top.x + 1, y = case.bounds.left_top.y + 1},
    color = {r = 1, g = 1, b = 1}, text = case.id .. '\n/scv-compare plan | run | pause | status'})
  for _, player in pairs(game.connected_players) do watch(player) end
  return status()
end

-- Hub-only scene lifecycle. Standalone authoritative source saves retain their
-- one-authoring-call boundary; these methods never exist as ordinary-save RPCs.
function Runtime.lab_release()
  if not lab_enabled() then return error_reply('unified-lab-required') end
  local s = state()
  if not s then
    storage.scv_navigation_comparison = {phase = 'idle', schema_version = 1, plans = {}, lab_sequence = 0}
    return status()
  end
  local surface = s.surface
  if surface and surface.valid then
    if not s.lab_owned_surface_index or s.lab_owned_surface_index ~= surface.index
      or surface.name ~= 'scv-navigation-comparison-source' then return error_reply('lab-surface-not-owned') end
    for _, player in pairs(game.players) do
      if player.valid and player.surface == surface then return error_reply('lab-scene-has-player') end
      if player.valid and player.character and player.character.valid and player.character.surface == surface then
        return error_reply('lab-scene-has-player-character')
      end
    end
  end
  game.tick_paused, game.ticks_to_run = true, 0
  if s.planning_run and s.planning_run.status == 'running' then
    PlanningRun.cancel(s.planning_run, 'unified-lab-scene-replaced', {tick = game.tick})
  end
  if s.actor and s.actor.valid then Follower.stop(s.actor); s.actor.destroy() end
  if surface and surface.valid then
    for _, object in pairs(rendering.get_all_objects()) do
      if object.valid and object.surface == surface then object.destroy() end
    end
  end
  storage.scv_navigation_comparison = {phase = 'idle', schema_version = 1, plans = {},
    lab_sequence = s.lab_sequence or 0, lab_owned_surface_index = s.lab_owned_surface_index}
  profiles = {}
  helpers.write_file(PERFORMANCE_PATH, '', false, 0)
  return status()
end

function Runtime.lab_select(id)
  if not lab_enabled() then return error_reply('unified-lab-required') end
  if not Catalog.get(id) then return error_reply('unknown-case') end
  local existing = game.get_surface('scv-navigation-comparison-source')
  if existing and (not state() or state().lab_owned_surface_index ~= existing.index) then
    return error_reply('lab-surface-not-owned')
  end
  local released = Runtime.lab_release()
  if not released.ok then return released end
  local s = state()
  s.lab_sequence = (s.lab_sequence or 0) + 1
  local response = prepare(s, id)
  if s.surface and s.surface.valid then s.lab_owned_surface_index = s.surface.index end
  return response
end

function Runtime.lab_actor()
  if not lab_enabled() then return nil end
  local s = state()
  return s and s.case and s.actor and s.actor.valid and s.actor or nil
end

function Runtime.lab_suspend()
  if not lab_enabled() then return error_reply('unified-lab-required') end
  local s = state()
  if not s or not s.case then return error_reply('source-required') end
  if s.planning_run and s.planning_run.status == 'running' then
    PlanningRun.cancel(s.planning_run, 'unified-lab-manual-control', {tick = game.tick})
  end
  if s.actor and s.actor.valid then Follower.stop(s.actor) end
  s.phase, s.auto_execute = 'manual', false
  return status()
end

function Runtime.lab_result()
  if not lab_enabled() then return nil end
  local s = state()
  if not s or not s.case or not s.report_available then return nil end
  return report(s, s.planning_result and s.planning_result.status == 'no-path' and 'no-path' or nil)
end

local function capture(s, message)
  if s.phase ~= 'prepared' then return error_reply('capture-requires-prepared-source') end
  local valid, reason = verify_source(s)
  if not valid then return error_reply(reason) end
  local session_id = 'saved-static-v4:' .. s.case.id .. ':' .. tostring(s.prepared_tick)
  local values = profile('capture', function()
    local snapshot, query = Capture.live(s.surface, s.actor, s.case.start, s.case.goal, s.case.bounds, {
      session_id = session_id, snapshot_id = session_id .. ':snapshot', query_id = session_id .. ':query',
      world_id = session_id, backend_session_id = session_id, command_id = '1', attempt_id = '1',
      include_graph = message.include_graph ~= false, resolution = message.resolution or 0.5,
      fixture = {id = s.case.id, version = s.case.fixture_version, category = s.case.category,
        expected_path = s.case.expected_path, original_walls = copy(s.case.fixture.walls)}})
    return {snapshot = snapshot, query = query}
  end)
  if not values.snapshot then return error_reply('capture:' .. values.query.code) end
  s.capture = {protocol = Runtime.PROTOCOL, kind = 'comparison-work', id = s.case.id,
    source_facts_hash = s.source_facts_hash, snapshot = values.snapshot, query = values.query}
  s.phase = 'captured'
  local encoded = json(s.capture)
  helpers.write_file(WORK_PATH, encoded, false, 0)
  return {ok = true, protocol = Runtime.PROTOCOL, path = WORK_PATH, bytes = #encoded,
    snapshot_hash = values.query.data_ref.snapshot_hash, query_hash = values.query.query_hash,
    source_facts_hash = s.source_facts_hash}
end

local function validate_pass(s, message)
  if s.phase ~= 'captured' and s.phase ~= 'planned' then return nil, 'planning-requires-captured-source' end
  if not Contract.ALGORITHMS[message.algorithm] then return nil, 'unknown-algorithm' end
  if s.algorithm and s.algorithm ~= message.algorithm then return nil, 'algorithm-change-requires-source-reload' end
  if (#s.plans == 0 and message.pass ~= 'cold') or (#s.plans == 1 and message.pass ~= 'repeat')
    or #s.plans >= 2 then return nil, 'invalid-planning-pass-order' end
  return verify_source(s)
end

local execute
local function planned(s, result)
  if not result or result.status == 'pending' or result.status == 'stale' then return end
  s.planning_result, s.phase = result, 'planned'
  Follower.stop(s.actor)
  game.tick_paused, game.ticks_to_run = true, 0
  local route = result.route
  local raw, raw_length, raw_scope = false, false, 'no-route'
  if route then
    local metrics = route.metrics and route.metrics.values or {}
    if s.solver_result then raw, raw_scope = copy(s.solver_result.points), 'external-solver-output'
    elseif metrics.raw_path then raw, raw_scope = copy(metrics.raw_path), 'provider-before-postprocess'
    elseif metrics.engine_path then raw, raw_scope = {}, 'engine-path-before-postprocess'
      for _, p in ipairs(metrics.engine_path) do raw[#raw + 1] = point(p) end
    else raw_scope = 'unavailable-after-production-postprocess' end
    raw_length = raw and PathMath.polyline_distance(s.case.start, raw) or metrics.raw_distance or false
  end
  local plan = {pass = s.pass, algorithm = s.algorithm, outcome = result.status,
    reason = result.reason or false, started_tick = s.plan_started_tick,
    duration_ticks = game.tick - s.plan_started_tick,
    raw_path = raw, raw_length = raw_length, raw_metric_scope = raw_scope,
    final_path = route and copy(route.points) or false,
    final_length = route and PathMath.polyline_distance(s.case.start, route.points) or false,
    selected_source = result.selected_source or false, provider_order = result.provider_order,
    request_count = result.metrics and result.metrics.values.request_count or 0,
    result = copy(result)}
  s.plans[#s.plans + 1] = plan
  publish(s)
  if route then
    local display = {surface = s.surface, actor = s.actor, query = s.execution_query or s.capture.query,
      snapshot = s.execution_snapshot or s.capture.snapshot, result = {points = raw or {}}, planning_result = result}
    Replay.draw(display)
  end
  if s.auto_execute then execute(s) end
end

local function begin_plan(s, message)
  if message.algorithm ~= 'production-v1' then return error_reply('external-plan-requires-upload-commit') end
  local valid, reason = validate_pass(s, message)
  if not valid then return error_reply(reason) end
  s.algorithm, s.pass, s.phase, s.plan_started_tick = message.algorithm, message.pass, 'planning', game.tick
  s.execution_query, s.execution_snapshot = s.capture.query, s.capture.snapshot
  s.solver_result, s.planning_result, s.reason = nil, nil, nil
  local values = profile(s.pass .. ':plan_start', function()
    local run, result = PlanningRun.start({schema_version = 1, profile_id = 'production-v1', values = {}}, {
      id = s.capture.query.query_id .. ':' .. s.pass, command_id = '1', adapter_id = 'saved-static-comparison-v1',
      reason = 'saved-map-comparison', start_position = s.case.start, goal_position = s.case.goal
    }, {surface = s.surface, actor = s.actor, tick = game.tick})
    return {run = run, result = result}
  end)
  s.planning_run = values.run
  if not values.run then return fail(s, 'planning-start-failed') end
  planned(s, values.result)
  if s.phase == 'planning' then game.speed, game.tick_paused = 1, false end
  return status()
end

local function commit(s, message)
  local valid, reason = validate_pass(s, message)
  if not valid then return error_reply(reason) end
  if not s.upload or s.upload_bytes == 0 then return error_reply('upload-required') end
  local ok, payload = pcall(helpers.json_to_table, table.concat(s.upload))
  if not ok or type(payload) ~= 'table' then return error_reply('invalid-upload-json') end
  local values = profile(message.pass .. ':admission', function()
    local admitted, detail = Contract.admission(s.capture, payload, message.algorithm, s.source_facts_hash)
    if not admitted then return {error = detail} end
    local run, result = PlanningRun.start({schema_version = 1, profile_id = Replay.PROFILE_ID, values = {}}, {
      id = admitted.query.query_id, command_id = admitted.query.command_id,
      adapter_id = 'saved-static-comparison-v1', reason = 'saved-map-external',
      start_position = admitted.query.start, goal_position = admitted.query.goal, navigation_query = admitted.query
    }, {surface = s.surface, actor = s.actor, tick = game.tick, solver_result = admitted.result,
      navigation_data_ref = admitted.query.data_ref, navigation_snapshot = admitted.snapshot})
    return {admitted = admitted, run = run, result = result}
  end)
  if values.error then return error_reply(values.error) end
  if not values.run or not values.result then return error_reply('external-planning-start-failed') end
  s.algorithm, s.pass, s.plan_started_tick = message.algorithm, message.pass, game.tick
  s.execution_query, s.execution_snapshot = values.admitted.query, values.admitted.snapshot
  s.planning_run, s.solver_result, s.reason = values.run, values.admitted.result, nil
  s.upload, s.upload_bytes, s.upload_next = nil, nil, nil
  planned(s, values.result)
  return status()
end

-- A recorded candidate is explicitly playback, not a pretend in-game solver.
-- Rebind it to observations of this scene and invoke the same imported-route
-- acceptance pipeline. No renderer or direct path-to-follower shortcut exists.
function Runtime.lab_plan_recording(record, algorithm)
  if not lab_enabled() then return error_reply('unified-lab-required') end
  local s = state()
  if not s or s.phase ~= 'prepared' then return error_reply('recording-requires-prepared-source') end
  if algorithm ~= 'grid-astar' and algorithm ~= 'grid-dijkstra' and algorithm ~= 'source-polygons' then
    return error_reply('unknown-recorded-algorithm')
  end
  if type(record) ~= 'table' or record.id ~= s.case.id or record.fixture_version ~= s.case.fixture_version
    or record.source_facts_hash ~= s.source_facts_hash then return error_reply('recording-source-identity-mismatch') end
  if type(record.source_save_sha256) ~= 'string' or #record.source_save_sha256 ~= 64
    or not record.source_save_sha256:match('^[0-9a-f]+$') then return error_reply('recording-source-save-hash-required') end
  local candidate = record.algorithms and record.algorithms[algorithm]
  if type(candidate) ~= 'table' or (candidate.outcome ~= 'complete' and candidate.outcome ~= 'no-path')
    or type(candidate.points) ~= 'table' or #candidate.points > 8194
    or type(candidate.source_snapshot_hash) ~= 'string' or type(candidate.source_query_hash) ~= 'string' then
    return error_reply('invalid-recorded-candidate')
  end
  local points = copy(candidate.points)
  if candidate.outcome == 'complete' then
    if #points < 2 then return error_reply('recorded-path-endpoints-required') end
    for _, p in ipairs(points) do
      if type(p) ~= 'table' or type(p.x) ~= 'number' or type(p.y) ~= 'number'
        or p.x ~= p.x or p.y ~= p.y or math.abs(p.x) == math.huge or math.abs(p.y) == math.huge then
        return error_reply('invalid-recorded-point')
      end
    end
    if Canonical.encode(points[1]) ~= Canonical.encode(s.case.start)
      or Canonical.encode(points[#points]) ~= Canonical.encode(s.case.goal) then
      return error_reply('recorded-path-command-endpoints-changed')
    end
    if type(candidate.predicted_distance) ~= 'number' or candidate.predicted_distance ~= candidate.predicted_distance
      or math.abs(PathMath.polyline_distance(s.case.start, points) - candidate.predicted_distance) > 1e-7 then
      return error_reply('recorded-distance-mismatch')
    end
  elseif #points ~= 0 then return error_reply('recorded-no-path-has-points') end
  local captured = capture(s, {include_graph = false})
  if not captured.ok then return captured end
  local snapshot, query = copy(s.capture.snapshot), copy(s.capture.query)
  snapshot.snapshot_id = snapshot.snapshot_id .. ':recorded:' .. algorithm
  snapshot.graph = {nodes = {}, edges = {}, representation = {id = 'recorded-reference-playback-v1',
    algorithm = algorithm, not_fresh_solver = true, source_save_sha256 = record.source_save_sha256,
    source_snapshot_hash = candidate.source_snapshot_hash, source_query_hash = candidate.source_query_hash}}
  local graph = snapshot.graph
  if candidate.outcome == 'complete' then
    for index, p in ipairs(points) do
      local id = index == 1 and 'start' or index == #points and 'goal' or ('recorded:' .. index)
      graph.nodes[index] = {id = id, position = point(p)}
      if index > 1 then graph.edges[#graph.edges + 1] = {from = graph.nodes[index - 1].id,
        to = id, distance = PathMath.distance(points[index - 1], p)} end
    end
  else graph.nodes = {{id = 'start', position = point(query.start)}, {id = 'goal', position = point(query.goal)}} end
  local data, data_error = NavigationData.new({backend_id = 'reference-graph-v1', backend_version = '1',
    session_id = query.session_id .. ':recorded', config = graph.representation})
  if not data then return error_reply('recording-data:' .. data_error.code) end
  local data_ref, load_error = NavigationData.load_world(data, snapshot)
  if not data_ref then return error_reply('recording-world:' .. load_error.code) end
  query.data_ref, query.snapshot_id, query.query_id = data_ref, snapshot.snapshot_id, query.query_id .. ':recorded:' .. algorithm
  query.required_capabilities = {'directed-graph-v1', 'distance', 'finite-bounds'}
  query.start_node, query.goal_node = 'start', 'goal'
  query.query_hash = assert(Boundary.hash_query(query))
  local result = {protocol = Boundary.PROTOCOL, kind = 'solver-result', query_id = query.query_id,
    session_id = query.session_id, command_id = query.command_id, attempt_id = query.attempt_id,
    snapshot_id = query.snapshot_id, query_hash = query.query_hash, data_ref = copy(data_ref),
    outcome = candidate.outcome, points = points, objective = copy(query.objective),
    predicted = candidate.outcome == 'complete' and {distance = candidate.predicted_distance} or {},
    solver = {id = 'recorded-reference-playback', version = '1'}, coverage = copy(snapshot.coverage),
    metrics = {recorded_algorithm = algorithm, not_fresh_solver = true,
      source_save_sha256 = record.source_save_sha256, source_snapshot_hash = candidate.source_snapshot_hash,
      source_query_hash = candidate.source_query_hash}}
  result.coverage.scope = 'bounded-graph'
  local valid, validation_error = Boundary.validate_query(query)
  if not valid then return error_reply('recording-query:' .. validation_error.code) end
  valid, validation_error = Boundary.validate_result(result, query)
  if not valid then return error_reply('recording-result:' .. validation_error.code) end
  s.algorithm, s.pass, s.plan_started_tick = algorithm, 'recorded', game.tick
  s.reference_playback = true
  s.reference_provenance = {source_facts_hash = record.source_facts_hash,
    source_save_sha256 = record.source_save_sha256, source_snapshot_hash = candidate.source_snapshot_hash,
    source_query_hash = candidate.source_query_hash, not_fresh_solver = true}
  s.capture = {protocol = Runtime.PROTOCOL, kind = 'comparison-work', id = s.case.id,
    source_facts_hash = s.source_facts_hash, snapshot = snapshot, query = query}
  s.execution_query, s.execution_snapshot, s.solver_result = query, snapshot, result
  local values = profile('recorded:admission', function()
    local run, progress = PlanningRun.start({schema_version = 1, profile_id = Replay.PROFILE_ID, values = {}}, {
      id = query.query_id, command_id = query.command_id, adapter_id = 'unified-lab-recorded-playback-v1',
      reason = 'recorded-reference-playback-not-fresh-solver', start_position = query.start,
      goal_position = query.goal, navigation_query = query
    }, {surface = s.surface, actor = s.actor, tick = game.tick, solver_result = result,
      navigation_data_ref = data_ref, navigation_snapshot = snapshot})
    return {run = run, result = progress}
  end)
  if not values.run or not values.result then return fail(s, 'recording-planning-start-failed') end
  s.planning_run = values.run
  planned(s, values.result)
  return status()
end

execute = function(s)
  if s.phase ~= 'planned' then return error_reply('execute-requires-terminal-plan') end
  local valid, reason = verify_source(s)
  if not valid then return error_reply(reason) end
  if s.planning_result.status == 'no-path' then finish(s, 'no-path', s.planning_result.reason); return status() end
  if s.planning_result.status ~= 'success' then
    finish(s, 'rejected', s.planning_result.reason or s.planning_result.status); return status()
  end
  s.session = {surface = s.surface, actor = s.actor, case_id = s.case.id,
    snapshot = s.execution_snapshot, query = s.execution_query,
    result = s.solver_result or {points = s.plans[#s.plans].raw_path or {}},
    status = 'prepared', started_tick = game.tick, max_ticks = 3600,
    actual_distance = 0, direction_switches = 0, max_cross_track_error = 0,
    last_position = point(s.actor.position)}
  Replay.activate(s.session, s.planning_run, s.planning_result)
  if s.session.status ~= 'moving' then finish(s, s.session.status, s.session.reason); return status() end
  s.phase, s.last_update_tick = 'moving', game.tick
  profile('execution_arm', function() return Replay.update(s.session, game.tick) end)
  if s.session.status == 'moving' then game.speed, game.tick_paused = 1, false
  else finish(s, s.session.status, s.session.reason) end
  return status()
end

function Runtime.dispatch(message)
  if not enabled() then return error_reply('comparison-map-required') end
  if type(message) ~= 'table' or message.protocol ~= Runtime.PROTOCOL then return error_reply('unsupported-protocol') end
  local operation, s = message.operation, state()
  if operation == 'catalog' then return {ok = true, protocol = Runtime.PROTOCOL,
    fixture_version = Catalog.VERSION, case_count = #Fixtures.list(), cases = Catalog.describe()} end
  if operation == 'status' then return status() end
  if not s then return error_reply('runtime-not-initialized') end
  if operation == 'prepare' then return prepare(s, message.id) end
  if operation == 'clock' then return Clock.dispatch(message, s.actor) end
  if operation == 'pause' then game.tick_paused, game.ticks_to_run = true, 0; return status() end
  if operation == 'facts' then
    if not s.case then return error_reply('source-required') end
    local facts, detail = capture_facts(s)
    if not facts then return error_reply('facts:' .. detail.code) end
    local encoded = json(facts)
    helpers.write_file(FACTS_PATH, encoded, false, 0)
    return {ok = true, protocol = Runtime.PROTOCOL, path = FACTS_PATH, bytes = #encoded,
      facts_hash = facts.facts_hash, source_facts_hash = s.source_facts_hash}
  end
  if operation == 'save' then
    if s.phase ~= 'prepared' or not game.tick_paused or game.ticks_to_run ~= 0 then
      return error_reply('only-paused-prepared-source-may-be-published') end
    if type(message.name) ~= 'string' or #message.name > 128 or not message.name:match('^[%w][%w_-]*$') then
      return error_reply('invalid-save-name') end
    game.server_save(message.name)
    return {ok = true, protocol = Runtime.PROTOCOL, filename = message.name .. '.zip',
      case_id = s.case.id, source_facts_hash = s.source_facts_hash}
  end
  if not s.case then return error_reply('source-required') end
  if operation == 'capture' then return capture(s, message) end
  if operation == 'plan' then return begin_plan(s, message) end
  if operation == 'upload' then
    if s.phase ~= 'captured' and s.phase ~= 'planned' then return error_reply('upload-requires-captured-source') end
    local accepted, reason = Contract.upload(s, message)
    if not accepted then return error_reply(reason) end
    return {ok = true, protocol = Runtime.PROTOCOL, next_index = s.upload_next,
      bytes = s.upload_bytes, duplicate = reason == 'duplicate'}
  end
  if operation == 'commit' then return commit(s, message) end
  if operation == 'execute' then return execute(s) end
  return error_reply('unknown-operation')
end

function Runtime.on_init()
  if not enabled() then return end
  storage.scv_navigation_comparison = {phase = 'idle', schema_version = 1, plans = {}}
  game.tick_paused, game.ticks_to_run = true, 0
end
function Runtime.on_load() loaded_from_save = true end

function Runtime.add_commands()
  if not enabled() then return end
  commands.add_command('scv-compare-agent', 'Local source-save comparison protocol.', function(command)
    if command.player_index then game.get_player(command.player_index).print('Use /scv-compare plan | run | status.'); return end
    local input, response = command.parameter or ''
    if #input > 20000 then response = error_reply('command-byte-limit')
    else
      local decoded, message = pcall(helpers.json_to_table, input)
      if not decoded or type(message) ~= 'table' then response = error_reply('invalid-json')
      else local ok, result = pcall(Runtime.dispatch, message)
        response = ok and result or error_reply('handler-error:' .. tostring(result)) end
    end
    rcon.print(json(response))
  end)
  commands.add_command('scv-compare', 'Saved static map: plan | run | pause | status.', function(command)
    if not command.player_index then return end
    local operation, s, response = command.parameter or 'status', state()
    local function dispatch(op, values)
      values = values or {}; values.protocol, values.operation = Runtime.PROTOCOL, op
      return Runtime.dispatch(values)
    end
    local ok, value = pcall(function()
      if operation == 'plan' or operation == 'run' then
        if s.phase == 'prepared' then response = dispatch('capture'); if not response.ok then return response end end
        if s.phase == 'captured' then
          s.auto_execute = operation == 'run'
          return dispatch('plan', {algorithm = 'production-v1', pass = 'cold'})
        end
        if operation == 'run' and s.phase == 'planned' then return dispatch('execute') end
        return status()
      end
      if operation == 'pause' or operation == 'status' then return dispatch(operation) end
      return error_reply('Use /scv-compare plan | run | pause | status. Reload source ZIP to repeat.')
    end)
    game.get_player(command.player_index).print(json(ok and value or error_reply(tostring(value))))
  end)
end

local function tick(event)
  if not enabled() then return end
  local s = state()
  if not s then return end
  if s.phase == 'planning' then
    if not Contract.source_position(s.actor, s.actor_origin) then fail(s, 'actor-moved-during-planning')
    elseif event.tick - s.plan_started_tick > 3600 then fail(s, 'planning-tick-guard') end
    return
  end
  if s.phase ~= 'moving' or event.tick <= s.last_update_tick then return end
  s.last_update_tick = event.tick
  local ok, outcome = pcall(function() return profile('on_tick', function() return Replay.update(s.session, event.tick) end) end)
  if not ok then fail(s, 'native-update:' .. tostring(outcome))
  elseif outcome ~= 'moving' then finish(s, outcome, s.session.reason) end
end
local function path_result(event)
  if not enabled() then return end
  local s = state()
  if not s or s.phase ~= 'planning' or not s.planning_run
    or event.id ~= s.planning_run.pending_request_id then return end
  local ok, result = pcall(function()
    return profile(s.pass .. ':path_result', function()
      return PlanningRun.handle_result(s.planning_run, event, {surface = s.surface, actor = s.actor, tick = game.tick})
    end)
  end)
  if not ok then fail(s, 'path-result:' .. tostring(result)) else planned(s, result) end
end
Runtime.events = {
  [defines.events.on_tick] = tick,
  [defines.events.on_script_path_request_finished] = path_result,
  [defines.events.on_player_created] = function(event) if enabled() then watch(game.get_player(event.player_index)) end end,
  [defines.events.on_player_joined_game] = function(event) if enabled() then watch(game.get_player(event.player_index)) end end
}
Runtime.active = enabled
return Runtime
