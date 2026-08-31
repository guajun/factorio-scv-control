local Serializable = {}

local function error_result(code, path, message)
  return false, {
    code = code,
    path = path,
    message = message
  }
end

local function key_path(path, key)
  if type(key) == "number" then return path .. "[" .. key .. "]" end
  if key:match("^[%a_][%w_]*$") then return path .. "." .. key end
  return path .. "[" .. string.format("%q", key) .. "]"
end

local function ordered_keys(value)
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(first, second)
    local first_type = type(first)
    local second_type = type(second)
    if first_type ~= second_type then return first_type < second_type end
    return first < second
  end)
  return keys
end

local function validate_value(value, path, ancestors)
  local value_type = type(value)
  if value_type == "nil" or value_type == "boolean" or value_type == "string" then
    return true
  end
  if value_type == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return error_result("non-finite-number", path, "Numbers must be finite.")
    end
    return true
  end
  if value_type ~= "table" then
    return error_result(
      "unsupported-value-type",
      path,
      "Serializable values cannot contain " .. value_type .. "."
    )
  end
  if getmetatable(value) ~= nil then
    return error_result("table-has-metatable", path, "Serializable tables cannot have metatables.")
  end
  if ancestors[value] then
    return error_result("cyclic-table", path, "Serializable tables cannot contain cycles.")
  end

  ancestors[value] = true
  for key in pairs(value) do
    local key_type = type(key)
    if key_type ~= "string"
        and (key_type ~= "number" or key < 1 or key % 1 ~= 0) then
      ancestors[value] = nil
      return error_result(
        "unsupported-table-key",
        path,
        "Table keys must be strings or positive integers."
      )
    end
  end
  for _, key in ipairs(ordered_keys(value)) do
    local ok, validation_error = validate_value(value[key], key_path(path, key), ancestors)
    if not ok then
      ancestors[value] = nil
      return false, validation_error
    end
  end
  ancestors[value] = nil
  return true
end

function Serializable.validate(value)
  return validate_value(value, "$", {})
end

local function copy_value(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, child in pairs(value) do copy[key] = copy_value(child) end
  return copy
end

function Serializable.copy(value)
  local ok, validation_error = Serializable.validate(value)
  if not ok then return nil, validation_error end
  return copy_value(value)
end

return Serializable
