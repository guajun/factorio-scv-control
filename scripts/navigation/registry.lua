local Serializable = require("scripts.navigation.serializable")

local Registry = {}

local function copy(value)
  local result, copy_error = Serializable.copy(value)
  if not result then error(copy_error.message) end
  return result
end

local function validate_string_array(family, id, field, values)
  if type(values) ~= "table" then
    error("Navigation registry " .. family .. "/" .. id .. " requires an array for " .. field .. ".")
  end
  local seen = {}
  local count = 0
  local maximum = 0
  for key in pairs(values) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      error("Navigation registry " .. family .. "/" .. id .. " requires an array for " .. field .. ".")
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  if count ~= maximum then
    error("Navigation registry " .. family .. "/" .. id .. " has a sparse " .. field .. " array.")
  end
  for index = 1, maximum do
    local value = values[index]
    if type(value) ~= "string" or value == "" then
      error("Navigation registry " .. family .. "/" .. id .. " has an invalid " .. field .. " entry at " .. index .. ".")
    end
    if seen[value] then
      error("Navigation registry " .. family .. "/" .. id .. " repeats " .. field .. " capability " .. value .. ".")
    end
    seen[value] = true
  end
end

function Registry.create(family, definitions)
  if type(family) ~= "string" or family == "" then error("Navigation registry family is required.") end
  if type(definitions) ~= "table" then error("Navigation registry definitions must be an array.") end

  local ordered_ids = {}
  local by_id = {}
  local implementations = {}
  local load_errors = {}
  for index, definition in ipairs(definitions) do
    local ok, validation_error = Serializable.validate(definition)
    if not ok then
      error("Navigation registry " .. family .. " entry " .. index .. " is not serializable: " .. validation_error.message)
    end
    if type(definition.id) ~= "string" or definition.id == "" then
      error("Navigation registry " .. family .. " entry " .. index .. " has no ID.")
    end
    if by_id[definition.id] then
      error("Navigation registry " .. family .. " repeats ID " .. definition.id .. ".")
    end
    if type(definition.module) ~= "string" or definition.module == "" then
      error("Navigation registry " .. family .. "/" .. definition.id .. " has no module.")
    end
    validate_string_array(family, definition.id, "provides", definition.provides)
    validate_string_array(family, definition.id, "requires", definition.requires)
    local stored = copy(definition)
    stored.family = family
    ordered_ids[#ordered_ids + 1] = stored.id
    by_id[stored.id] = stored
  end

  local instance = {family = family}
  local implementations_loaded = false

  function instance.list()
    local result = {}
    for _, id in ipairs(ordered_ids) do result[#result + 1] = copy(by_id[id]) end
    return result
  end

  function instance.get(id)
    local definition = by_id[id]
    return definition and copy(definition) or nil
  end

  function instance.load()
    if implementations_loaded then
      for _, id in ipairs(ordered_ids) do
        if load_errors[id] then
          return false, {
            component_id = id,
            module = by_id[id].module,
            cause = load_errors[id]
          }
        end
      end
      return true
    end
    implementations_loaded = true
    for _, id in ipairs(ordered_ids) do
      local loaded, implementation = pcall(require, by_id[id].module)
      if loaded then
        implementations[id] = implementation
      else
        load_errors[id] = tostring(implementation)
        return false, {
          component_id = id,
          module = by_id[id].module,
          cause = load_errors[id]
        }
      end
    end
    return true
  end

  function instance.resolve(id)
    local definition = by_id[id]
    if not definition then return nil, "unknown-component" end
    if not implementations_loaded then return nil, "registry-not-loaded" end
    local implementation = implementations[id]
    if implementation == nil then return nil, load_errors[id] end
    return {
      definition = copy(definition),
      implementation = implementation
    }
  end

  return instance
end

return Registry
