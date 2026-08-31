local Contracts = require("scripts.navigation.contracts")
local Serializable = require("scripts.navigation.serializable")

local Profiles = {}
Profiles.DEFAULT_ID = "production-v1"

local ordered = {
  require("scripts.navigation.profiles.production_v1")
}
local by_id = {}
for _, profile in ipairs(ordered) do
  local ok, validation_error = Contracts.validate("profile", profile)
  if not ok then error(validation_error.message .. " at " .. validation_error.path) end
  if by_id[profile.id] then error("Duplicate navigation profile ID " .. profile.id .. ".") end
  by_id[profile.id] = profile
end

local function copy(value)
  local result, copy_error = Serializable.copy(value)
  if not result then error(copy_error.message) end
  return result
end

function Profiles.get(id)
  local profile = by_id[id]
  return profile and copy(profile) or nil
end

function Profiles.list()
  local result = {}
  for _, profile in ipairs(ordered) do result[#result + 1] = copy(profile) end
  return result
end

function Profiles.default_reference()
  return {
    schema_version = Contracts.VERSION,
    profile_id = Profiles.DEFAULT_ID,
    values = {}
  }
end

return Profiles
