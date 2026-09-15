local Capture = require("__scv-control-testkit__/interchange/capture")
local Replay = require("__scv-control-testkit__/interchange/replay")
local Fixtures = require("__scv-control-testkit__/pathfinding/fixtures")
local Imports = require("__scv-control-testkit__/interchange/imported_plans")
local Canonical = require("__factorio-scv-control__/scripts/navigation/canonical")
local WireJson = require("__factorio-scv-control__/scripts/navigation/wire_json")
local Boundary = require("__factorio-scv-control__/scripts/navigation/solver_boundary")
local PathMath = require("__factorio-scv-control__/scripts/path_math")
local Follower = require("__factorio-scv-control__/scripts/follower")

local Tests = {}
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

local function known_result(case, points)
  local query = case.query
  return {
    protocol = "scv-navigation/1", kind = "solver-result",
    query_id = query.query_id, query_hash = query.query_hash,
    session_id = query.session_id, command_id = query.command_id, attempt_id = query.attempt_id,
    snapshot_id = query.snapshot_id, data_ref = copy(query.data_ref), outcome = "complete",
    solver = {id = "known-route-test", version = "1"}, objective = copy(query.objective),
    coverage = copy(case.snapshot.coverage), points = copy(points),
    predicted = {distance = PathMath.polyline_distance(query.start, points)}, metrics = {}
  }
end

local function first_difference(first, second, path)
  if type(first) ~= type(second) then return {path = path, expected_type = type(first), actual_type = type(second)} end
  if type(first) ~= "table" then
    if first ~= second then return {path = path, expected = first, actual = second,
      expected_canonical = Canonical.encode(first), actual_canonical = Canonical.encode(second)} end
    return nil
  end
  for key, value in pairs(first) do
    local difference = first_difference(value, second[key], path .. "." .. tostring(key))
    if difference then return difference end
  end
  for key in pairs(second) do if first[key] == nil then return {path = path .. "." .. tostring(key), unexpected = true} end end
end

function Tests.start(expect)
  local encoded_cases, errors, by_id = {}, {}, {}
  local captured, roundtrip, all_bound, mismatch = 0, true, true, nil
  -- Bound peak memory and encoding work to one fixture. Retain source data only
  -- for the three cases used below; the bundle output keeps every full snapshot.
  for _, fixture in ipairs(Fixtures.list()) do
    local snapshot, query = Capture.fixture(fixture.id)
    if not snapshot then errors[#errors + 1] = {id = fixture.id, error = query}
    else
      captured = captured + 1
      local case = {id = fixture.id, snapshot = snapshot, query = query}
      local encoded_case = assert(WireJson.encode(case))
      encoded_cases[#encoded_cases + 1] = encoded_case
      local decoded = helpers.json_to_table(encoded_case)
      local second = Canonical.hash(decoded.snapshot)
      local matches = query.data_ref.snapshot_hash == second
        and Boundary.hash_query(query) == Boundary.hash_query(decoded.query)
      roundtrip = roundtrip and matches
      if not matches and not mismatch then
        mismatch = first_difference(snapshot, decoded.snapshot, fixture.id)
          or {expected = query.data_ref.snapshot_hash, actual = second}
      end
      all_bound = all_bound and query.query_hash == Boundary.hash_query(query)
        and snapshot.graph.nodes[#snapshot.graph.nodes].id == "goal"
      if fixture.id == "open-diagonal" or fixture.id == "long-wall-return"
          or fixture.id == "tight-clearance-corridor" then by_id[fixture.id] = case end
      log("SCV_INTERCHANGE_CASE_ENCODED " .. fixture.id)
    end
  end
  local encoded = '{"protocol":"scv-navigation/1","kind":"capture-bundle","cases":['
    .. table.concat(encoded_cases, ",") .. '],"errors":' .. assert(WireJson.encode(errors)) .. '}'
  local artifact, artifact_error = Capture.write(nil, nil, nil, encoded)
  log("SCV_INTERCHANGE_WRITE_COMPLETE")
  expect("interchange.capture-artifact-written", artifact ~= nil, artifact_error)
  expect("interchange.fixture-v4-export", captured == 11 and #errors == 0, {captured = captured, errors = errors})
  expect("interchange.json-hash-roundtrip", roundtrip, mismatch)
  local tight = by_id["tight-clearance-corridor"]
  expect("interchange.tight-original-geometry", tight ~= nil and #tight.snapshot.geometry.entities == 34
    and tight.query.start.x == 9.9296875 and tight.query.start.y == -9.87890625
    and tight.query.goal.y == 9.8671875 and #tight.snapshot.fixture.original_walls == 2)
  expect("interchange.pinned-source-and-exact-endpoints", all_bound)
  local open = by_id["open-diagonal"]
  expect("interchange.execution-bound-is-production-policy", open ~= nil
    and open.query.execution.arrival_tolerance == Follower.tolerance({character_running_speed = open.snapshot.actor.running_speed})
    and open.query.goal_tolerance == PathMath.ARRIVAL_DISTANCE)
  local surface = Capture.ensure_surface("scv-interchange-domain-tests")
  local test_tiles = {}
  for x = -4, 7 do for y = -4, 3 do test_tiles[#test_tiles + 1] = {name = "refined-concrete", position = {x, y}} end end
  surface.set_tiles(test_tiles, true, false, false, false)
  local actor = surface.create_entity({name = "character", position = {0, 0}, force = "player"})
  local gate = surface.create_entity({name = "gate", position = {3, 0}, force = "player"})
  local unsupported, unsupported_error = Capture.live(surface, actor, {x = 0, y = 0}, {x = 6, y = 0}, {{-4, -4}, {8, 4}})
  expect("interchange.actual-gate-not-silently-flattened", unsupported == nil
    and unsupported_error and unsupported_error.code == "unsupported-world-semantics")
  if gate then gate.destroy() end
  if actor then actor.destroy() end

  local blocked = copy(by_id["long-wall-return"])
  if blocked then
    blocked.result = known_result(blocked, {blocked.query.start, blocked.query.goal})
    local session, prepare_error = Replay.prepare(blocked)
    if session then Replay.start(session) end
    expect("interchange.import-cannot-bypass-live-wall-validation", session ~= nil and session.status == "rejected",
      {error = prepare_error, planning = session and session.planning_result})
  end
  local straight = copy(by_id["open-diagonal"])
  if not straight then
    storage.scv_interchange_tests = {done = true, reports = {}}
    return true
  end
  straight.id = "known-open-diagonal"
  straight.result = known_result(straight, {straight.query.start, straight.query.goal})
  local loose = copy(straight)
  loose.query.execution.arrival_tolerance = loose.query.execution.arrival_tolerance + 1
  loose.query.query_hash = assert(Boundary.hash_query(loose.query))
  loose.result.query_hash = loose.query.query_hash
  local loose_session = Replay.prepare(loose)
  if loose_session then Replay.start(loose_session) end
  expect("interchange.import-cannot-loosen-execution-bound", loose_session ~= nil
    and loose_session.status == "rejected" and loose_session.reason == "execution-contract-mismatch")
  local stale = copy(straight)
  stale.result.attempt_id = "obsolete-attempt"
  local stale_session, stale_error = Replay.prepare(stale)
  if stale_session then Replay.start(stale_session) end
  expect("interchange.stale-attempt-rejected", stale_session ~= nil and stale_session.status == "rejected",
    {error = stale_error, planning = stale_session and stale_session.planning_result})
  local cases = {straight}
  for _, case in ipairs(Imports.cases) do
    if case.snapshot.fixture then
      local expected = case.snapshot.fixture.expected_path and "complete" or "no-path"
      expect("interchange.solver-outcome-" .. case.id, case.result.outcome == expected,
        {expected = expected, actual = case.result.outcome})
    end
    cases[#cases + 1] = case
  end
  storage.scv_interchange_tests = {cases = cases, next_case = 1, reports = {}, done = false}
  return false
end

function Tests.on_tick(expect, tick)
  local suite = storage.scv_interchange_tests
  if not suite or suite.done then return true end
  if not suite.active then
    local case = suite.cases[suite.next_case]
    if not case then
      suite.done = true
      helpers.write_file("scv-control/navigation/replay-results.json", helpers.table_to_json({
        protocol = "scv-navigation/1", kind = "replay-report", cases = suite.reports
      }), false, 0)
      return true
    end
    local session, prepare_error = Replay.prepare(case)
    if not session then
      expect("interchange.replay-" .. case.id, false, prepare_error)
      suite.next_case = suite.next_case + 1
      return false
    end
    suite.active = Replay.start(session)
  end
  local session = suite.active
  Replay.update(session, tick)
  if session.status == "moving" then return false end
  local expected = session.result.outcome == "complete" and "arrived" or "rejected"
  local report = Replay.report(session)
  expect("interchange.replay-" .. session.case_id, session.status == expected, {
    outcome = session.status, expected = expected, reason = session.reason,
    actual_travel_ticks = session.actual_travel_ticks, arrival_error = session.arrival_error,
    query_hash = session.query.query_hash
  })
  suite.reports[#suite.reports + 1] = report
  suite.active, suite.next_case = nil, suite.next_case + 1
  return false
end

return Tests
