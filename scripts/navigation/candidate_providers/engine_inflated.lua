local EnginePath = require("scripts.navigation.candidate_providers.engine_path")

local EngineInflated = {kind = "async", required = false}

function EngineInflated.request(context)
  return EnginePath.request(context, true)
end

function EngineInflated.handle_result(context, event)
  return EnginePath.result(context, event, "engine-inflated", "engine-inflated")
end

return EngineInflated
