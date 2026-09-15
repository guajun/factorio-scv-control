local Imported = require("scripts.navigation.candidate_providers.imported_route")

local External = {kind = "external", required = true}

function External.request(context)
  if type(context.request_solver) ~= "function" then return nil, "missing-solver-transport" end
  local token, detail = context.request_solver(context.navigation_query)
  if type(token) ~= "string" or token == "" then return nil, detail or "invalid-solver-token" end
  return token
end

function External.handle_result(context, event)
  return Imported.adapt(context, event.result, "external-route")
end

return External
