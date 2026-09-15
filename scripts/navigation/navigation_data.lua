local Canonical = require("__factorio-scv-control__/scripts/navigation/canonical")
local Serializable = require("__factorio-scv-control__/scripts/navigation/serializable")
local Boundary = require("__factorio-scv-control__/scripts/navigation/solver_boundary")

-- A bounded, serializable store of committed input generations. This is a
-- lifecycle implementation for captured data; it does not bake navigation meshes.
-- Public snapshots/refs are copies. Only these module functions mutate the store.
local NavigationData = {}

local function err(code, message, path)
  return {code = code, message = message, path = path or "$", kind = "navigation-data-error"}
end

local function failed(code, message, path)
  return nil, err(code, message, path)
end

local function outcome(status, reason, details)
  local result = details or {}
  result.status, result.reason = status, reason
  return result
end

local function copy(value)
  return Serializable.copy(value)
end

local function text(value)
  return type(value) == "string" and #value > 0
end

local function integer(value)
  return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

local function usable(state)
  if type(state) ~= "table" or state.schema ~= "scv-navigation-data/1" then
    return failed("invalid-state", "Expected a NavigationData state.")
  end
  if state.closed then return failed("closed-world", "This backend incarnation has been closed.") end
  return true
end

local function collect(state)
  for id, generation in pairs(state.generations) do
    if id ~= state.current_generation and generation.pins == 0 then
      state.generations[id] = nil
    end
  end
end

local function has_capacity(state)
  local retained = 0
  for _, generation in pairs(state.generations) do
    if generation.pins > 0 then retained = retained + 1 end
  end
  return retained < state.limits.max_generations
end

local function reference(state, snapshot, id)
  local snapshot_hash, hash_error = Canonical.hash(snapshot)
  if not snapshot_hash then return nil, hash_error end
  local actor_hash, actor_error = Canonical.hash(snapshot.actor)
  if not actor_hash then return nil, actor_error end
  return {
    backend_id = state.backend_id,
    backend_version = state.backend_version,
    generation_id = id,
    snapshot_id = snapshot.snapshot_id,
    snapshot_hash = snapshot_hash,
    config_hash = state.config_hash,
    actor_hash = actor_hash,
    revisions = copy(snapshot.revisions)
  }
end

local function matching_generation(state, ref)
  local ok, state_error = usable(state)
  if not ok then return nil, state_error end
  local valid, validation_error = Boundary.validate_data_ref(ref)
  if not valid then return nil, validation_error end
  local generation = state.generations[ref.generation_id]
  if not generation then return failed("stale-generation", "The committed generation is unavailable.") end
  local encoded, encode_error = Canonical.encode(ref)
  if not encoded then return nil, encode_error end
  if encoded ~= generation.ref_encoding then
    return failed("data-reference-mismatch", "Every NavigationDataRef field must match its committed generation.")
  end
  return generation
end

function NavigationData.new(options)
  if type(options) ~= "table" or not text(options.backend_id)
      or not text(options.backend_version) or not text(options.session_id) then
    return failed("invalid-options", "backend_id, backend_version and session_id must be nonempty strings.")
  end
  local config_hash, config_error = Canonical.hash(options.config or {})
  if not config_hash then return nil, config_error end
  local limits = options.limits or {}
  if type(limits) ~= "table" then return failed("invalid-limits", "Limits must be a table.") end
  limits = {
    max_generations = limits.max_generations or 16,
    max_delta_history = limits.max_delta_history or 128,
    max_history_bytes = limits.max_history_bytes or 8 * 1024 * 1024
  }
  for key, value in pairs(limits) do
    if not integer(value) or value < 1 then
      return failed("invalid-limits", "Storage limits must be positive finite integers.", "$.limits." .. key)
    end
  end
  return {
    schema = "scv-navigation-data/1",
    backend_id = options.backend_id,
    backend_version = options.backend_version,
    session_id = options.session_id,
    config = copy(options.config or {}),
    config_hash = config_hash,
    limits = limits,
    next_generation = 1,
    sequence = 0,
    generations = {},
    history = {},
    history_order = {},
    history_bytes = 0,
    closed = false
  }
end

local function install(state, snapshot, ref)
  state.generations[ref.generation_id] = {
    snapshot = snapshot,
    ref = ref,
    ref_encoding = Canonical.encode(ref),
    pins = 1
  }
  state.current_generation = ref.generation_id
  state.next_generation = state.next_generation + 1
  state.world_id, state.surface_id = snapshot.world_id, snapshot.surface_id
  collect(state)
  return copy(ref)
end

-- A load is an atomic full resynchronization. Its returned reference owns one pin.
-- The world/surface cannot change within this backend session; create another
-- state with a new session_id when a save/surface incarnation changes.
function NavigationData.load_world(state, snapshot)
  local ok, state_error = usable(state)
  if not ok then return nil, state_error end
  if state.pending then return failed("update-pending", "Commit or abort the staged update before loading a world.") end
  -- Bound nesting/size before the structural schema validator walks the input.
  local encoded, encode_error = Canonical.encode(snapshot)
  if not encoded then return nil, encode_error end
  local valid, validation_error = Boundary.validate_snapshot(snapshot)
  if not valid then return nil, validation_error end
  if state.world_id and (snapshot.world_id ~= state.world_id or snapshot.surface_id ~= state.surface_id) then
    return failed("world-incarnation-mismatch", "A backend session cannot switch world or surface identity.")
  end
  if not has_capacity(state) then return failed("generation-limit", "Release pinned generations before loading another.") end
  local id = state.session_id .. ":g" .. state.next_generation
  local ref, reference_error = reference(state, snapshot, id)
  if not ref then return nil, reference_error end
  local result = install(state, copy(snapshot), ref)
  state.sequence, state.history, state.history_order, state.history_bytes = 0, {}, {}, 0
  return result
end

function NavigationData.current(state)
  local ok, state_error = usable(state)
  if not ok then return nil, state_error end
  local generation = state.generations[state.current_generation]
  if not generation then return failed("world-not-loaded", "Load a snapshot before requesting navigation data.") end
  return copy(generation.ref)
end

function NavigationData.resolve(state, ref)
  local generation, resolve_error = matching_generation(state, ref)
  if not generation then return nil, resolve_error end
  return copy(generation.snapshot)
end

function NavigationData.acquire(state, ref)
  if ref == nil then
    local current, current_error = NavigationData.current(state)
    if not current then return nil, current_error end
    ref = current
  end
  local generation, resolve_error = matching_generation(state, ref)
  if not generation then return nil, resolve_error end
  generation.pins = generation.pins + 1
  return copy(generation.ref)
end

function NavigationData.release(state, ref)
  local generation, resolve_error = matching_generation(state, ref)
  if not generation then return nil, resolve_error end
  if generation.pins == 0 then return failed("unbalanced-release", "The generation has no acquired pins.") end
  generation.pins = generation.pins - 1
  collect(state)
  return true
end

local function array(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
  end
  return count == #value
end

local function patch_entries(entries, changes, path)
  if changes == nil then return copy(entries) end
  if type(changes) ~= "table" or not array(changes.upsert or {}) or not array(changes.remove or {}) then
    return failed("invalid-delta-entries", "Upserts and removals must be arrays.", path)
  end
  for key in pairs(changes) do
    if key ~= "upsert" and key ~= "remove" then
      return failed("unknown-delta-field", "Entry changes accept only upsert and remove.", path .. "." .. tostring(key))
    end
  end
  local by_id, touched = {}, {}
  for _, item in ipairs(entries) do by_id[item.id] = copy(item) end
  for _, id in ipairs(changes.remove or {}) do
    if not text(id) or touched[id] then
      return failed("duplicate-delta-entry", "Each entity/tile ID may be changed only once per delta.", path)
    end
    if not by_id[id] then return failed("unknown-removal", "A removal must identify an existing entry.", path) end
    touched[id], by_id[id] = true, nil
  end
  for _, item in ipairs(changes.upsert or {}) do
    if type(item) ~= "table" or not text(item.id) or touched[item.id] then
      return failed("duplicate-delta-entry", "Each entity/tile upsert requires a unique ID.", path)
    end
    touched[item.id], by_id[item.id] = true, copy(item)
  end
  local ids, result = {}, {}
  for id in pairs(by_id) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do result[#result + 1] = by_id[id] end
  return result
end

local function valid_bounds(bounds)
  if type(bounds) ~= "table" or type(bounds.left_top) ~= "table" or type(bounds.right_bottom) ~= "table" then
    return false
  end
  for _, position in ipairs({bounds.left_top, bounds.right_bottom}) do
    for _, key in ipairs({"x", "y"}) do
      local value = position[key]
      if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return false end
    end
  end
  return bounds.left_top.x < bounds.right_bottom.x and bounds.left_top.y < bounds.right_bottom.y
end

-- Receipt/staging never changes the current queryable generation. Only one update
-- may be staged. Deltas use monotonic sequence numbers relative to the last load.
function NavigationData.begin_update(state, delta)
  local ok, state_error = usable(state)
  if not ok then return outcome("error", state_error.code, {error = state_error}) end
  local encoded, encode_error = Canonical.encode(delta)
  if not encoded then return outcome("error", encode_error.code, {error = encode_error}) end
  if type(delta) ~= "table" or delta.protocol ~= "scv-navigation/1" or delta.kind ~= "world-delta"
      or not text(delta.delta_id) or not text(delta.base_generation) or not text(delta.snapshot_id)
      or not integer(delta.sequence) or delta.sequence < 1 or not integer(delta.captured_tick)
      or type(delta.revisions) ~= "table" or not integer(delta.revisions.topology)
      or not integer(delta.revisions.motion) or not valid_bounds(delta.dirty_bounds) then
    return outcome("error", "invalid-delta", {error = err("invalid-delta", "Delta identity, sequence, bounds or revisions are malformed.")})
  end
  local accepted_fields = {protocol = true, kind = true, delta_id = true, base_generation = true,
    snapshot_id = true, sequence = true, captured_tick = true, revisions = true,
    dirty_bounds = true, entities = true, tiles = true, graph = true}
  for key in pairs(delta) do
    if not accepted_fields[key] then
      return outcome("error", "unknown-delta-field", {error = err("unknown-delta-field", "Unsupported delta field.", "$[" .. tostring(key) .. "]")})
    end
  end
  if #encoded > state.limits.max_history_bytes then return outcome("error", "delta-history-size-limit") end
  local previous = state.history[delta.delta_id]
  if previous then
    if previous.encoded ~= encoded then return outcome("error", "conflicting-delta") end
    local generation = state.generations[previous.generation_id]
    return generation and outcome("duplicate", "already-committed", {ref = copy(generation.ref)})
      or outcome("resync-required", "duplicate-generation-released")
  end
  if state.pending then
    if state.pending.delta_id == delta.delta_id then
      if state.pending.encoded ~= encoded then return outcome("error", "conflicting-delta") end
      return outcome("duplicate", "already-staged", {stage_id = state.pending.stage_id})
    end
    return outcome("error", "update-pending")
  end
  if delta.base_generation ~= state.current_generation then return outcome("resync-required", "stale-base") end
  if delta.sequence ~= state.sequence + 1 then return outcome("resync-required", "out-of-order-sequence") end
  local current = state.generations[state.current_generation]
  if not current then return outcome("resync-required", "world-not-loaded") end
  for _, generation in pairs(state.generations) do
    if delta.snapshot_id == generation.snapshot.snapshot_id then return outcome("error", "snapshot-id-reused") end
  end
  if delta.captured_tick < current.snapshot.captured_tick
      or delta.revisions.topology < current.snapshot.revisions.topology
      or delta.revisions.motion < current.snapshot.revisions.motion then
    return outcome("resync-required", "revision-regression")
  end
  local coverage = current.snapshot.coverage.bounds
  if delta.dirty_bounds.left_top.x < coverage.left_top.x or delta.dirty_bounds.left_top.y < coverage.left_top.y
      or delta.dirty_bounds.right_bottom.x > coverage.right_bottom.x
      or delta.dirty_bounds.right_bottom.y > coverage.right_bottom.y then
    return outcome("resync-required", "dirty-bounds-outside-coverage")
  end
  local snapshot = copy(current.snapshot)
  local entities, entity_error = patch_entries(snapshot.geometry.entities, delta.entities, "$.entities")
  if not entities then return outcome("error", entity_error.code, {error = entity_error}) end
  local tiles, tile_error = patch_entries(snapshot.geometry.tiles, delta.tiles, "$.tiles")
  if not tiles then return outcome("error", tile_error.code, {error = tile_error}) end
  snapshot.geometry.entities, snapshot.geometry.tiles = entities, tiles
  snapshot.snapshot_id, snapshot.captured_tick = delta.snapshot_id, delta.captured_tick
  snapshot.revisions = copy(delta.revisions)
  -- A graph is a derived representation. Never retain old edges/weights across an
  -- update unless the producer explicitly supplies the rebuilt replacement.
  snapshot.graph = delta.graph and copy(delta.graph) or nil
  if delta.revisions.topology == current.snapshot.revisions.topology
      and delta.revisions.motion == current.snapshot.revisions.motion
      and (Canonical.encode(snapshot.geometry) ~= Canonical.encode(current.snapshot.geometry)
        or Canonical.encode(snapshot.graph) ~= Canonical.encode(current.snapshot.graph)) then
    return outcome("error", "changed-data-without-revision")
  end
  local valid, validation_error = Boundary.validate_snapshot(snapshot)
  if not valid then return outcome("error", validation_error.code, {error = validation_error}) end
  if not has_capacity(state) then return outcome("error", "generation-limit") end
  local stage_id = state.session_id .. ":g" .. state.next_generation
  local ref, reference_error = reference(state, snapshot, stage_id)
  if not ref then return outcome("error", reference_error.code, {error = reference_error}) end
  state.pending = {stage_id = stage_id, snapshot = snapshot, ref = ref, delta_id = delta.delta_id,
    sequence = delta.sequence, encoded = encoded, base_generation = delta.base_generation}
  return outcome("staged", nil, {stage_id = stage_id})
end

function NavigationData.commit(state, stage_id)
  local ok, state_error = usable(state)
  if not ok then return outcome("error", state_error.code, {error = state_error}) end
  local pending = state.pending
  if not pending or pending.stage_id ~= stage_id then return outcome("error", "unknown-stage") end
  if pending.base_generation ~= state.current_generation then return outcome("resync-required", "stale-base") end
  if not has_capacity(state) then return outcome("error", "generation-limit") end
  local ref = install(state, pending.snapshot, pending.ref)
  state.sequence = pending.sequence
  state.history[pending.delta_id] = {encoded = pending.encoded, generation_id = ref.generation_id}
  state.history_order[#state.history_order + 1] = pending.delta_id
  state.history_bytes = state.history_bytes + #pending.encoded
  while #state.history_order > state.limits.max_delta_history or state.history_bytes > state.limits.max_history_bytes do
    local oldest_id = table.remove(state.history_order, 1)
    state.history_bytes = state.history_bytes - #state.history[oldest_id].encoded
    state.history[oldest_id] = nil
  end
  state.pending = nil
  return outcome("committed", nil, {ref = ref})
end

function NavigationData.abort(state, stage_id)
  local ok, state_error = usable(state)
  if not ok then return nil, state_error end
  if not state.pending or state.pending.stage_id ~= stage_id then return failed("unknown-stage", "No such staged update exists.") end
  state.pending = nil
  return true
end

function NavigationData.close_world(state)
  local ok, state_error = usable(state)
  if not ok then return nil, state_error end
  state.closed, state.pending, state.current_generation = true, nil, nil
  state.generations, state.history, state.history_order, state.history_bytes = {}, {}, {}, 0
  return true
end

return NavigationData
