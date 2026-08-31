local Contracts = require("scripts.navigation.contracts")
local PathMath = require("scripts.path_math")
local Policy = require("scripts.navigation_policy")
local ProfileResolver = require("scripts.navigation.profile_resolver")
local Serializable = require("scripts.navigation.serializable")

local PlanningRun = {}
local implementations_loaded, implementation_error = ProfileResolver.load_implementations()

local function copy(value)
  local result, copy_error = Serializable.copy(value)
  if not result then error(copy_error.message .. " at " .. copy_error.path) end
  return result
end

local function tick(runtime)
  if runtime and runtime.tick ~= nil then
    return type(runtime.tick) == "function" and runtime.tick() or runtime.tick
  end
  return game and game.tick or 0
end

local function append_trace(run, runtime, event)
  event.sequence = #run.trace + 1
  event.tick_offset = math.max(0, tick(runtime) - run.started_tick)
  run.trace[#run.trace + 1] = event
  if runtime and runtime.on_trace then runtime.on_trace(copy(event), run) end
end

local function metrics(values)
  return {schema_version = Contracts.VERSION, values = values or {}}
end

local function planning_result(run, status, fields)
  fields = fields or {}
  local result = {
    schema_version = Contracts.VERSION,
    status = status,
    run_id = run.id,
    adapter_id = run.adapter_id,
    profile_id = run.profile_reference.profile_id,
    provider_order = copy(run.provider_order),
    trace = copy(run.trace),
    candidates = copy(run.candidates),
    metrics = metrics({
      request_count = run.request_count,
      duration_ticks = math.max(0, (fields.finished_tick or run.started_tick) - run.started_tick)
    })
  }
  for key, value in pairs(fields) do
    if key ~= "finished_tick" then result[key] = value end
  end
  local valid, validation_error = Contracts.validate("planning_result", result)
  if not valid then error(validation_error.message .. " at " .. validation_error.path) end
  return result
end

local function finish(run, runtime, status, fields)
  if run.status ~= "running" then return run.terminal_result end
  fields = fields or {}
  append_trace(run, runtime, {
    event = "terminal",
    status = status,
    reason = fields.reason
  })
  fields.finished_tick = tick(runtime)
  run.status = status
  run.pending_request_id = nil
  run.pending_provider_id = nil
  run.terminal_result = planning_result(run, status, fields)
  return run.terminal_result
end

local function fail(run, runtime, reason, fields)
  fields = fields or {}
  fields.reason = reason
  return finish(run, runtime, "failed", fields)
end

local function resolve(run)
  if not implementations_loaded then return nil, implementation_error end
  return ProfileResolver.resolve(run.profile_reference)
end

local function candidates_by_provider(run)
  local result = {}
  for _, candidate in ipairs(run.candidates) do
    result[candidate.provider_id] = candidate
  end
  return result
end

local function context(run, runtime, resolved)
  return {
    run_id = run.id,
    adapter_id = run.adapter_id,
    profile = resolved.profile,
    profile_values = resolved.values,
    surface = runtime.surface,
    actor = runtime.actor,
    start_position = run.start_position,
    goal_position = run.goal_position,
    reason = run.reason,
    candidates = run.candidates,
    candidates_by_provider = candidates_by_provider(run),
    request_path = runtime.request_path
  }
end

local function call_component(run, runtime, label, implementation, method, ...)
  local operation = implementation and implementation[method]
  if type(operation) ~= "function" then
    return nil, label .. " does not implement " .. method
  end
  local called, first, second = pcall(operation, ...)
  if not called then return nil, tostring(first) end
  if first == nil then return nil, tostring(second or (label .. " returned no result")) end
  return first, second
end

local function validate_contract(contract, value)
  local valid, validation_error = Contracts.validate(contract, value)
  if valid then return true end
  return nil, validation_error.message .. " at " .. validation_error.path
end

local function process_candidate(run, runtime, resolved, candidate)
  local component_context = context(run, runtime, resolved)
  local route = candidate.route
  for _, component in ipairs(resolved.stages.postprocessors) do
    local component_id = component.definition.id
    route, candidate.stage_error = call_component(
      run,
      runtime,
      component_id,
      component.implementation,
      "process",
      component_context,
      route
    )
    if not route then return nil, candidate.stage_error end
    local valid, validation_error = validate_contract("route", route)
    if not valid then return nil, validation_error end
    append_trace(run, runtime, {
      event = "postprocess",
      component_id = component_id,
      provider_id = candidate.provider_id,
      status = "success"
    })
  end

  candidate.route = route
  candidate.validator_results = {}
  for _, component in ipairs(resolved.stages.validators) do
    local component_id = component.definition.id
    local result, component_error = call_component(
      run,
      runtime,
      component_id,
      component.implementation,
      "validate",
      component_context,
      route
    )
    if not result then return nil, component_error end
    local valid, validation_error = validate_contract("validator_result", result)
    if not valid then return nil, validation_error end
    candidate.validator_results[#candidate.validator_results + 1] = result
    append_trace(run, runtime, {
      event = "validate",
      component_id = component_id,
      provider_id = candidate.provider_id,
      status = result.status
    })
  end

  local cost_component = resolved.stages.cost_model
  local cost_result, cost_error = call_component(
    run,
    runtime,
    cost_component.definition.id,
    cost_component.implementation,
    "score",
    component_context,
    route
  )
  if not cost_result then return nil, cost_error end
  local valid, validation_error = validate_contract("cost_result", cost_result)
  if not valid then return nil, validation_error end
  candidate.cost_result = cost_result
  if cost_result.status == "success" then
    route.predicted.distance = cost_result.value
  end
  append_trace(run, runtime, {
    event = "score",
    component_id = cost_component.definition.id,
    provider_id = candidate.provider_id,
    status = cost_result.status
  })
  return candidate
end

local function record_candidate(run, runtime, resolved, candidate)
  local valid, validation_error = validate_contract("candidate", candidate)
  if not valid then return nil, validation_error end
  if candidate.status == "success" then
    candidate, validation_error = process_candidate(run, runtime, resolved, candidate)
    if not candidate then return nil, validation_error end
  end
  run.candidates[#run.candidates + 1] = candidate
  return candidate
end

local function select_route(run, runtime, resolved)
  local evaluations = {}
  for _, candidate in ipairs(run.candidates) do
    if candidate.status == "success" then
      evaluations[#evaluations + 1] = {
        candidate = candidate,
        validator_results = candidate.validator_results,
        cost_result = candidate.cost_result
      }
    end
  end
  local selector = resolved.stages.selector
  local selected, selection_error = call_component(
    run,
    runtime,
    selector.definition.id,
    selector.implementation,
    "select",
    context(run, runtime, resolved),
    evaluations
  )
  if not selected then return fail(run, runtime, selection_error) end
  append_trace(run, runtime, {
    event = "select",
    component_id = selector.definition.id,
    provider_id = selected.candidate.provider_id,
    status = "success"
  })
  return finish(run, runtime, "success", {
    route = copy(selected.candidate.route),
    selected_provider_id = selected.candidate.provider_id,
    selected_source = selected.candidate.route.source
  })
end

local function terminal_candidate(run, runtime, implementation, candidate)
  if candidate.status == "error" then
    return fail(run, runtime, "provider-error", {provider_id = candidate.provider_id})
  end
  if not implementation.required then return nil end
  if candidate.status == "busy" then
    return finish(run, runtime, "busy-retry", {
      provider_id = candidate.provider_id,
      reason = "pathfinder-busy",
      retry_after_ticks = Policy.path_request.busy_retry_ticks
    })
  end
  if candidate.status == "no-path" then
    return finish(run, runtime, "no-path", {
      provider_id = candidate.provider_id,
      reason = "required-provider-no-path"
    })
  end
  return nil
end

local advance

advance = function(run, runtime, resolved)
  while run.status == "running" do
    run.provider_index = run.provider_index + 1
    local component = resolved.stages.candidate_providers[run.provider_index]
    if not component then return select_route(run, runtime, resolved) end

    local provider_id = component.definition.id
    local implementation = component.implementation
    run.current_provider_id = provider_id
    append_trace(run, runtime, {
      event = "provider-start",
      provider_id = provider_id,
      status = "running"
    })

    if implementation.kind == "async" then
      local request_id, request_error = call_component(
        run,
        runtime,
        provider_id,
        implementation,
        "request",
        context(run, runtime, resolved)
      )
      if not request_id then return fail(run, runtime, request_error, {provider_id = provider_id}) end
      run.pending_request_id = request_id
      run.pending_provider_id = provider_id
      run.request_count = run.request_count + 1
      append_trace(run, runtime, {
        event = "provider-request",
        provider_id = provider_id,
        request_ordinal = run.request_count,
        status = "pending"
      })
      if runtime.on_request then
        runtime.on_request(request_id, {
          provider_id = provider_id,
          request_ordinal = run.request_count,
          run_id = run.id
        }, run)
      end
      return {status = "pending", request_id = request_id, provider_id = provider_id}
    end

    if implementation.kind ~= "sync" then
      return fail(run, runtime, "unsupported-provider-kind", {provider_id = provider_id})
    end
    local candidate, provider_error = call_component(
      run,
      runtime,
      provider_id,
      implementation,
      "provide",
      context(run, runtime, resolved)
    )
    if not candidate then return fail(run, runtime, provider_error, {provider_id = provider_id}) end
    append_trace(run, runtime, {
      event = "provider-result",
      provider_id = provider_id,
      status = candidate.status
    })
    local recorded, record_error = record_candidate(run, runtime, resolved, candidate)
    if not recorded then return fail(run, runtime, record_error, {provider_id = provider_id}) end
    local terminal = terminal_candidate(run, runtime, implementation, recorded)
    if terminal then return terminal end
  end
  return run.terminal_result
end

function PlanningRun.start(profile_reference, specification, runtime)
  specification = specification or {}
  runtime = runtime or {}
  local preflight, preflight_error = ProfileResolver.preflight(profile_reference)
  if not preflight then return nil, preflight_error end

  local provider_order = {}
  for _, provider in ipairs(preflight.stages.candidate_providers) do
    provider_order[#provider_order + 1] = provider.id
  end
  local run = {
    schema_version = Contracts.VERSION,
    id = specification.id,
    command_id = specification.command_id,
    adapter_id = specification.adapter_id or "unspecified",
    profile_reference = copy(profile_reference),
    start_position = PathMath.copy_position(specification.start_position),
    goal_position = PathMath.copy_position(specification.goal_position),
    reason = specification.reason or "unspecified",
    started_tick = tick(runtime),
    provider_order = provider_order,
    provider_index = 0,
    current_provider_id = nil,
    pending_request_id = nil,
    pending_provider_id = nil,
    request_count = 0,
    candidates = {},
    trace = {},
    status = "running",
    terminal_result = nil
  }
  append_trace(run, runtime, {
    event = "run-start",
    profile_id = profile_reference.profile_id,
    status = "running"
  })

  local resolved, resolution_error = resolve(run)
  if not resolved then
    return run, fail(run, runtime, resolution_error.message or "profile-resolution-failed")
  end
  return run, advance(run, runtime, resolved)
end

function PlanningRun.handle_result(run, event, runtime)
  runtime = runtime or {}
  if not run or run.status ~= "running" then
    return planning_result(run or {
      id = nil,
      adapter_id = "unknown",
      profile_reference = {profile_id = "unknown"},
      provider_order = {},
      trace = {},
      candidates = {},
      request_count = 0,
      started_tick = tick(runtime)
    }, "stale", {
      reason = "run-not-active",
      finished_tick = tick(runtime)
    })
  end
  if not run.pending_request_id or event.id ~= run.pending_request_id then
    append_trace(run, runtime, {
      event = "provider-result",
      provider_id = run.pending_provider_id,
      status = "stale"
    })
    return planning_result(run, "stale", {
      reason = "request-id-mismatch",
      finished_tick = tick(runtime)
    })
  end

  local resolved, resolution_error = resolve(run)
  if not resolved then return fail(run, runtime, resolution_error.message or "profile-resolution-failed") end
  local component = resolved.stages.candidate_providers[run.provider_index]
  if not component or component.definition.id ~= run.pending_provider_id then
    return fail(run, runtime, "pending-provider-mismatch")
  end

  local provider_id = run.pending_provider_id
  run.pending_request_id = nil
  run.pending_provider_id = nil
  local candidate, provider_error = call_component(
    run,
    runtime,
    provider_id,
    component.implementation,
    "handle_result",
    context(run, runtime, resolved),
    event
  )
  if not candidate then return fail(run, runtime, provider_error, {provider_id = provider_id}) end
  append_trace(run, runtime, {
    event = "provider-result",
    provider_id = provider_id,
    status = candidate.status
  })
  local recorded, record_error = record_candidate(run, runtime, resolved, candidate)
  if not recorded then return fail(run, runtime, record_error, {provider_id = provider_id}) end
  local terminal = terminal_candidate(run, runtime, component.implementation, recorded)
  if terminal then return terminal end
  return advance(run, runtime, resolved)
end

function PlanningRun.cancel(run, reason, runtime)
  if not run or run.status ~= "running" then return run and run.terminal_result or nil end
  return finish(run, runtime or {}, "cancelled", {reason = reason or "cancelled"})
end

function PlanningRun.provider_trace(run)
  local trace = {}
  for _, entry in ipairs(run.trace or {}) do
    if entry.event == "provider-start"
        or entry.event == "provider-request"
        or entry.event == "provider-result"
        or entry.event == "terminal" then
      trace[#trace + 1] = {
        event = entry.event,
        provider_id = entry.provider_id,
        status = entry.status
      }
    end
  end
  return trace
end

return PlanningRun
