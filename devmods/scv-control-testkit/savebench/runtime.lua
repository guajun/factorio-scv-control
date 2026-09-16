local Catalog = require("savebench.catalog")
local Adapters = require("savebench.adapters")
local Facts = require("savebench.facts")
local WireJson = require("__factorio-scv-control__/scripts/navigation/wire_json")

local Runtime = {PROTOCOL = "scv-savebench/1"}
local RESULT_PATH = "scv-control/savebench/result.json"
local FACTS_PATH = "scv-control/savebench/facts.json"
local PERFORMANCE_PATH = "scv-control/savebench/performance.jsonl"

-- These observations never make simulation decisions. A joining multiplayer
-- peer loads Lua anew; using either value as admission state would desync it.
local loaded_from_save, runtime_build_calls = false, 0
local hook_profiles = {}

local function lab_enabled() return remote.interfaces.scv_unified_lab ~= nil end
local function enabled() return remote.interfaces.scv_navigation_savebench ~= nil or lab_enabled() end
local function point(p) return {x = p.x, y = p.y} end
local function error_reply(reason) return {ok = false, protocol = Runtime.PROTOCOL, reason = reason} end
local function json(value) return assert(WireJson.encode(value)) end
local function saved_state() return storage.scv_navigation_savebench end

local function status()
  local state = saved_state()
  local prepared = state and state.prepared
  local result = state and state.result
  return {ok = true, protocol = Runtime.PROTOCOL, state = state and state.phase or "idle",
    case_id = prepared and prepared.descriptor.id or false,
    domain = prepared and prepared.descriptor.domain or false,
    fixture_version = prepared and prepared.descriptor.fixture_version or false,
    source_facts_hash = state and state.source_facts_hash or false,
    source_verified = state and state.source_verified == true,
    actor_position = prepared and prepared.actor.valid and point(prepared.actor.position) or false,
    surface = prepared and prepared.surface.valid and prepared.surface.name or false,
    game_tick = game.tick, paused = game.tick_paused, ticks_to_run = game.ticks_to_run,
    loaded_from_save = loaded_from_save, runtime_build_calls = runtime_build_calls,
    derived_compile_calls = prepared and prepared.derived_compile_calls or 0,
    reason = state and state.reason or false,
    report_path = result and RESULT_PATH or false,
    performance_path = state and state.run_started_tick and PERFORMANCE_PATH or false,
    result = result and {id = result.id, passed = result.passed,
      terminal_state = result.terminal_state, reason = result.reason,
      assertion_count = #result.assertions} or false}
end

local function profile(name, callback)
  local timer = game.create_profiler()
  local ok, value = pcall(callback)
  timer.stop()
  local aggregate = hook_profiles[name]
  if not aggregate then
    aggregate = {timer = game.create_profiler(true), count = 0}
    hook_profiles[name] = aggregate
  end
  aggregate.timer.add(timer)
  aggregate.count = aggregate.count + 1
  -- LuaProfiler intentionally has no readable numeric time. Localization on
  -- the authoritative server writes its actual duration; host tooling parses
  -- it. Timing objects/values never enter storage or the canonical world facts.
  helpers.write_file(PERFORMANCE_PATH, {"", '{"kind":"hook","hook":"', name,
    '","tick":', game.tick, ',"duration":"', timer, '"}\n'}, true, 0)
  if not ok then error(value) end
  return value
end

local function finish_profile()
  for _, name in ipairs({"begin", "on_tick", "path_result", "script_raised_built", "script_raised_destroy"}) do
    local item = hook_profiles[name]
    if item then
      helpers.write_file(PERFORMANCE_PATH, {"", '{"kind":"aggregate","hook":"', name,
        '","count":', item.count, ',"duration":"', item.timer, '"}\n'}, true, 0)
    end
  end
end

local function capture(prepared)
  local case = prepared.descriptor
  return Facts.capture(prepared.surface, prepared.actor, case.bounds,
    {case_id = case.id, domain = case.domain, fixture_version = case.fixture_version,
      start = case.start, goal = case.goal, scenario = "navigation-savebench",
      state_key = "baseline", scope = case.scope})
end

local function finish(state, result)
  if state.result then return end
  Adapters.stop(state.prepared)
  state.result = result
  state.phase, state.reason = result.passed and "complete" or "failed", result.reason
  state.completed_tick = game.tick
  game.tick_paused, game.ticks_to_run = true, 0
  local report = {protocol = Runtime.PROTOCOL, schema_version = 1,
    case_id = state.prepared.descriptor.id, domain = state.prepared.descriptor.domain,
    fixture_version = state.prepared.descriptor.fixture_version,
    factorio_version = script.active_mods.base,
    source_facts_hash = state.source_facts_hash, source_verified = state.source_verified == true,
    loaded_from_save = loaded_from_save, runtime_build_calls = runtime_build_calls,
    derived_compile_calls = state.prepared.derived_compile_calls or 0,
    run_started_tick = state.run_started_tick, completed_tick = game.tick,
    duration_ticks = state.run_started_tick and game.tick - state.run_started_tick or 0,
    result = result, performance_path = PERFORMANCE_PATH}
  helpers.write_file(RESULT_PATH, json(report), false, 0)
  finish_profile()
  log("SCV_SAVEBENCH_COMPLETE case=" .. report.case_id .. " passed=" .. tostring(result.passed))
  for _, player in pairs(game.connected_players) do
    player.print("Savebench " .. report.case_id .. ": " .. result.terminal_state
      .. (result.passed and " (passed)" or " (failed)") .. ". Reload the source save to repeat.")
  end
end

local function fail(state, reason)
  if not state or not state.prepared then return error_reply(reason) end
  finish(state, {id = state.prepared.descriptor.id, passed = false, terminal_state = "failed",
    reason = reason, assertions = {{name = "save-source-execution", passed = false, details = reason}},
    metrics = {}, timeline = {{tick = game.tick, event = "runtime-failed", reason = reason}}})
  return status()
end

local function annotate(prepared)
  local case, surface = prepared.descriptor, prepared.surface
  rendering.draw_circle({color = {r = 0.2, g = 1, b = 0.4}, radius = 0.55, width = 3,
    target = case.start, surface = surface})
  rendering.draw_circle({color = {r = 0.2, g = 0.8, b = 1}, radius = 0.55, width = 3,
    target = case.goal, surface = surface})
  rendering.draw_text({text = "START", color = {r = 0.2, g = 1, b = 0.4},
    target = {x = case.start.x, y = case.start.y - 1.2}, alignment = "center", surface = surface})
  rendering.draw_text({text = "GOAL", color = {r = 0.2, g = 0.8, b = 1},
    target = {x = case.goal.x, y = case.goal.y - 1.2}, alignment = "center", surface = surface})
  rendering.draw_text({text = case.domain .. " / " .. case.id .. "\n/scv-savebench run | pause | status",
    color = {r = 1, g = 1, b = 1}, target = {x = case.bounds.left_top.x + 1, y = case.bounds.left_top.y + 1},
    surface = surface})
end

local function watch(player)
  -- The unified hub is responsible for player controller/camera ownership.
  if lab_enabled() then return end
  local state = saved_state()
  local prepared = state and state.prepared
  if not prepared then return end
  player.set_controller({type = defines.controllers.spectator})
  player.teleport(prepared.actor.position, prepared.surface)
  player.zoom = 0.9
  player.force.chart(prepared.surface, prepared.descriptor.bounds)
  player.print("This is the saved native map for " .. prepared.descriptor.id
    .. ". It starts paused. /scv-savebench run executes it; /scv-savebench pause freezes it."
    .. " Reload the save to restore the same source entities.")
end

local function prepare(state, id, lab_sequence)
  if state.phase ~= "idle" then return error_reply("prepare-requires-fresh-marker-map") end
  local case = Catalog.get(id)
  if not case then return error_reply("unknown-case") end
  game.tick_paused, game.ticks_to_run = true, 0
  runtime_build_calls = runtime_build_calls + 1
  state.prepared = Adapters.prepare(case, lab_sequence or runtime_build_calls)
  state.actor_origin = point(state.prepared.actor.position)
  local facts, detail = capture(state.prepared)
  if not facts then return fail(state, "source-capture-failed:" .. detail.code .. ":" .. detail.message) end
  state.source_facts_hash, state.prepared_tick, state.phase = facts.facts_hash, game.tick, "prepared"
  annotate(state.prepared)
  for _, player in pairs(game.connected_players) do watch(player) end
  return status()
end

function Runtime.lab_release()
  if not lab_enabled() then return error_reply('unified-lab-required') end
  local s = saved_state()
  if not s then
    storage.scv_navigation_savebench = {phase = 'idle', schema_version = 1, lab_sequence = 0, lab_owned_surfaces = {}}
    return status()
  end
  local prepared, surface = s.prepared, s.prepared and s.prepared.surface
  local cleanup
  if surface and surface.valid then
    local domain = prepared.descriptor.domain
    local expected_name = domain == 'gate-actions' and ('scv-gate-actions-' .. tostring(s.lab_sequence))
      or domain == 'dynamic' and 'scv-navigation-episodes'
      or domain == 'belt-controller' and 'scv-belt-controller'
    if not s.lab_owned_surface_index or s.lab_owned_surface_index ~= surface.index
      or surface.name ~= expected_name then return error_reply('lab-surface-not-owned') end
    for _, player in pairs(game.players) do
      if player.valid and player.surface == surface then return error_reply('lab-scene-has-player') end
      if player.valid and player.character and player.character.valid and player.character.surface == surface then
        return error_reply('lab-scene-has-player-character')
      end
    end
  end
  game.tick_paused, game.ticks_to_run = true, 0
  if prepared then
    Adapters.stop(prepared)
    if prepared.actor and prepared.actor.valid then prepared.actor.destroy() end
  end
  if surface and surface.valid then
    for _, object in pairs(rendering.get_all_objects()) do
      if object.valid and object.surface == surface then object.destroy() end
    end
    if prepared.descriptor.domain == 'gate-actions' then
      local name, index = surface.name, surface.index
      if not game.delete_surface(surface) then return error_reply('lab-owned-gate-surface-delete-failed') end
      -- Factorio queues surface deletion for the next native update. Do not
      -- claim that its LuaSurface becomes invalid during this paused command.
      cleanup = {gate_surface_deletion_queued = true, surface_name = name, surface_index = index}
    end
  end
  storage.scv_navigation_savebench = {phase = 'idle', schema_version = 1, lab_sequence = s.lab_sequence or 0,
    lab_owned_surfaces = s.lab_owned_surfaces or {}}
  hook_profiles = {}
  helpers.write_file(PERFORMANCE_PATH, '', false, 0)
  local response = status()
  response.cleanup = cleanup
  return response
end

function Runtime.lab_select(id)
  if not lab_enabled() then return error_reply('unified-lab-required') end
  local case = Catalog.get(id)
  if not case then return error_reply('unknown-case') end
  local target_name = case.domain == 'dynamic' and 'scv-navigation-episodes'
    or case.domain == 'belt-controller' and 'scv-belt-controller'
  local target = target_name and game.get_surface(target_name)
  local current = saved_state()
  if target and (not current or not current.lab_owned_surfaces
    or current.lab_owned_surfaces[target_name] ~= target.index) then return error_reply('lab-surface-not-owned') end
  local released = Runtime.lab_release()
  if not released.ok then return released end
  local s = saved_state()
  local sequence = (s.lab_sequence or 0) + 1
  -- Never reuse a process-local counter after save/load, or delete an unrelated
  -- surface merely because its name collides with the next generated name.
  while game.get_surface('scv-gate-actions-' .. sequence) do sequence = sequence + 1 end
  s.lab_sequence = sequence
  local response = prepare(s, id, sequence)
  response.cleanup = released.cleanup
  if s.prepared and s.prepared.surface.valid then
    s.lab_owned_surface_index = s.prepared.surface.index
    s.lab_owned_surfaces = s.lab_owned_surfaces or {}
    if target_name then s.lab_owned_surfaces[target_name] = s.prepared.surface.index end
  end
  return response
end

function Runtime.lab_actor()
  if not lab_enabled() then return nil end
  local s = saved_state()
  local actor = s and s.prepared and s.prepared.actor
  return actor and actor.valid and actor or nil
end

function Runtime.lab_suspend()
  if not lab_enabled() then return error_reply('unified-lab-required') end
  local s = saved_state()
  if not s or not s.prepared then return error_reply('source-required') end
  Adapters.stop(s.prepared)
  s.phase = 'manual'
  return status()
end

function Runtime.lab_result()
  if not lab_enabled() then return nil end
  local s = saved_state()
  return s and s.result or nil
end

local function run(state)
  if state.phase == "running" then game.tick_paused = false; return status() end
  if state.phase ~= "prepared" then return error_reply("run-requires-prepared-source-save") end
  if not game.tick_paused or game.ticks_to_run ~= 0 then return error_reply("source-must-be-paused") end
  local prepared = state.prepared
  if not prepared.actor.valid or not prepared.surface.valid then return fail(state, "saved-actor-or-surface-missing") end
  local position = prepared.actor.position
  if position.x ~= state.actor_origin.x or position.y ~= state.actor_origin.y then
    return fail(state, "saved-actor-origin-changed")
  end
  local facts, detail = capture(prepared)
  if not facts then return fail(state, "source-recapture-failed:" .. detail.code .. ":" .. detail.message) end
  if facts.facts_hash ~= state.source_facts_hash then return fail(state, "source-facts-changed") end
  state.source_verified, state.phase, state.run_started_tick = true, "running", game.tick
  state.last_update_tick = game.tick
  game.speed = 1
  hook_profiles = {}
  helpers.write_file(PERFORMANCE_PATH, "", false, 0)
  local ok, result = pcall(function()
    return profile("begin", function()
      Adapters.begin(prepared, game.tick)
      -- Issue the first native command while paused, at the saved actor origin.
      -- This avoids uncommanded belt drift between loading and the first tick.
      return Adapters.update(prepared, game.tick)
    end)
  end)
  if not ok then return fail(state, "begin-error:" .. tostring(result)) end
  if result then finish(state, result) else game.tick_paused = false end
  return status()
end

function Runtime.dispatch(message)
  if not enabled() then return error_reply("savebench-map-required") end
  if type(message) ~= "table" or (message.protocol and message.protocol ~= Runtime.PROTOCOL) then
    return error_reply("unsupported-protocol")
  end
  local operation, state = message.operation, saved_state()
  if operation == "catalog" then
    return {ok = true, protocol = Runtime.PROTOCOL, fixture_version = Catalog.VERSION,
      case_count = #Catalog.cases, cases = Catalog.describe()}
  end
  if operation == "status" then return status() end
  if not state then return error_reply("runtime-not-initialized") end
  if operation == "prepare" then return prepare(state, message.id) end
  if operation == "run" then return run(state) end
  if operation == "pause" then game.tick_paused, game.ticks_to_run = true, 0; return status() end
  if operation == "facts" then
    if not state.prepared then return error_reply("no-prepared-source") end
    local facts, detail = capture(state.prepared)
    if not facts then return error_reply("capture-failed:" .. detail.code .. ":" .. detail.message) end
    local data = json(facts)
    helpers.write_file(FACTS_PATH, data, false, 0)
    return {ok = true, protocol = Runtime.PROTOCOL, path = FACTS_PATH,
      bytes = #data, facts_hash = facts.facts_hash, source_facts_hash = state.source_facts_hash}
  end
  if operation == "save" then
    if state.phase ~= "prepared" or not game.tick_paused or game.ticks_to_run ~= 0 then
      return error_reply("only-paused-prepared-source-may-be-published")
    end
    if type(message.name) ~= "string" or #message.name > 128
        or not message.name:match("^[%w][%w_-]*$") then return error_reply("invalid-save-name") end
    game.server_save(message.name)
    return {ok = true, protocol = Runtime.PROTOCOL, filename = message.name .. ".zip",
      case_id = state.prepared.descriptor.id, source_facts_hash = state.source_facts_hash}
  end
  return error_reply("unknown-operation")
end

function Runtime.on_init()
  if not enabled() then return end
  storage.scv_navigation_savebench = {phase = "idle", schema_version = 1}
  game.tick_paused, game.ticks_to_run = true, 0
end

function Runtime.on_load()
  loaded_from_save = true
  -- Never change storage or the engine clock from on_load. A saved source is
  -- already paused; joining clients must inherit the server's synchronized state.
end

function Runtime.add_commands()
  if not enabled() then return end
  commands.add_command("scv-savebench-agent", "Local save-backed native test protocol.", function(command)
    if command.player_index then
      game.get_player(command.player_index).print("Use /scv-savebench run | pause | status.")
      return
    end
    local text = command.parameter or ""
    local response
    if #text > 20000 then response = error_reply("command-byte-limit")
    else
      local decoded_ok, message = pcall(helpers.json_to_table, text)
      if not decoded_ok or type(message) ~= "table" then response = error_reply("invalid-json")
      else
        local ok, value = pcall(Runtime.dispatch, message)
        response = ok and value or error_reply("handler-error:" .. tostring(value))
      end
    end
    rcon.print(json(response))
  end)
  commands.add_command("scv-savebench", "Inspect and run the saved source map: status | run | pause.", function(command)
    if not command.player_index then return end
    local player = game.get_player(command.player_index)
    local operation = command.parameter or "status"
    if operation ~= "status" and operation ~= "run" and operation ~= "pause" then
      player.print("/scv-savebench status | run | pause. Reload this save to repeat the original case.")
      return
    end
    local ok, value = pcall(Runtime.dispatch, {operation = operation})
    player.print(json(ok and value or error_reply("handler-error:" .. tostring(value))))
  end)
end

local function tick(event)
  if not enabled() then return end
  local state = saved_state()
  if not state or state.phase ~= "running" then return end
  -- A paused RCON command can arm movement before on_tick for that same tick.
  -- It has not had a native entity update yet; sampling twice would report a
  -- fictitious zero-speed collision and query a gate mid-request transition.
  if state.last_update_tick and event.tick <= state.last_update_tick then return end
  state.last_update_tick = event.tick
  local ok, result = pcall(function()
    return profile("on_tick", function() return Adapters.update(state.prepared, event.tick) end)
  end)
  if not ok then fail(state, "tick-error:" .. tostring(result))
  elseif result then finish(state, result) end
end

local function path_result(event)
  if not enabled() then return end
  local state = saved_state()
  if not state or state.phase ~= "running" then return end
  local ok, result = pcall(function()
    return profile("path_result", function() return Adapters.path_result(state.prepared, event) end)
  end)
  if not ok then fail(state, "path-result-error:" .. tostring(result))
  elseif result then finish(state, result) end
end

local function mutation(name, event)
  if not enabled() then return end
  local state = saved_state()
  if not state or state.phase ~= "running" then return end
  -- The callback remains synchronous: an on-route wall edit stops the actor
  -- in the native entity event before the next physical movement update.
  profile(name, function() Adapters.entity_event(state.prepared, name, event) end)
end

Runtime.events = {
  [defines.events.on_tick] = tick,
  [defines.events.on_script_path_request_finished] = path_result,
  [defines.events.script_raised_built] = function(event) mutation("script_raised_built", event) end,
  [defines.events.script_raised_destroy] = function(event) mutation("script_raised_destroy", event) end,
  [defines.events.on_player_created] = function(event)
    if enabled() then watch(game.get_player(event.player_index)) end
  end,
  [defines.events.on_player_joined_game] = function(event)
    if enabled() then watch(game.get_player(event.player_index)) end
  end
}

Runtime.active = enabled
return Runtime
