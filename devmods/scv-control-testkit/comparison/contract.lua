-- The wire may replace a derived graph, never the native source or command.
local Boundary = require("__factorio-scv-control__/scripts/navigation/solver_boundary")
local Canonical = require("__factorio-scv-control__/scripts/navigation/canonical")
local Serializable = require("__factorio-scv-control__/scripts/navigation/serializable")

local Contract = {PROTOCOL = "scv-compare/1", CHUNK_BYTES = 3000, MAX_UPLOAD_BYTES = 1024 * 1024}
local POLYGON_BACKEND = 'extremity-source-polygons-v1'
Contract.ALGORITHMS = {['production-v1'] = true, ['grid-astar'] = true,
  ['grid-dijkstra'] = true, ['source-polygons'] = true}
local function copy(value) return assert(Serializable.copy(value)) end
local function equal(a, b) return Canonical.encode(a) == Canonical.encode(b) end
local function failure(reason) return nil, reason end
local function only(value, keys)
  if type(value) ~= 'table' then return false end
  for key in pairs(value) do if not keys[key] then return false end end
  return true
end
local function unchanged(source, derived, mutable)
  for key, value in pairs(source) do
    if not mutable[key] and not equal(value, derived[key]) then return false end
  end
  for key in pairs(derived) do if source[key] == nil and not mutable[key] then return false end end
  return true
end

function Contract.source_position(actor, origin)
  return actor and actor.valid and actor.position.x == origin.x and actor.position.y == origin.y
end

function Contract.upload(state, message)
  if type(message.index) ~= 'number' or message.index % 1 ~= 0 or message.index < 1
    or type(message.text) ~= 'string' or #message.text < 1 or #message.text > Contract.CHUNK_BYTES then
    return failure('invalid-upload-chunk')
  end
  if message.reset then
    if message.index ~= 1 then return failure('reset-requires-first-chunk') end
    state.upload, state.upload_bytes, state.upload_next = {}, 0, 1
  end
  if not state.upload then return failure('upload-reset-required') end
  if message.index < state.upload_next then
    if state.upload[message.index] == message.text then return true, 'duplicate' end
    return failure('conflicting-upload-duplicate')
  end
  if message.index ~= state.upload_next then return failure('out-of-order-upload') end
  if state.upload_bytes + #message.text > Contract.MAX_UPLOAD_BYTES then return failure('upload-byte-limit') end
  state.upload[message.index] = message.text
  state.upload_bytes, state.upload_next = state.upload_bytes + #message.text, state.upload_next + 1
  return true
end

local function admission(resident, payload, algorithm, facts_hash)
  if algorithm ~= 'grid-astar' and algorithm ~= 'grid-dijkstra' and algorithm ~= 'source-polygons' then
    return failure('unsupported-external-algorithm')
  end
  if not only(payload, {source_facts_hash = true, source_snapshot_hash = true,
      source_query_hash = true, result = true, derived = true}) then return failure('invalid-admission-envelope') end
  if payload.source_facts_hash ~= facts_hash then return failure('source-facts-identity-mismatch') end
  local source, source_query = resident.snapshot, resident.query
  if payload.source_snapshot_hash ~= source_query.data_ref.snapshot_hash
    or payload.source_snapshot_hash ~= Canonical.hash(source)
    or payload.source_query_hash ~= source_query.query_hash then return failure('source-capture-identity-mismatch') end
  local snapshot, query = source, source_query
  if payload.derived then
    if algorithm ~= 'source-polygons' then return failure('unexpected-derived-graph') end
    local derived = payload.derived
    if not only(derived, {snapshot_id = true, source_input = true, graph = true, query = true})
      or type(derived.query) ~= 'table' then return failure('invalid-derived-fields') end
    local expected = {snapshot_id = source.snapshot_id,
      snapshot_hash = source_query.data_ref.snapshot_hash, query_hash = source_query.query_hash}
    if not equal(derived.source_input, expected) then return failure('derived-source-binding-mismatch') end
    snapshot, query = copy(source), copy(derived.query)
    snapshot.snapshot_id, snapshot.source_input, snapshot.graph = derived.snapshot_id, copy(derived.source_input), copy(derived.graph)
    if not unchanged(source_query, query, {query_id = true, snapshot_id = true,
        data_ref = true, query_hash = true, start_node = true, goal_node = true}) then
      return failure('derived-command-changed')
    end
    if not unchanged(source_query.data_ref, query.data_ref or {}, {backend_id = true,
        backend_version = true, generation_id = true, snapshot_id = true,
        snapshot_hash = true, config_hash = true}) then return failure('derived-world-identity-changed') end
    if snapshot.snapshot_id ~= source.snapshot_id .. ':' .. POLYGON_BACKEND
      or query.query_id ~= source_query.query_id .. ':' .. POLYGON_BACKEND
      or query.data_ref.backend_id ~= POLYGON_BACKEND or query.data_ref.backend_version ~= '1'
      or query.data_ref.generation_id ~= source_query.data_ref.generation_id .. ':' .. POLYGON_BACKEND
      or query.start_node ~= 'start' or query.goal_node ~= 'goal'
      or type(snapshot.graph.representation) ~= 'table'
      or snapshot.graph.representation.id ~= POLYGON_BACKEND then return failure('derived-backend-identity-mismatch') end
    local config = copy(snapshot.graph.representation)
    config.id = nil
    if Canonical.hash(config) ~= query.data_ref.config_hash then return failure('derived-config-hash-mismatch') end
    if not equal(snapshot.geometry, source.geometry) then return failure('derived-source-geometry-changed') end
  elseif algorithm == 'source-polygons' then return failure('derived-graph-required') end
  local valid, detail = Boundary.validate_snapshot(snapshot)
  if not valid then return failure('snapshot:' .. detail.code) end
  valid, detail = Boundary.validate_query(query)
  if not valid then return failure('query:' .. detail.code) end
  if query.data_ref.snapshot_hash ~= Canonical.hash(snapshot)
    or query.data_ref.actor_hash ~= Canonical.hash(snapshot.actor)
    or query.snapshot_id ~= snapshot.snapshot_id then return failure('derived-content-hash-mismatch') end
  valid, detail = Boundary.validate_result(payload.result, query)
  if not valid then return failure('result:' .. detail.code) end
  local expected_solver = algorithm == 'source-polygons' and 'extremitypathfinder'
    or algorithm == 'grid-astar' and 'python-graph-astar' or 'python-graph-dijkstra'
  if payload.result.solver.id ~= expected_solver then return failure('solver-algorithm-identity-mismatch') end
  if algorithm ~= 'source-polygons' and payload.result.metrics.algorithm ~=
      (algorithm == 'grid-astar' and 'astar' or 'dijkstra') then return failure('solver-search-identity-mismatch') end
  return {snapshot = snapshot, query = query, result = copy(payload.result)}
end

function Contract.admission(resident, payload, algorithm, facts_hash)
  local ok, result, reason = pcall(admission, resident, payload, algorithm, facts_hash)
  if not ok then return nil, 'malformed-admission' end
  return result, reason
end

return Contract
