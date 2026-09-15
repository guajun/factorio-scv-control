# Live transport probe design record

This note records the pre-implementation checklist. The exact-version initial
probe now passes on Factorio 2.0.77; current commands and verified scope are in
[LIVE.md](LIVE.md). Full saved-session lifecycle, source invalidation and GUI
two-peer verification remain [issue #16](https://github.com/guajun/factorio-scv-control/issues/16).
The operation names below are design examples, not the implemented RPC schema.

The offline reference does not launch or connect to Factorio. The next transport
task can reuse `solver.solve`, `validate_result`, and the same query/result hashes.

The documented server flags include `--start-server-load-scenario`, `--rcon-bind
ADDRESS:PORT`, and `--rcon-password`. Use a runner-owned isolated headless server,
bind RCON to `127.0.0.1`, and retain only its process handle for cleanup. Verify flags
with the installed executable's help output before treating the current web
documentation as an exact-version guarantee. [Factorio command-line documentation](https://wiki.factorio.com/Command_line_parameters)

Register one fixed TestKit command that parses its parameter as JSON. It should
support bounded `capabilities`, `begin`, `upload-chunk`, `commit-result`, `poll`,
and `cancel` operations with request/session identity. Asynchronous Factorio work
stays in storage as plain state; a later poll returns progress or completion.
`rcon.print` addresses the calling RCON interface, so a tick callback must not
retain a command's RCON object to push an unsolicited completion. Custom command
registration is recreated on each load. [LuaRCON](https://lua-api.factorio.com/latest/classes/LuaRCON.html),
[LuaCommandProcessor](https://lua-api.factorio.com/latest/classes/LuaCommandProcessor.html)

The first probe should answer these questions with an exact-version machine
report before making live transport part of `-Suite all`:

- Does the installed binary accept localhost RCON with the same GUI-free launch
  mode used by the current runner?
- Can the host authenticate, submit a fixed command, and read a correlated JSON
  answer when TCP splits one reply across multiple reads?
- Does one complete imported result reach shared PlanningRun validation and the
  native follower's arrival terminal state?
- Are duplicate deliveries idempotent, old attempts/session IDs rejected, and
  interrupted uploads bounded and discarded?
- Do timeout, malformed frames, wrong credentials, solver crash, cancelled
  requests, and world-generation changes end in explicit distinct states?
- Does save/reload rotate the session and reject pre-load results, with no socket
  or native process object stored in Factorio state?

Do not use generic Source-server assumptions to guess Factorio's multi-response
termination behavior. An official Factorio forum report documents historical
differences and ordering pitfalls; the current installed version requires a probe.
Application chunking plus exact byte-count framing can bound requests independently
of those differences. [Historical RCON report](https://forums.factorio.com/viewtopic.php?t=86598)

This original checklist is retained to make untested lifecycle requirements
visible; passing initial headless arrival does not complete every item above.
