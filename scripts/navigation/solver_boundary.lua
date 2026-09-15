local Serializable = require("scripts.navigation.serializable")
local Canonical = require("scripts.navigation.canonical")

local Boundary = {PROTOCOL = "scv-navigation/1"}
-- Interchange resource limits, independent of planner tuning and caller budgets.
Boundary.LIMITS = {points = 100000, nodes = 100000, edges = 800000, entries = 200000}
local outcomes = {
  complete = true, partial = true, ["no-path"] = true, ["budget-exhausted"] = true,
  cancelled = true, ["stale-world"] = true, unsupported = true,
  ["invalid-query"] = true, error = true
}

local function need(condition, code, path)
  if not condition then
    error({kind = "solver-boundary-error", code = code, path = path,
      message = code .. " at " .. path}, 0)
  end
end

local function checked(operation)
  local ok, result = pcall(operation)
  if ok then return true, result end
  if type(result) ~= "table" then
    result = {kind = "solver-boundary-error", code = "invalid-value", path = "$", message = tostring(result)}
  end
  return false, result
end

local function object(value, path)
  need(type(value) == "table", "expected-object", path)
end

local function plain(value)
  local ok, detail = Serializable.validate(value)
  need(ok, detail and detail.code or "nonserializable", detail and detail.path or "$")
  object(value, "$")
end

local function text_value(value, path)
  need(type(value) == "string" and #value > 0 and #value <= 1024, "invalid-string", path)
end

local function number(value, path, minimum)
  need(type(value) == "number" and value == value and math.abs(value) < math.huge
    and (minimum == nil or value >= minimum), "invalid-number", path)
end

local function integer(value, path, minimum, maximum)
  number(value, path, minimum)
  need(value % 1 == 0 and (not maximum or value <= maximum), "invalid-integer", path)
end

local function array(value, path, limit)
  object(value, path)
  local count, maximum = 0, 0
  for key in pairs(value) do
    integer(key, path, 1, limit)
    count, maximum = count + 1, math.max(maximum, key)
  end
  need(count == maximum, "sparse-array", path)
  return count
end

local function point(value, path)
  object(value, path)
  number(value.x, path .. ".x")
  number(value.y, path .. ".y")
end

local function bounds(value, path)
  object(value, path)
  point(value.left_top, path .. ".left_top")
  point(value.right_bottom, path .. ".right_bottom")
  need(value.left_top.x < value.right_bottom.x and value.left_top.y < value.right_bottom.y,
    "invalid-bounds", path)
end

local function revisions(value)
  object(value, "$.revisions")
  integer(value.topology, "$.revisions.topology", 0)
  integer(value.motion, "$.revisions.motion", 0)
end

local function inside(position, area)
  return position.x >= area.left_top.x and position.x <= area.right_bottom.x
    and position.y >= area.left_top.y and position.y <= area.right_bottom.y
end

local function coverage(value)
  object(value, "$.coverage")
  bounds(value.bounds, "$.coverage.bounds")
  need(value.unknown == "blocked", "unsupported-unknown-policy", "$.coverage.unknown")
end

local function envelope(value, kind)
  plain(value)
  need(value.protocol == Boundary.PROTOCOL, "unsupported-protocol", "$.protocol")
  need(value.kind == kind, "invalid-kind", "$.kind")
end

local function data_ref(value)
  object(value, "$.data_ref")
  for _, key in ipairs({"backend_id", "backend_version", "generation_id", "snapshot_id",
      "snapshot_hash", "config_hash", "actor_hash"}) do text_value(value[key], "$.data_ref." .. key) end
  revisions(value.revisions)
end

function Boundary.validate_data_ref(value)
  return checked(function() plain(value); data_ref(value) end)
end

function Boundary.validate_snapshot(snapshot)
  return checked(function()
    envelope(snapshot, "world-snapshot")
    for _, key in ipairs({"snapshot_id", "world_id", "surface_id"}) do text_value(snapshot[key], "$." .. key) end
    integer(snapshot.captured_tick, "$.captured_tick", 0)
    object(snapshot.actor, "$.actor")
    revisions(snapshot.revisions)
    coverage(snapshot.coverage)
    object(snapshot.geometry, "$.geometry")
    for _, kind in ipairs({"entities", "tiles"}) do
      local seen = {}
      array(snapshot.geometry[kind], "$.geometry." .. kind, Boundary.LIMITS.entries)
      for _, item in ipairs(snapshot.geometry[kind]) do
        object(item, "$.geometry." .. kind)
        text_value(item.id, "$.geometry." .. kind .. ".id")
        need(not seen[item.id], "duplicate-geometry-id", "$.geometry." .. kind)
        seen[item.id] = true
      end
    end
    if snapshot.graph then
      object(snapshot.graph, "$.graph")
      array(snapshot.graph.nodes, "$.graph.nodes", Boundary.LIMITS.nodes)
      array(snapshot.graph.edges, "$.graph.edges", Boundary.LIMITS.edges)
      local nodes, edges = {}, {}
      for _, node in ipairs(snapshot.graph.nodes) do
        object(node, "$.graph.nodes")
        text_value(node.id, "$.graph.nodes.id")
        point(node.position, "$.graph.nodes.position")
        need(inside(node.position, snapshot.coverage.bounds), "node-outside-coverage", "$.graph.nodes")
        need(not nodes[node.id], "duplicate-node", "$.graph.nodes")
        nodes[node.id] = true
      end
      for _, edge in ipairs(snapshot.graph.edges) do
        object(edge, "$.graph.edges")
        need(nodes[edge.from] and nodes[edge.to], "unknown-edge-node", "$.graph.edges")
        number(edge.distance, "$.graph.edges.distance", 0)
        if edge.travel_ticks ~= nil then number(edge.travel_ticks, "$.graph.edges.travel_ticks", 0) end
        edges[edge.from] = edges[edge.from] or {}
        need(not edges[edge.from][edge.to], "duplicate-edge", "$.graph.edges")
        edges[edge.from][edge.to] = true
      end
    end
  end)
end

function Boundary.hash_query(query)
  local value, detail = Serializable.copy(query)
  if not value then return nil, detail end
  value.query_hash = nil
  return Canonical.hash(value)
end

local function objective(value)
  object(value, "$.objective")
  need((value.id == "distance" and value.units == "tiles")
    or (value.id == "travel-time" and value.units == "ticks"), "unsupported-objective", "$.objective")
end

local function query_shape(query)
  envelope(query, "navigation-query")
  for _, key in ipairs({"query_id", "session_id", "command_id", "attempt_id", "snapshot_id", "query_hash"}) do
    text_value(query[key], "$." .. key)
  end
  data_ref(query.data_ref)
  need(query.snapshot_id == query.data_ref.snapshot_id, "snapshot-id-mismatch", "$.snapshot_id")
  point(query.start, "$.start"); point(query.goal, "$.goal")
  number(query.goal_tolerance, "$.goal_tolerance", 0)
  if query.execution then
    object(query.execution, "$.execution")
    need(query.execution.controller_id == "native-follower-v1", "unsupported-controller", "$.execution.controller_id")
    number(query.execution.arrival_tolerance, "$.execution.arrival_tolerance", 0)
  end
  objective(query.objective)
  array(query.required_capabilities, "$.required_capabilities", 128)
  local seen = {}
  for _, capability in ipairs(query.required_capabilities) do
    text_value(capability, "$.required_capabilities")
    need(not seen[capability], "duplicate-capability", "$.required_capabilities")
    seen[capability] = true
  end
  object(query.budget, "$.budget")
  integer(query.budget.max_expansions, "$.budget.max_expansions", 0, 1000000)
  integer(query.budget.max_points, "$.budget.max_points", 1, Boundary.LIMITS.points)
  if query.start_node then text_value(query.start_node, "$.start_node") end
  if query.goal_node then text_value(query.goal_node, "$.goal_node") end
  need(Boundary.hash_query(query) == query.query_hash, "query-hash-mismatch", "$.query_hash")
end

function Boundary.validate_query(query)
  return checked(function() query_shape(query) end)
end

function Boundary.check_capabilities(query, descriptor)
  return checked(function()
    query_shape(query)
    local support = descriptor.query_support
    need(type(support) == "table", "provider-has-no-query-contract", "$.provider." .. descriptor.id)
    local provided = {}
    for _, value in ipairs(support.capabilities or {}) do provided[value] = true end
    for _, required in ipairs(query.required_capabilities) do
      need(provided[required], "unsupported-capability", "$.provider." .. descriptor.id .. "." .. required)
    end
    local objective_supported = false
    for _, id in ipairs(support.objectives or {}) do
      if id == query.objective.id then objective_supported = true end
    end
    need(objective_supported, "unsupported-provider-objective", "$.provider." .. descriptor.id)
    if support.backends then
      local supported = false
      for _, id in ipairs(support.backends) do if id == query.data_ref.backend_id then supported = true end end
      need(supported, "unsupported-backend", "$.data_ref.backend_id")
    end
  end)
end

function Boundary.validate_result(result, query)
  return checked(function()
    query_shape(query)
    envelope(result, "solver-result")
    for _, key in ipairs({"query_id", "session_id", "command_id", "attempt_id", "snapshot_id", "query_hash"}) do
      need(result[key] == query[key], "result-identity-mismatch", "$." .. key)
    end
    data_ref(result.data_ref)
    need(Canonical.encode(result.data_ref) == Canonical.encode(query.data_ref), "data-ref-mismatch", "$.data_ref")
    need(outcomes[result.outcome], "invalid-outcome", "$.outcome")
    objective(result.objective)
    need(Canonical.encode(result.objective) == Canonical.encode(query.objective), "objective-mismatch", "$.objective")
    object(result.solver, "$.solver")
    text_value(result.solver.id, "$.solver.id"); text_value(result.solver.version, "$.solver.version")
    coverage(result.coverage)
    local count = array(result.points, "$.points", query.budget.max_points)
    for _, p in ipairs(result.points) do
      point(p, "$.points")
      need(inside(p, result.coverage.bounds), "route-outside-coverage", "$.points")
    end
    if result.outcome == "complete" then
      need(count > 0, "empty-complete-route", "$.points")
      local first, last = result.points[1], result.points[count]
      need(first.x == query.start.x and first.y == query.start.y, "start-mismatch", "$.points[1]")
      local dx, dy = last.x - query.goal.x, last.y - query.goal.y
      need(dx * dx + dy * dy <= query.goal_tolerance * query.goal_tolerance,
        "incomplete-endpoint", "$.points")
      object(result.predicted, "$.predicted")
      number(result.predicted.distance, "$.predicted.distance", 0)
      if query.objective.id == "travel-time" then number(result.predicted.travel_ticks, "$.predicted.travel_ticks", 0) end
    elseif result.outcome == "no-path" then
      need(result.coverage.scope == "bounded-graph", "unscoped-no-path", "$.coverage.scope")
      need(count == 0, "no-path-with-points", "$.points")
    elseif result.outcome ~= "partial" and result.outcome ~= "budget-exhausted" then
      need(count == 0, "failure-with-points", "$.points")
    end
    if result.predicted and result.predicted.travel_ticks ~= nil then
      number(result.predicted.travel_ticks, "$.predicted.travel_ticks", 0)
    end
    object(result.metrics, "$.metrics")
    -- Conditional transitions are reserved until a calibrated executor exists.
    if result.actions then need(array(result.actions, "$.actions", 0) == 0, "unsupported-actions", "$.actions") end
  end)
end

function Boundary.admit(result, query, current_data_ref)
  local valid, detail = Boundary.validate_result(result, query)
  if not valid then return false, detail end
  return checked(function()
    data_ref(current_data_ref)
    need(Canonical.encode(current_data_ref) == Canonical.encode(query.data_ref), "stale-world", "$.data_ref")
  end)
end

function Boundary.actor_descriptor(actor)
  local prototype = actor.prototype
  local box = prototype.collision_box
  return {
    name = actor.name,
    collision_box = {
      left_top = {x = box.left_top.x, y = box.left_top.y},
      right_bottom = {x = box.right_bottom.x, y = box.right_bottom.y}
    },
    collision_mask = assert(Serializable.copy(prototype.collision_mask)),
    running_speed = actor.character_running_speed,
    force = type(actor.force) == "string" and actor.force or actor.force.name
  }
end

return Boundary
