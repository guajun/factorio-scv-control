local Contracts = require("scripts.navigation.contracts")
local Profiles = require("scripts.navigation.profiles.init")
local Registries = require("scripts.navigation.registries.init")
local Serializable = require("scripts.navigation.serializable")

local ProfileResolver = {}

local function resolution_error(code, profile_id, fields)
  fields = fields or {}
  local result = {
    schema_version = Contracts.VERSION,
    kind = "profile-resolution-error",
    code = code,
    profile_id = profile_id,
    message = fields.message or code
  }
  for key, value in pairs(fields) do
    if key ~= "message" then result[key] = value end
  end
  return result
end

local function copy(value)
  local result, copy_error = Serializable.copy(value)
  if not result then return nil, copy_error end
  return result
end

local function sorted_keys(set)
  local result = {}
  for key in pairs(set) do result[#result + 1] = key end
  table.sort(result)
  return result
end

local function stage_ids(profile, stage)
  if stage.cardinality == "many" then return profile[stage.profile_key] end
  return {profile[stage.profile_key]}
end

function ProfileResolver.reference(profile_id, values)
  if values == nil then values = {} end
  local reference = {
    schema_version = Contracts.VERSION,
    profile_id = profile_id,
    values = values
  }
  local ok, validation_error = Contracts.validate("profile_reference", reference)
  if not ok then return nil, validation_error end
  return copy(reference)
end

function ProfileResolver.preflight_profile(profile, values)
  local profile_id = type(profile) == "table" and profile.id or nil
  local ok, validation_error = Contracts.validate("profile", profile)
  if not ok then
    return nil, resolution_error("invalid-profile", profile_id, {
      contract_error = validation_error,
      message = validation_error.message
    })
  end
  if values == nil then values = {} end
  local values_ok, values_error = Serializable.validate(values)
  if not values_ok then
    return nil, resolution_error("invalid-profile-values", profile.id, {
      contract_error = values_error,
      message = values_error.message
    })
  end

  local stages = {}
  local capabilities = {}
  for _, stage in ipairs(Registries.STAGES) do
    local ids = stage_ids(profile, stage)
    if stage.minimum and #ids < stage.minimum then
      return nil, resolution_error("invalid-stage-combination", profile.id, {
        stage = stage.profile_key,
        message = "Stage " .. stage.profile_key .. " requires at least " .. stage.minimum .. " component."
      })
    end
    local definitions = {}
    for _, id in ipairs(ids) do
      local definition = stage.registry.get(id)
      if not definition then
        return nil, resolution_error("unknown-component", profile.id, {
          stage = stage.profile_key,
          component_id = id,
          message = "Unknown " .. stage.profile_key .. " component " .. tostring(id) .. "."
        })
      end
      local missing = {}
      for _, capability in ipairs(definition.requires) do
        if not capabilities[capability] then missing[#missing + 1] = capability end
      end
      if #missing > 0 then
        table.sort(missing)
        return nil, resolution_error("missing-capability", profile.id, {
          stage = stage.profile_key,
          component_id = definition.id,
          missing_capabilities = missing,
          message = "Component " .. definition.id .. " is missing required capabilities."
        })
      end
      definitions[#definitions + 1] = definition
      for _, capability in ipairs(definition.provides) do capabilities[capability] = true end
    end
    stages[stage.resolved_key] = stage.cardinality == "many" and definitions or definitions[1]
  end

  local missing_requirements = {}
  for _, capability in ipairs(profile.requirements) do
    if not capabilities[capability] then missing_requirements[#missing_requirements + 1] = capability end
  end
  if #missing_requirements > 0 then
    table.sort(missing_requirements)
    return nil, resolution_error("missing-profile-capability", profile.id, {
      missing_capabilities = missing_requirements,
      message = "Profile requirements are not satisfied."
    })
  end

  local profile_copy, profile_copy_error = copy(profile)
  if not profile_copy then
    return nil, resolution_error("invalid-profile", profile.id, {
      contract_error = profile_copy_error,
      message = profile_copy_error.message
    })
  end
  local values_copy, values_copy_error = copy(values)
  if not values_copy then
    return nil, resolution_error("invalid-profile-values", profile.id, {
      contract_error = values_copy_error,
      message = values_copy_error.message
    })
  end
  return {
    schema_version = Contracts.VERSION,
    profile = profile_copy,
    values = values_copy,
    stages = stages,
    capabilities = sorted_keys(capabilities)
  }
end

function ProfileResolver.preflight(reference)
  local profile_id = type(reference) == "table" and reference.profile_id or nil
  local ok, validation_error = Contracts.validate("profile_reference", reference)
  if not ok then
    return nil, resolution_error("invalid-profile-reference", profile_id, {
      contract_error = validation_error,
      message = validation_error.message
    })
  end
  local profile = Profiles.get(reference.profile_id)
  if not profile then
    return nil, resolution_error("unknown-profile", reference.profile_id, {
      message = "Unknown navigation profile " .. reference.profile_id .. "."
    })
  end
  return ProfileResolver.preflight_profile(profile, reference.values)
end

function ProfileResolver.load_implementations()
  for _, stage in ipairs(Registries.STAGES) do
    local loaded, load_error = stage.registry.load()
    if not loaded then
      return nil, resolution_error("module-load-failed", nil, {
        stage = stage.profile_key,
        component_id = load_error.component_id,
        module = load_error.module,
        cause = load_error.cause,
        message = "Failed to load module for component " .. load_error.component_id .. "."
      })
    end
  end
  return true
end

local function resolve_definition(profile_id, stage, definition)
  local resolved, load_error = stage.registry.resolve(definition.id)
  if not resolved then
    return nil, resolution_error("module-load-failed", profile_id, {
      stage = stage.profile_key,
      component_id = definition.id,
      module = definition.module,
      cause = load_error,
      message = "Failed to load module for component " .. definition.id .. "."
    })
  end
  return resolved
end

function ProfileResolver.resolve_profile(profile, values)
  local preflight, preflight_error = ProfileResolver.preflight_profile(profile, values)
  if not preflight then return nil, preflight_error end
  local resolved_stages = {}
  for _, stage in ipairs(Registries.STAGES) do
    local definitions = preflight.stages[stage.resolved_key]
    if stage.cardinality == "many" then
      local resolved = {}
      for _, definition in ipairs(definitions) do
        local component, component_error = resolve_definition(profile.id, stage, definition)
        if not component then return nil, component_error end
        resolved[#resolved + 1] = component
      end
      resolved_stages[stage.resolved_key] = resolved
    else
      local component, component_error = resolve_definition(profile.id, stage, definitions)
      if not component then return nil, component_error end
      resolved_stages[stage.resolved_key] = component
    end
  end
  return {
    schema_version = Contracts.VERSION,
    profile = preflight.profile,
    values = preflight.values,
    capabilities = preflight.capabilities,
    stages = resolved_stages
  }
end

function ProfileResolver.resolve(reference)
  local preflight, preflight_error = ProfileResolver.preflight(reference)
  if not preflight then return nil, preflight_error end
  return ProfileResolver.resolve_profile(preflight.profile, preflight.values)
end

return ProfileResolver
