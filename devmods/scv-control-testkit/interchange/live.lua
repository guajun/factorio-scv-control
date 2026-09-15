local Capture = require("interchange.capture")
local Replay = require("interchange.replay")
local Fixtures = require("pathfinding.fixtures")
local PlanningRun = require("__factorio-scv-control__/scripts/navigation/planning_run")
local Follower = require("__factorio-scv-control__/scripts/follower")
local WireJson = require("__factorio-scv-control__/scripts/navigation/wire_json")

local Live = {PROTOCOL = "scv-navigation/1", CHUNK_BYTES = 3000}
local MAX_UPLOAD = 1024 * 1024
local WORK_FILE = "scv-control/navigation/live-work.json"
local WAIT_TICKS = 36000 -- transport failure guard; host uses a separate wall clock watchdog

local function enabled()
  return remote.interfaces.scv_test_interactive ~= nil or remote.interfaces.scv_navigation_live ~= nil
end

local function error_reply(reason) return {ok = false, reason = reason} end
local function point(value) return {x = value.x, y = value.y} end
local function ascii_json_bytes(value)
  -- The initial fixtures use ASCII prototype IDs; reject instead of splitting an
  -- unsupported UTF-8 sequence across RCON replies in this protocol profile.
  return not value:find("[\128-\255]")
end
local function integer(value, minimum, maximum)
  return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= maximum
end

local function summary(state)
  local request = state.request
  local result = {ok = true, protocol = Live.PROTOCOL, session_id = state.session_id}
  if request then
    result.request_token, result.status, result.fixture_id = request.token, request.status, request.fixture_id
    result.bytes = request.work and #request.work or 0
    result.chunks = request.work and math.ceil(#request.work / Live.CHUNK_BYTES) or 0
    result.query_id = request.session and request.session.query.query_id
    result.query_hash = request.session and request.session.query.query_hash
    if request.status == "pending" and request.work_file then
      result.transfer = {kind = "script-output-file-v1", path = request.work_file,
        bytes = #request.work, request_token = request.token, session_id = state.session_id,
        query_id = result.query_id, query_hash = result.query_hash,
        snapshot_hash = request.session.query.data_ref.snapshot_hash}
    end
    result.reason = request.reason
    result.committed = request.committed == true
    result.admission_count = request.admission_count or 0
    if request.status == "arrived" or request.status == "rejected" or request.status == "failed"
        or request.status == "cancelled" then
      result.terminal = {status = request.status, reason = request.reason}
      if request.session then
        result.terminal.actual_travel_ticks = request.session.actual_travel_ticks
        result.terminal.arrival_error = request.session.arrival_error
        result.terminal.execution_arrival_tolerance = request.session.execution_arrival_tolerance
        result.terminal.actual_distance = request.session.actual_distance
        result.terminal.direction_switches = request.session.direction_switches
      end
    end
  else result.status = "idle" end
  return result
end

local function stop_request(request, reason)
  if not request then return end
  local session = request.session
  if session then
    if session.actor and session.actor.valid then Follower.stop(session.actor) end
    if session.planning_run and session.planning_run.status == "running" then
      PlanningRun.cancel(session.planning_run, reason, {tick = game.tick})
    end
  end
  request.status, request.reason = "cancelled", reason
  request.work, request.upload = nil, nil
end

local function restore_player()
  local view = storage.scv_navigation_live_view
  if not view then return end
  local player = game.get_player(view.player_index)
  if player then
    if view.character and view.character.valid then
      player.set_controller({type = defines.controllers.character, character = view.character})
    else
      player.set_controller({type = defines.controllers.spectator})
      player.teleport(view.position, view.surface)
    end
  end
  storage.scv_navigation_live_view = nil
end

local function watch_request(request)
  if not request.player_index then return end
  local player = game.get_player(request.player_index)
  if not player then return end
  restore_player()
  storage.scv_navigation_live_view = {player_index = player.index, character = player.character,
    position = player.position, surface = player.surface}
  player.set_controller({type = defines.controllers.spectator})
  player.teleport(request.session.query.start, request.session.surface)
  player.print("External solver pending. /scv-nav-live return restores your character.")
end

local function begin(state, fixture_id, player_index)
  if not Fixtures.get(fixture_id) then return error_reply("unknown-fixture") end
  if state.request and not summary(state).terminal then return error_reply("request-active") end
  restore_player()
  state.sequence = state.sequence + 1
  state.request = {fixture_id = fixture_id, token = state.session_id .. ":request:" .. state.sequence,
    status = "queued", queued_tick = game.tick, upload = {}, upload_bytes = 0,
    upload_next_index = 1, player_index = player_index}
  return summary(state)
end

local function runtime(request)
  local session = request.session
  return {surface = session.surface, actor = session.actor, tick = game.tick,
    navigation_data_ref = session.query.data_ref, navigation_snapshot = session.snapshot,
    request_solver = function() return request.token end}
end

local function prepare(state, request)
  local snapshot, query, actor = Capture.fixture(request.fixture_id, {
    session_id = state.session_id, query_id = request.token .. ":query",
    command_id = tostring(state.sequence), attempt_id = "1",
    snapshot_id = request.token .. ":snapshot", backend_session_id = request.token,
    surface_name = "scv-navigation-live", keep_actor = true
  })
  if not snapshot then request.status, request.reason = "failed", query.code; return end
  -- Capture and execution share this exact actor/surface incarnation. Only the
  -- accepted-route/follower adapter is reused from offline replay.
  local session = {surface = actor.surface, actor = actor, case_id = request.fixture_id,
    snapshot = snapshot, query = query, result = {}, status = "prepared", started_tick = game.tick,
    max_ticks = 3600, actual_distance = 0, direction_switches = 0, max_cross_track_error = 0,
    last_position = point(actor.position)}
  request.session = session
  local run, progress = PlanningRun.start({schema_version = 1, profile_id = "external-distance-v1", values = {}}, {
    id = query.query_id, command_id = query.command_id, adapter_id = "live-rcon-testkit-v1",
    reason = "live-external", start_position = query.start, goal_position = query.goal,
    navigation_query = query
  }, runtime(request))
  session.planning_run = run
  if not run or not progress or progress.status ~= "pending" then
    request.status, request.reason = "failed", progress and (progress.reason or progress.message) or "planning-start-failed"
    return
  end
  local work, work_error = WireJson.encode({protocol = Live.PROTOCOL, kind = "live-work",
    request_token = request.token, id = request.fixture_id, snapshot = snapshot, query = query})
  if not work then request.status, request.reason = "failed", work_error.code; return end
  if not ascii_json_bytes(work) then request.status, request.reason = "failed", "non-ascii-fixture-transport"; return end
  -- Bulk data never traverses the synchronized command stream in file mode.
  -- Publish the descriptor only after writing completes, and only write on the
  -- authoritative server. The single-slot file is correlated by the full token
  -- and hashes, so an old reader cannot accept a newer request's contents.
  if state.snapshot_transport == "file" then
    helpers.write_file(WORK_FILE, work, false, 0)
    request.work_file = WORK_FILE
  end
  request.work, request.status, request.pending_tick = work, "pending", game.tick
  watch_request(request)
end

function Live.dispatch(message)
  if not enabled() then return error_reply("test-map-required") end
  if type(message) ~= "table" or message.protocol ~= Live.PROTOCOL then return error_reply("unsupported-protocol") end
  local operation = message.operation
  if operation == "capabilities" then
    local state = storage.scv_navigation_live
    if message.nonce then
      local transport = message.snapshot_transport or (state and state.snapshot_transport) or "file"
      if transport ~= "file" and transport ~= "rcon" then return error_reply("unsupported-snapshot-transport") end
      if type(message.nonce) ~= "string" or #message.nonce < 8 or #message.nonce > 128
          or not message.nonce:match("^[%w_-]+$") then return error_reply("invalid-session-nonce") end
      if not state or state.nonce ~= message.nonce then
        if state then stop_request(state.request, "session-replaced") end
        restore_player()
        state = {nonce = message.nonce, session_id = "live:" .. message.nonce, sequence = 0,
          snapshot_transport = transport}
        storage.scv_navigation_live = state
      elseif state.snapshot_transport ~= transport then
        return error_reply("transport-change-requires-fresh-session")
      end
    end
    local result = state and summary(state) or {ok = true, protocol = Live.PROTOCOL, status = "disconnected"}
    result.handshake_required, result.chunk_bytes, result.max_upload_bytes = not state, Live.CHUNK_BYTES, MAX_UPLOAD
    result.capabilities = {"bounded-static-fixtures", "distance", "external-provider", "native-follower", "gui-spectator"}
    result.snapshot_transports = {"file", "rcon"}
    result.snapshot_transport = state and state.snapshot_transport
    return result
  end
  local state = storage.scv_navigation_live
  if not state then return error_reply("session-handshake-required") end
  if message.session_id ~= state.session_id then return error_reply("stale-session") end
  if operation == "begin" then return begin(state, message.fixture_id) end
  if operation == "poll" then
    if message.request_token and (not state.request or message.request_token ~= state.request.token) then return error_reply("stale-request") end
    return summary(state)
  end
  local request = state.request
  if not request or message.request_token ~= request.token then return error_reply("stale-request") end
  if operation == "cancel" then
    if summary(state).terminal then return error_reply("request-already-terminal") end
    stop_request(request, "host-cancelled")
    return summary(state)
  end
  if operation == "download" then
    if request.status ~= "pending" then return error_reply("request-not-pending") end
    if not integer(message.offset, 0, #request.work)
        or not integer(message.max_bytes or Live.CHUNK_BYTES, 1, Live.CHUNK_BYTES) then return error_reply("invalid-download-range") end
    local last = math.min(#request.work, message.offset + (message.max_bytes or Live.CHUNK_BYTES))
    return {ok = true, session_id = state.session_id, request_token = request.token,
      offset = message.offset, data = request.work:sub(message.offset + 1, last),
      next_offset = last, eof = last == #request.work, bytes = #request.work}
  end
  if request.committed then return error_reply("duplicate-result") end
  if request.status ~= "pending" then return error_reply("request-not-pending") end
  if operation == "upload" then
    if not integer(message.index, 1, math.ceil(MAX_UPLOAD / Live.CHUNK_BYTES))
        or type(message.data) ~= "string" or #message.data == 0 or #message.data > Live.CHUNK_BYTES
        or message.data:find("[^\1-\127]") then return error_reply("invalid-upload-chunk") end
    if message.index < request.upload_next_index then
      if request.upload[message.index] == message.data then return {ok = true, duplicate = true, next_index = request.upload_next_index} end
      return error_reply("conflicting-upload-duplicate")
    end
    if message.index ~= request.upload_next_index then return error_reply("out-of-order-upload") end
    if request.upload_bytes + #message.data > MAX_UPLOAD then return error_reply("upload-byte-limit") end
    request.upload[message.index], request.upload_next_index = message.data, message.index + 1
    request.upload_bytes = request.upload_bytes + #message.data
    return {ok = true, next_index = request.upload_next_index, bytes = request.upload_bytes}
  end
  if operation == "commit" then
    if request.upload_bytes == 0 then return error_reply("empty-upload") end
    if message.total_chunks and message.total_chunks ~= request.upload_next_index - 1 then return error_reply("incomplete-upload") end
    local parsed, result = pcall(helpers.json_to_table, table.concat(request.upload))
    request.committed, request.upload = true, nil
    if not parsed or type(result) ~= "table" then
      request.status, request.reason = "rejected", "invalid-result-json"
      PlanningRun.fail_pending(request.session.planning_run, request.reason, runtime(request))
      return summary(state)
    end
    local session = request.session
    session.result = result
    local progress = PlanningRun.handle_solver_result(session.planning_run,
      {id = request.token, provider_id = "external-route", result = result}, runtime(request))
    request.admission_count = (request.admission_count or 0) + 1
    Replay.activate(session, session.planning_run, progress)
    request.status, request.reason = session.status, session.reason
    request.work = nil
    Replay.draw(session, request.player_index)
    return summary(state)
  end
  return error_reply("unknown-operation")
end

function Live.add_commands()
  if not enabled() then return end
  commands.add_command("scv-nav-agent", "Bounded JSON RPC for a local external solver on the TestKit map.", function(command)
    if command.player_index then game.get_player(command.player_index).print("Use /scv-nav-live for GUI tests."); return end
    local payload = command.parameter or ""
    local reply
    if #payload > 20000 then reply = error_reply("command-byte-limit")
    else
      local valid, decoded = pcall(helpers.json_to_table, payload)
      if not valid or type(decoded) ~= "table" then reply = error_reply("invalid-json")
      else
        local ok, result = pcall(Live.dispatch, decoded)
        reply = ok and result or error_reply("handler-error:" .. tostring(result))
      end
    end
    rcon.print(assert(WireJson.encode(reply)))
  end)
  commands.add_command("scv-nav-live", "Real-time external solver test: fixture-id | status | return", function(command)
    if not command.player_index then return end
    local player = game.get_player(command.player_index)
    local parameter = command.parameter or "status"
    if parameter == "return" then restore_player(); return end
    local state = storage.scv_navigation_live
    if not state then player.print("Start the host RCON solver service for this test-map session first."); return end
    if parameter == "status" then player.print(assert(WireJson.encode(summary(state)))); return end
    local result = begin(state, parameter, player.index)
    player.print(result.ok and "Queued external solver fixture " .. parameter or result.reason)
  end)
end

-- All admission state is synchronized storage. on_load also runs on a newly
-- joining multiplayer peer: a Lua-local "needs handshake" flag would make that
-- peer cancel a request which the server is still executing, causing a desync.
-- The authoritative host rotates the nonce through a synchronized command on
-- reconnect; no peer invents a session transition merely because it loaded.

Live.events = {[defines.events.on_tick] = function(event)
  if not enabled() then return end
  local state = storage.scv_navigation_live
  local request = state and state.request
  if not request then return end
  if request.status == "queued" then
    local ok, detail = pcall(prepare, state, request)
    if not ok then request.status, request.reason = "failed", "capture-error:" .. tostring(detail) end
  elseif request.status == "pending" and event.tick - request.pending_tick > WAIT_TICKS then
    request.status, request.reason = "failed", "solver-transport-timeout"
    PlanningRun.fail_pending(request.session.planning_run, request.reason, runtime(request))
  elseif request.status == "moving" then
    Replay.update(request.session, event.tick)
    request.status, request.reason = request.session.status, request.session.reason
  end
  if (request.status == "arrived" or request.status == "failed" or request.status == "rejected") and not request.reported then
    request.reported = true
    local report = request.session and Replay.report(request.session) or {id = request.fixture_id}
    report.outcome, report.reason, report.request_token, report.session_id = request.status, request.reason, request.token, state.session_id
    helpers.write_file("scv-control/navigation/live-result.json", assert(WireJson.encode(report)), false, 0)
    log("SCV_NAV_LIVE_TERMINAL " .. assert(WireJson.encode(summary(state))))
    if request.player_index then
      local player = game.get_player(request.player_index)
      if player then player.print("Live external solver " .. request.status .. ": " .. (request.reason or "")) end
    end
  end
end}

return Live
