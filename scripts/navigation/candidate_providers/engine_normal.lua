local EnginePath = require("scripts.navigation.candidate_providers.engine_path")

local EngineNormal = {kind = "async", required = true}

function EngineNormal.request(context)
  return EnginePath.request(context, false)
end

function EngineNormal.handle_result(context, event)
  return EnginePath.result(context, event, "engine-normal", "engine")
end

return EngineNormal
