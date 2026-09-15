local Live = require("__scv-control-testkit__/interchange/live")
local Tests = {}

function Tests.run(expect)
  local function call(operation, fields)
    fields = fields or {}
    fields.protocol, fields.operation = Live.PROTOCOL, operation
    return Live.dispatch(fields)
  end
  expect("live.ordinary-save-cannot-enable-service", call("capabilities").reason == "test-map-required")
  remote.add_interface("scv_navigation_live", {active = function() return true end})
  local first = call("capabilities", {nonce = "headless-contract-session"})
  expect("live.synchronized-handshake", first.ok == true and first.handshake_required == false)
  expect("live.bulk-file-is-default", first.snapshot_transport == "file")
  local changed = call("capabilities", {nonce = "headless-contract-session", snapshot_transport = "rcon"})
  expect("live.transport-cannot-change-within-session", changed.reason == "transport-change-requires-fresh-session")
  local unsupported = call("capabilities", {nonce = "headless-contract-session", snapshot_transport = "shared-memory"})
  expect("live.unsupported-transport-is-explicit", unsupported.reason == "unsupported-snapshot-transport")
  local state = storage.scv_navigation_live
  state.request = {status = "pending", token = "pending-before-peer-load", pending_tick = game.tick,
    upload = {}, upload_next_index = 1, upload_bytes = 0}
  if Live.on_load then Live.on_load() end
  Live.events[defines.events.on_tick]({tick = game.tick})
  local loaded = call("poll", {session_id = first.session_id})
  expect("live.peer-load-does-not-invent-cancellation", loaded.ok == true
    and loaded.status == "pending" and loaded.request_token == "pending-before-peer-load")
  local function chunk(index, data)
    return call("upload", {session_id = first.session_id, request_token = loaded.request_token, index = index, data = data})
  end
  expect("live.out-of-order-upload-rejected", chunk(2, "{}").reason == "out-of-order-upload")
  local accepted = chunk(1, "{")
  local duplicate = chunk(1, "{")
  expect("live.duplicate-chunk-has-one-effect", accepted.ok == true and duplicate.duplicate == true
    and state.request.upload_next_index == 2 and state.request.upload_bytes == 1)
  expect("live.conflicting-duplicate-upload-rejected", chunk(1, "{}").reason == "conflicting-upload-duplicate"
    and state.request.upload_bytes == 1)
  local second = call("capabilities", {nonce = "headless-contract-reconnect"})
  local stale = call("poll", {session_id = first.session_id})
  expect("live.host-reconnect-rotates-synchronized-session", second.session_id ~= first.session_id
    and second.status == "idle" and stale.reason == "stale-session")
  storage.scv_navigation_live = nil
  remote.remove_interface("scv_navigation_live")
end

return Tests
