# Live external solver on the test map

The companion mod's `interchange.live` event library enables this service only
when the `scv_test_interactive` or `scv_navigation_live` scenario marker exists.
The default production profile remains local. No command reads arbitrary host
files or evaluates solver-returned Lua. The host must explicitly connect by RCON;
the test runner must never launch a graphical client.

`/scv-nav-agent <JSON>` is the fixed host command. Every request contains
`protocol: "scv-navigation/1"` and `operation`. Responses are one JSON object.
Use the version-preserving wire JSON encoder for numeric fields.

| Operation | Additional request fields | Result |
| --- | --- | --- |
| `capabilities` | optional fresh ASCII `nonce` (8–128 letters/digits/hyphen/underscore), `snapshot_transport` (`file` default or `rcon`) | With nonce, establish `session_id`; return transport selection/support, `handshake_required`, `chunk_bytes`, limits and capabilities. A transport change requires a fresh session. Without nonce, inspect only. |
| `begin` | `session_id`, `fixture_id` | Queue one shared fixture-v4 case; return `request_token`. Capture starts on the next tick. |
| `poll` | `session_id`, optional `request_token` | Current status, work byte/chunk counts, query identity, or terminal summary. File-mode pending work includes `transfer`: fixed relative path, bytes, token/session, query ID/hash and snapshot hash. |
| `download` | `session_id`, `request_token`, zero-based byte `offset`, `max_bytes <= chunk_bytes` | Legacy/diagnostic channel: `{data, next_offset, eof, bytes}`. Joined chunks are the exact same `live-work` JSON as the bulk file. The default host does not use it. |
| `upload` | `session_id`, `request_token`, one-based `index`, ASCII `data` | Sequential upload acknowledgement. Identical duplicate chunks are idempotent; conflicting duplicates/reordering reject. Total payload is bounded at 1 MiB. |
| `commit` | `session_id`, `request_token`, optional `total_chunks` | Parse assembled `solver-result` JSON and deliver exactly once to shared `PlanningRun.handle_solver_result`. |
| `cancel` | `session_id`, `request_token` | Stop the actor, cancel the shared planning run and invalidate upload state. |

All operations after capabilities require the matching session ID. Unknown or
superseded request tokens fail explicitly. A committed result cannot be delivered
twice. Admission includes query/data/actor identity plus the normal live validators.
Successful search transitions into real movement; only measured follower arrival
produces `arrived`. Poll returns `admission_count` for duplicate-delivery assertions.

Terminal artifacts are written as `script-output/scv-control/navigation/live-result.json`
and logged with `SCV_NAV_LIVE_TERMINAL`. The report retains the raw external result,
shared final planning result, actor movement measurements and request identity.
Transport wait and movement ticks are failure guards, never success conditions.

Host reconnect uses a fresh nonce and cancels the old incarnation through a
synchronized command. `on_load` does not independently change session state,
because it also runs on joining clients. The launcher currently starts fresh
scenarios; arbitrary saved-session resumption remains a separate lifecycle test.

Bulk-file publication uses `helpers.write_file` with `for_player=0`: only the
authoritative server writes it. `pending`/`transfer` is published after the write.
The path is fixed, not supplied by a solver; clients neither read it nor make
local planning decisions. The existing result commit remains authoritative.

GUI commands in the marked test save:

- `/scv-nav-live fixture-id` queues work for the connected host solver service,
  reconstructs a dedicated test surface and spectates the real moving actor.
- `/scv-nav-live status` prints current request/terminal state.
- `/scv-nav-live return` restores the original character and location.

Orange is the imported raw route; cyan is the exact accepted route. The GUI and
headless entry points share the same command state, imported-result admission and
Follower. A host service must poll and solve pending work without restarting the
Factorio process between commands. The user may explicitly join that headless
server with a GUI client; the host tooling never launches one automatically.

Required probes: normal open-fixture arrival; second case in the same process;
duplicate commit leaves `admission_count = 1`; wrong request/session rejected;
out-of-order and conflicting upload rejected; cancellation prevents late commit;
malformed or stale solver result rejected; host reconnect rotates the nonce; host
watchdog terminates its own failed process while GUI service mode remains running
until explicitly stopped. Live gates/belts/dynamic-world solving are unsupported
until their domain models and invalidation policies are calibrated.

All session state is synchronized storage. A joining GUI peer also runs `on_load`,
so that hook cannot independently invalidate a live request. The current launcher
starts a fresh scenario each time and rotates the nonce on connecting. Resuming
arbitrary saved live sessions and a two-peer desync probe remain separate tests.
