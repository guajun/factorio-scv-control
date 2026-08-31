local Serializable = require("scripts.navigation.serializable")

local Contracts = {}
Contracts.VERSION = 1
Contracts.SCHEMAS = {
  profile = {version = 1},
  profile_reference = {version = 1},
  candidate = {version = 1},
  route = {version = 1, includes = "corridor"},
  route_action = {version = 1},
  dependency = {version = 1},
  validator_result = {version = 1},
  cost_result = {version = 1},
  metrics = {version = 1},
  planning_result = {version = 1},
  terminal_result = {version = 1}
}

local function failure(contract, code, path, message)
  return false, {
    schema_version = Contracts.VERSION,
    kind = "navigation-contract-error",
    contract = contract,
    code = code,
    path = path,
    message = message
  }
end

local function require_plain_table(contract, value)
  if type(value) ~= "table" then
    return failure(contract, "expected-table", "$", "Contract value must be a table.")
  end
  local ok, serializable_error = Serializable.validate(value)
  if not ok then
    return failure(
      contract,
      serializable_error.code,
      serializable_error.path,
      serializable_error.message
    )
  end
  if value.schema_version ~= Contracts.VERSION then
    return failure(
      contract,
      "unsupported-schema-version",
      "$.schema_version",
      "Expected schema version " .. Contracts.VERSION .. "."
    )
  end
  return true
end

local function nonempty_string(contract, value, path)
  if type(value) ~= "string" or value == "" then
    return failure(contract, "expected-nonempty-string", path, "Value must be a non-empty string.")
  end
  return true
end

local function finite_number(contract, value, path, minimum)
  if type(value) ~= "number" or value ~= value
      or value == math.huge or value == -math.huge then
    return failure(contract, "expected-finite-number", path, "Value must be a finite number.")
  end
  if minimum ~= nil and value < minimum then
    return failure(contract, "number-below-minimum", path, "Value must be at least " .. minimum .. ".")
  end
  return true
end

local function positive_integer(contract, value, path)
  if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
    return failure(contract, "expected-positive-integer", path, "Value must be a positive integer.")
  end
  return true
end

local function array_length(contract, value, path)
  if type(value) ~= "table" then
    return nil, select(2, failure(contract, "expected-array", path, "Value must be an array."))
  end
  local count = 0
  local maximum = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return nil, select(2, failure(contract, "expected-array", path, "Array keys must be positive integers."))
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  if count ~= maximum then
    return nil, select(2, failure(contract, "sparse-array", path, "Arrays cannot contain gaps."))
  end
  return maximum
end

local function string_array(contract, value, path)
  local length, validation_error = array_length(contract, value, path)
  if not length then return false, validation_error end
  local seen = {}
  for index = 1, length do
    local ok, field_error = nonempty_string(contract, value[index], path .. "[" .. index .. "]")
    if not ok then return false, field_error end
    if seen[value[index]] then
      return failure(
        contract,
        "duplicate-array-value",
        path .. "[" .. index .. "]",
        "Array values must be unique."
      )
    end
    seen[value[index]] = true
  end
  return true
end

local function enum_value(contract, value, allowed, path)
  if allowed[value] then return true end
  return failure(contract, "invalid-enum-value", path, "Value is not supported by this schema version.")
end

local function point(contract, value, path)
  if type(value) ~= "table" then
    return failure(contract, "expected-position", path, "Position must contain finite x and y values.")
  end
  local ok, field_error = finite_number(contract, value.x, path .. ".x")
  if not ok then return false, field_error end
  return finite_number(contract, value.y, path .. ".y")
end

local validators = {}

validators.profile = function(value)
  local contract = "profile"
  local ok, validation_error = require_plain_table(contract, value)
  if not ok then return false, validation_error end
  ok, validation_error = nonempty_string(contract, value.id, "$.id")
  if not ok then return false, validation_error end
  ok, validation_error = nonempty_string(contract, value.world_model, "$.world_model")
  if not ok then return false, validation_error end
  for _, field in ipairs({"candidate_providers", "postprocessors", "validators", "requirements"}) do
    ok, validation_error = string_array(contract, value[field], "$." .. field)
    if not ok then return false, validation_error end
  end
  for _, field in ipairs({"cost_model", "selector", "trajectory", "replan_policy"}) do
    ok, validation_error = nonempty_string(contract, value[field], "$." .. field)
    if not ok then return false, validation_error end
  end
  if value.config ~= nil and type(value.config) ~= "table" then
    return failure(contract, "expected-table", "$.config", "Profile config must be a table.")
  end
  return true
end

validators.profile_reference = function(value)
  local contract = "profile_reference"
  local ok, validation_error = require_plain_table(contract, value)
  if not ok then return false, validation_error end
  local allowed = {schema_version = true, profile_id = true, values = true}
  for field in pairs(value) do
    if not allowed[field] then
      return failure(
        contract,
        "unexpected-field",
        "$." .. tostring(field),
        "Profile references can contain only a profile ID and serializable values."
      )
    end
  end
  ok, validation_error = nonempty_string(contract, value.profile_id, "$.profile_id")
  if not ok then return false, validation_error end
  if type(value.values) ~= "table" then
    return failure(contract, "expected-table", "$.values", "Profile values must be a table.")
  end
  return true
end

validators.route_action = function(value)
  local contract = "route_action"
  local ok, validation_error = require_plain_table(contract, value)
  if not ok then return false, validation_error end
  ok, validation_error = nonempty_string(contract, value.type, "$.type")
  if not ok then return false, validation_error end
  if value.at_point_index ~= nil then
    ok, validation_error = positive_integer(contract, value.at_point_index, "$.at_point_index")
    if not ok then return false, validation_error end
  end
  if value.values ~= nil and type(value.values) ~= "table" then
    return failure(contract, "expected-table", "$.values", "Action values must be a table.")
  end
  return true
end

validators.dependency = function(value)
  local contract = "dependency"
  local ok, validation_error = require_plain_table(contract, value)
  if not ok then return false, validation_error end
  ok, validation_error = nonempty_string(contract, value.kind, "$.kind")
  if not ok then return false, validation_error end
  if value.key ~= nil and type(value.key) ~= "string" and type(value.key) ~= "number" then
    return failure(contract, "invalid-dependency-key", "$.key", "Dependency key must be a string or number.")
  end
  if value.revision ~= nil then
    ok, validation_error = finite_number(contract, value.revision, "$.revision", 0)
    if not ok then return false, validation_error end
  end
  return true
end

validators.metrics = function(value)
  local contract = "metrics"
  local ok, validation_error = require_plain_table(contract, value)
  if not ok then return false, validation_error end
  if type(value.values) ~= "table" then
    return failure(contract, "expected-table", "$.values", "Metrics values must be a table.")
  end
  return true
end

local function optional_metrics(contract, value, path)
  if value == nil then return true end
  local ok, validation_error = validators.metrics(value)
  if ok then return true end
  validation_error.contract = contract
  validation_error.path = path .. validation_error.path:sub(2)
  return false, validation_error
end

local function corridor(contract, value)
  local length, validation_error = array_length(contract, value, "$.corridor")
  if not length then return false, validation_error end
  for index = 1, length do
    local segment = value[index]
    if type(segment) ~= "table" then
      return failure(
        contract,
        "expected-table",
        "$.corridor[" .. index .. "]",
        "Corridor segments must be serializable tables."
      )
    end
    if segment.from_point_index ~= nil then
      local ok, field_error = positive_integer(
        contract,
        segment.from_point_index,
        "$.corridor[" .. index .. "].from_point_index"
      )
      if not ok then return false, field_error end
    end
    if segment.to_point_index ~= nil then
      local ok, field_error = positive_integer(
        contract,
        segment.to_point_index,
        "$.corridor[" .. index .. "].to_point_index"
      )
      if not ok then return false, field_error end
    end
  end
  return true
end

validators.route = function(value)
  local contract = "route"
  local ok, validation_error = require_plain_table(contract, value)
  if not ok then return false, validation_error end
  ok, validation_error = enum_value(contract, value.status, {success = true}, "$.status")
  if not ok then return false, validation_error end
  ok, validation_error = nonempty_string(contract, value.source, "$.source")
  if not ok then return false, validation_error end
  local point_count
  point_count, validation_error = array_length(contract, value.points, "$.points")
  if not point_count then return false, validation_error end
  if point_count == 0 then
    return failure(contract, "empty-route", "$.points", "Successful routes require at least one point.")
  end
  for index = 1, point_count do
    ok, validation_error = point(contract, value.points[index], "$.points[" .. index .. "]")
    if not ok then return false, validation_error end
  end
  ok, validation_error = corridor(contract, value.corridor)
  if not ok then return false, validation_error end
  local action_count
  action_count, validation_error = array_length(contract, value.actions, "$.actions")
  if not action_count then return false, validation_error end
  for index = 1, action_count do
    ok, validation_error = validators.route_action(value.actions[index])
    if not ok then
      validation_error.contract = contract
      validation_error.path = "$.actions[" .. index .. "]" .. validation_error.path:sub(2)
      return false, validation_error
    end
  end
  local dependency_count
  dependency_count, validation_error = array_length(contract, value.dependencies, "$.dependencies")
  if not dependency_count then return false, validation_error end
  for index = 1, dependency_count do
    ok, validation_error = validators.dependency(value.dependencies[index])
    if not ok then
      validation_error.contract = contract
      validation_error.path = "$.dependencies[" .. index .. "]" .. validation_error.path:sub(2)
      return false, validation_error
    end
  end
  if type(value.predicted) ~= "table" then
    return failure(contract, "expected-table", "$.predicted", "Predicted route values must be a table.")
  end
  for _, field in ipairs({"distance", "travel_ticks"}) do
    if value.predicted[field] ~= nil then
      ok, validation_error = finite_number(
        contract,
        value.predicted[field],
        "$.predicted." .. field,
        0
      )
      if not ok then return false, validation_error end
    end
  end
  if type(value.world_revisions) ~= "table" then
    return failure(contract, "expected-table", "$.world_revisions", "World revisions must be a table.")
  end
  for revision, revision_value in pairs(value.world_revisions) do
    ok, validation_error = finite_number(
      contract,
      revision_value,
      "$.world_revisions." .. tostring(revision),
      0
    )
    if not ok then return false, validation_error end
  end
  return optional_metrics(contract, value.metrics, "$.metrics")
end

validators.candidate = function(value)
  local contract = "candidate"
  local ok, validation_error = require_plain_table(contract, value)
  if not ok then return false, validation_error end
  ok, validation_error = nonempty_string(contract, value.provider_id, "$.provider_id")
  if not ok then return false, validation_error end
  ok, validation_error = enum_value(
    contract,
    value.status,
    {success = true, ["no-path"] = true, busy = true, error = true},
    "$.status"
  )
  if not ok then return false, validation_error end
  if value.status == "success" then
    if value.route == nil then
      return failure(contract, "missing-route", "$.route", "Successful candidates require a route.")
    end
    ok, validation_error = validators.route(value.route)
    if not ok then
      validation_error.contract = contract
      validation_error.path = "$.route" .. validation_error.path:sub(2)
      return false, validation_error
    end
  elseif value.route ~= nil then
    return failure(contract, "unexpected-route", "$.route", "Only successful candidates can contain a route.")
  end
  return optional_metrics(contract, value.metrics, "$.metrics")
end

validators.validator_result = function(value)
  local contract = "validator_result"
  local ok, validation_error = require_plain_table(contract, value)
  if not ok then return false, validation_error end
  ok, validation_error = nonempty_string(contract, value.validator_id, "$.validator_id")
  if not ok then return false, validation_error end
  ok, validation_error = enum_value(
    contract,
    value.status,
    {pass = true, fail = true, error = true},
    "$.status"
  )
  if not ok then return false, validation_error end
  if value.reason ~= nil then
    ok, validation_error = nonempty_string(contract, value.reason, "$.reason")
    if not ok then return false, validation_error end
  end
  return optional_metrics(contract, value.metrics, "$.metrics")
end

validators.cost_result = function(value)
  local contract = "cost_result"
  local ok, validation_error = require_plain_table(contract, value)
  if not ok then return false, validation_error end
  ok, validation_error = nonempty_string(contract, value.cost_model_id, "$.cost_model_id")
  if not ok then return false, validation_error end
  ok, validation_error = enum_value(
    contract,
    value.status,
    {success = true, error = true},
    "$.status"
  )
  if not ok then return false, validation_error end
  if value.status == "success" then
    ok, validation_error = finite_number(contract, value.value, "$.value", 0)
    if not ok then return false, validation_error end
  elseif value.value ~= nil then
    return failure(contract, "unexpected-cost", "$.value", "Failed cost results cannot contain a value.")
  end
  if value.components ~= nil and type(value.components) ~= "table" then
    return failure(contract, "expected-table", "$.components", "Cost components must be a table.")
  end
  return optional_metrics(contract, value.metrics, "$.metrics")
end

validators.terminal_result = function(value)
  local contract = "terminal_result"
  local ok, validation_error = require_plain_table(contract, value)
  if not ok then return false, validation_error end
  ok, validation_error = enum_value(
    contract,
    value.status,
    {arrived = true, ["no-path"] = true, cancelled = true, failed = true},
    "$.status"
  )
  if not ok then return false, validation_error end
  if value.route ~= nil then
    ok, validation_error = validators.route(value.route)
    if not ok then
      validation_error.contract = contract
      validation_error.path = "$.route" .. validation_error.path:sub(2)
      return false, validation_error
    end
  end
  if value.reason ~= nil then
    ok, validation_error = nonempty_string(contract, value.reason, "$.reason")
    if not ok then return false, validation_error end
  end
  return optional_metrics(contract, value.metrics, "$.metrics")
end

validators.planning_result = function(value)
  local contract = "planning_result"
  local ok, validation_error = require_plain_table(contract, value)
  if not ok then return false, validation_error end
  ok, validation_error = enum_value(
    contract,
    value.status,
    {
      success = true,
      ["no-path"] = true,
      ["busy-retry"] = true,
      cancelled = true,
      stale = true,
      failed = true
    },
    "$.status"
  )
  if not ok then return false, validation_error end
  if value.status == "success" then
    if value.route == nil then
      return failure(contract, "missing-route", "$.route", "Successful planning results require a route.")
    end
    ok, validation_error = validators.route(value.route)
    if not ok then
      validation_error.contract = contract
      validation_error.path = "$.route" .. validation_error.path:sub(2)
      return false, validation_error
    end
  elseif value.route ~= nil then
    return failure(contract, "unexpected-route", "$.route", "Only successful planning results can contain a route.")
  end
  ok, validation_error = string_array(contract, value.provider_order, "$.provider_order")
  if not ok then return false, validation_error end
  local trace_length
  trace_length, validation_error = array_length(contract, value.trace, "$.trace")
  if not trace_length then return false, validation_error end
  local candidate_length
  candidate_length, validation_error = array_length(contract, value.candidates, "$.candidates")
  if not candidate_length then return false, validation_error end
  for index = 1, candidate_length do
    ok, validation_error = validators.candidate(value.candidates[index])
    if not ok then
      validation_error.contract = contract
      validation_error.path = "$.candidates[" .. index .. "]" .. validation_error.path:sub(2)
      return false, validation_error
    end
  end
  if value.retry_after_ticks ~= nil then
    ok, validation_error = finite_number(
      contract,
      value.retry_after_ticks,
      "$.retry_after_ticks",
      0
    )
    if not ok then return false, validation_error end
  end
  if value.reason ~= nil then
    ok, validation_error = nonempty_string(contract, value.reason, "$.reason")
    if not ok then return false, validation_error end
  end
  return optional_metrics(contract, value.metrics, "$.metrics")
end

function Contracts.validate(contract, value)
  local validator = validators[contract]
  if not validator then
    return failure(
      tostring(contract),
      "unknown-contract",
      "$",
      "No validator is registered for this contract."
    )
  end
  return validator(value)
end

function Contracts.copy(contract, value)
  local ok, validation_error = Contracts.validate(contract, value)
  if not ok then return nil, validation_error end
  return Serializable.copy(value)
end

return Contracts
