local Canonical = require("__factorio-scv-control__/scripts/navigation/canonical")
local NavigationData = require("__factorio-scv-control__/scripts/navigation/navigation_data")
local Serializable = require("__factorio-scv-control__/scripts/navigation/serializable")
local WireJson = require("__factorio-scv-control__/scripts/navigation/wire_json")

local Tests = {}

local function copy(value) return Serializable.copy(value) end

local function fixture()
  return {
    protocol = "scv-navigation/1", kind = "world-snapshot", snapshot_id = "data-test:0",
    world_id = "data-test-world", surface_id = "surface:1", captured_tick = 10,
    actor = {name = "character", force = "player", collision_box = {
      left_top = {x = -0.2, y = -0.2}, right_bottom = {x = 0.2, y = 0.2}}},
    revisions = {topology = 0, motion = 0},
    coverage = {bounds = {left_top = {x = -8, y = -8}, right_bottom = {x = 8, y = 8}}, unknown = "blocked"},
    geometry = {entities = {{id = "wall:1", name = "stone-wall", position = {x = 2, y = 2}}}, tiles = {}},
    graph = {nodes = {{id = "a", position = {x = 0, y = 0}}, {id = "b", position = {x = 4, y = 0}}},
      edges = {{from = "a", to = "b", distance = 4, travel_ticks = 28}}}
  }
end

local function store(overrides)
  local options = {backend_id = "captured-graph-v1", backend_version = "1", session_id = "session:data-test",
    config = {step = 0.5}}
  for key, value in pairs(overrides or {}) do options[key] = value end
  return NavigationData.new(options)
end

local function delta(ref, sequence)
  return {
    protocol = "scv-navigation/1", kind = "world-delta", delta_id = "delta:" .. sequence,
    base_generation = ref.generation_id, snapshot_id = "data-test:" .. sequence,
    sequence = sequence, captured_tick = 10 + sequence,
    revisions = {topology = sequence, motion = 0},
    dirty_bounds = {left_top = {x = 1, y = 1}, right_bottom = {x = 4, y = 4}},
    entities = {upsert = {{id = "wall:2", name = "stone-wall", position = {x = 3, y = 2}}}, remove = {"wall:1"}}
  }
end

function Tests.run(expect)
  local vectors = {
    {value = {}, encoded = "e;", hash = "scv-c14n1-adler32:010700a1:2"},
    {value = 0, encoded = "n0p0;", hash = "scv-c14n1-adler32:04d6017a:5"},
    {value = -0.0, encoded = "n0p0;", hash = "scv-c14n1-adler32:04d6017a:5"},
    {value = 1.5, encoded = "n3p-1;", hash = "scv-c14n1-adler32:067d01ab:6"},
    {value = 0.1, encoded = "n3602879701896397p-55;", hash = "scv-c14n1-adler32:3a630506:22"},
    {value = 5e-324, encoded = "n1p-1074;", hash = "scv-c14n1-adler32:0c8a0244:9"},
    {value = 0.15 * 1.5, encoded = "n2026619832316723p-53;", hash = "scv-c14n1-adler32:394f04ec:22"},
    {value = 0.225, encoded = "n8106479329266893p-55;", hash = "scv-c14n1-adler32:3a5e0504:22"},
    {value = 9007199254740991, encoded = "n9007199254740991p0;", hash = "scv-c14n1-adler32:30710496:20"},
    {value = {z = false, a = {1.5, {}, "门"}}, encoded = "o2:s1:aa3:n3p-1;e;s3:门s1:zb0;",
      hash = "scv-c14n1-adler32:9dcd0a60:31"}
  }
  local vector_failures = {}
  for index, vector in ipairs(vectors) do
    local encoded, encode_error = Canonical.encode(vector.value)
    local hash = Canonical.hash(vector.value)
    if encoded ~= vector.encoded or hash ~= vector.hash then
      vector_failures[#vector_failures + 1] = {index = index, actual_encoding = encoded,
        actual_hash = hash, error = encode_error}
    end
  end
  expect("navigation_data.canonical_python_vectors", #vector_failures == 0, {failures = vector_failures})

  local repeated = {}
  for index = 1, 1024 do
    repeated[index] = {id = "cell:" .. index, distance = index % 2 == 0 and 0.5 or 0.1}
  end
  expect("navigation_data.canonical_large_array_block_checksum", Canonical.hash(repeated)
    == "scv-c14n1-adler32:bd569be8:44979", {hash = Canonical.hash(repeated)})

  local snapshot = fixture()
  local reordered = {}
  for _, key in ipairs({"graph", "geometry", "coverage", "revisions", "actor", "captured_tick",
      "surface_id", "world_id", "snapshot_id", "kind", "protocol"}) do reordered[key] = copy(snapshot[key]) end
  local json_round_trip = helpers.json_to_table(helpers.table_to_json(snapshot))
  expect("navigation_data.canonical_storage_and_json_round_trip",
    Canonical.hash(snapshot) == Canonical.hash(reordered)
      and Canonical.hash(snapshot) == Canonical.hash(copy(snapshot))
      and Canonical.hash(snapshot) == Canonical.hash(json_round_trip),
    {hash = Canonical.hash(snapshot), json_hash = Canonical.hash(json_round_trip)})

  -- Regression captured in fixture-v4: the actual actor runs at binary64
  -- 0.22499999999999998; helpers.table_to_json emitted 0.225 and changed its hash.
  -- Irregular graph connectors exercise additional nontrivial computed doubles.
  local precise_snapshot = fixture()
  precise_snapshot.actor.running_speed = 0.15 * 1.5
  precise_snapshot.graph.edges[1].distance = math.sqrt(0.7 * 0.7 + 3.9 * 3.9)
  precise_snapshot.graph.edges[1].travel_ticks = 1 / 0.15
  precise_snapshot.exporter = {note = '墙\\gate\n"quoted"\t' .. string.char(0, 1, 31)}
  local precise_json, precise_error = WireJson.encode(precise_snapshot)
  local precise_round_trip = precise_json and helpers.json_to_table(precise_json)
  local native_round_trip = helpers.json_to_table(helpers.table_to_json(precise_snapshot))
  expect("navigation_data.wire_json_preserves_real_actor_and_computed_graph_identity",
    precise_round_trip ~= nil and Canonical.hash(precise_snapshot) == Canonical.hash(precise_round_trip)
      and precise_round_trip.actor.running_speed == precise_snapshot.actor.running_speed
      and precise_round_trip.exporter.note == precise_snapshot.exporter.note,
    {error = precise_error, hash = Canonical.hash(precise_snapshot),
      precise_hash = precise_round_trip and Canonical.hash(precise_round_trip),
      engine_json_hash = Canonical.hash(native_round_trip),
      engine_json_loses_identity = Canonical.hash(native_round_trip) ~= Canonical.hash(precise_snapshot)})

  local invalid = {{[1] = 1, field = 2}, {[2] = "sparse"}, {value = math.huge}, {value = string.char(255)}}
  local cycle = {}; cycle.self = cycle; invalid[#invalid + 1] = cycle
  local all_rejected = true
  for _, item in ipairs(invalid) do
    local encoded, encode_error = Canonical.encode(item)
    local wire, wire_error = WireJson.encode(item)
    all_rejected = all_rejected and encoded == nil and type(encode_error) == "table"
      and wire == nil and type(wire_error) == "table"
  end
  expect("navigation_data.canonical_rejects_ambiguous_and_invalid_values", all_rejected, {})

  local state = store()
  local ref, load_error = NavigationData.load_world(state, snapshot)
  expect("navigation_data.load_commits_reference", ref ~= nil and ref.snapshot_hash == Canonical.hash(snapshot)
    and ref.actor_hash == Canonical.hash(snapshot.actor) and ref.config_hash == Canonical.hash({step = 0.5}),
    {ref = ref, error = load_error})
  if not ref then return end

  local resolved = NavigationData.resolve(state, ref)
  snapshot.geometry.entities[1].position.x = 999
  resolved.geometry.entities[1].position.x = 999
  local authoritative = NavigationData.resolve(state, ref)
  expect("navigation_data.committed_inputs_are_immutable_copies", authoritative.geometry.entities[1].position.x == 2,
    {position = authoritative.geometry.entities[1].position})

  local forged = copy(ref); forged.revisions.topology = 77
  local rejected, reference_error = NavigationData.resolve(state, forged)
  local other = store({session_id = "another-session"})
  local other_ref = NavigationData.load_world(other, fixture())
  local foreign, foreign_error = NavigationData.resolve(state, other_ref)
  expect("navigation_data.full_reference_and_session_are_correlated", rejected == nil
    and reference_error.code == "data-reference-mismatch" and foreign == nil and foreign_error.code == "stale-generation",
    {forged = reference_error, foreign = foreign_error})

  local before = Canonical.hash(state)
  local malformed = fixture(); malformed.coverage.bounds.left_top.x = math.huge
  local malformed_ref = NavigationData.load_world(state, malformed)
  local invalid_delta = delta(ref, 1); invalid_delta.entities = {upsert = {{id = "x"}, {id = "x"}}}
  local invalid_update = NavigationData.begin_update(state, invalid_delta)
  local mismatched = fixture(); mismatched.surface_id = "surface:2"
  local mismatch_ref, mismatch_error = NavigationData.load_world(state, mismatched)
  local unversioned_delta = delta(ref, 1); unversioned_delta.revisions.topology = 0
  local unversioned_result = NavigationData.begin_update(state, unversioned_delta)
  expect("navigation_data.rejected_inputs_do_not_mutate_store", malformed_ref == nil
    and invalid_update.status == "error" and mismatch_ref == nil
    and mismatch_error.code == "world-incarnation-mismatch"
    and unversioned_result.reason == "changed-data-without-revision" and before == Canonical.hash(state),
    {invalid_delta = invalid_update, mismatch = mismatch_error, unversioned = unversioned_result})

  local update = delta(ref, 1)
  local staging = NavigationData.begin_update(state, update)
  local still_current = NavigationData.current(state)
  local hidden_ref = copy(ref); hidden_ref.generation_id = staging.stage_id
  local hidden = NavigationData.resolve(state, hidden_ref)
  expect("navigation_data.staged_updates_are_not_queryable", staging.status == "staged"
    and still_current.generation_id == ref.generation_id and hidden == nil, {stage = staging})

  local duplicate = NavigationData.begin_update(state, copy(update))
  local conflict = copy(update); conflict.captured_tick = 20
  local conflicting = NavigationData.begin_update(state, conflict)
  expect("navigation_data.staged_duplicate_is_idempotent", duplicate.status == "duplicate"
    and duplicate.stage_id == staging.stage_id and conflicting.status == "error"
    and conflicting.reason == "conflicting-delta", {duplicate = duplicate, conflict = conflicting})

  -- Storage round-trip while work is staged must not expose it prematurely or
  -- require callbacks/metatables to complete the commit after load.
  state = copy(state)
  local committed = NavigationData.commit(state, staging.stage_id)
  local new_ref = committed.ref
  local old_snapshot = NavigationData.resolve(state, ref)
  local new_snapshot = new_ref and NavigationData.resolve(state, new_ref)
  expect("navigation_data.commit_publishes_without_mutating_pinned_generation", committed.status == "committed"
    and old_snapshot.geometry.entities[1].id == "wall:1"
    and new_snapshot.geometry.entities[1].id == "wall:2"
    and old_snapshot.graph ~= nil and new_snapshot.graph == nil,
    {commit = committed, old_snapshot_id = old_snapshot.snapshot_id,
      new_snapshot_id = new_snapshot and new_snapshot.snapshot_id})
  if not new_ref then return end

  duplicate = NavigationData.begin_update(state, copy(update))
  before = Canonical.hash(state)
  local stale = delta(ref, 2)
  local stale_result = NavigationData.begin_update(state, stale)
  local skipped = delta(new_ref, 3)
  local skipped_result = NavigationData.begin_update(state, skipped)
  expect("navigation_data_duplicate_commit_and_resync_outcomes", duplicate.status == "duplicate"
    and duplicate.ref.generation_id == new_ref.generation_id
    and stale_result.status == "resync-required" and stale_result.reason == "stale-base"
    and skipped_result.status == "resync-required" and skipped_result.reason == "out-of-order-sequence"
    and before == Canonical.hash(state), {stale = stale_result, skipped = skipped_result})

  local retained = NavigationData.acquire(state, ref)
  NavigationData.release(state, ref)
  local once_pinned = NavigationData.resolve(state, retained)
  NavigationData.release(state, retained)
  local released, released_error = NavigationData.resolve(state, ref)
  expect("navigation_data.release_reclaims_only_unpinned_old_generations", once_pinned ~= nil and released == nil
    and released_error.code == "stale-generation" and NavigationData.resolve(state, new_ref) ~= nil,
    {released = released_error})

  local next_update = delta(new_ref, 2)
  next_update.entities = {upsert = {}, remove = {}}
  next_update.graph = fixture().graph
  local next_stage = NavigationData.begin_update(state, next_update)
  local aborted = NavigationData.abort(state, next_stage.stage_id)
  expect("navigation_data.abort_keeps_committed_generation", next_stage.status == "staged" and aborted
    and NavigationData.current(state).generation_id == new_ref.generation_id,
    {stage = next_stage})

  local limited = store({limits = {max_generations = 1}})
  local limited_ref = NavigationData.load_world(limited, fixture())
  local limited_result = NavigationData.begin_update(limited, delta(limited_ref, 1))
  NavigationData.release(limited, limited_ref)
  local available = NavigationData.begin_update(limited, delta(limited_ref, 1))
  expect("navigation_data.pin_budget_is_explicit_and_recoverable", limited_result.status == "error"
    and limited_result.reason == "generation-limit" and available.status == "staged",
    {limited = limited_result, available = available})

  local closed = NavigationData.close_world(state)
  local after_close, closed_error = NavigationData.resolve(state, new_ref)
  expect("navigation_data.close_invalidates_all_references", closed == true and after_close == nil
    and closed_error.code == "closed-world" and Serializable.validate(state), {error = closed_error})
end

return Tests
