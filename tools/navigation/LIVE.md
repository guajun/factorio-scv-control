# Live external solver lab

```powershell
python .\tools\navigation\live.py --test
python .\tools\navigation\live.py --port 34198
python .\tools\navigation\live.py --test --compare-transports
```

The first command starts an isolated localhost headless server, checks real
external planning, result delivery, follower arrival, cancellation and session
replacement, writes `live-report.json`, and stops only that server process. Test
success depends on arrival and protocol outcomes; timeout is a failure guard.

Snapshot transport now defaults to `--snapshot-transport file`. Factorio writes
one exact JSON payload to its isolated `script-output/scv-control/navigation/live-work.json`
using the supported `helpers.write_file(..., false, 0)` API. Only after writing
does `poll` publish the token, byte count, query identity and snapshot checksum.
The host performs one bounded local file read and validates those identities.
RCON carries short control messages and result uploads, not the full graph.
This is a bulk file channel, not shared memory or a new Lua filesystem API.

The fixed single-slot path stays under the launcher's own output directory;
unexpected paths, incomplete bytes, stale tokens or altered query/snapshot data
fail closed. A later request may overwrite the slot, but cannot be accepted under
an earlier request's descriptor. Results still go through synchronized RCON input
and shared PlanningRun validation. No per-client solver or memory injection exists.

`--snapshot-transport rcon` retains the old chunked download for comparison only.
The third command above checks both channels against the exact same captured
problem and records separate timings. `live-report.json` now reports capture-to-ready,
file read, read/decode/identity checks, solver work and upload/admission separately.
The game-side file write is included in capture-to-ready, not in host file-read time.
The normal default test does not run the slow comparison.

This removes the 1,128 command round trips; it does not cache the world, eliminate
synchronous capture, or make total command latency equal to file-read latency.
Committed-generation reuse and incremental updates remain issue #16.

The second command keeps the headless server and external solver running until
Ctrl+C. Open the printed `JOIN-CLIENT.txt` instructions and manually run the
generated `join-client.ps1`. It launches a separate client config using the exact
server mod copies; your ordinary client might use another development checkout
and fail checksum synchronization. In the developer map run `/scv-nav-live open-diagonal` or
another catalog fixture. The client spectates a separate real character while
the host downloads the current snapshot, solves it externally, and submits the
result through shared live validation and the native follower. Use
`/scv-nav-live status` to inspect status and `/scv-nav-live return` to restore
the player character. The script never starts or manipulates the graphical
client automatically. Ordinary singleplayer saves are not RCON servers; GUI testing joins this
explicitly isolated multiplayer host.

Use `--factorio-exe PATH` or `FACTORIO_EXE` to override Steam-library discovery.
`--artifact-root PATH` requires a fresh output directory; default is a retained
temporary directory. Artifacts include exact work/result JSON, server logs,
session metadata, and the test report. RCON credentials are generated per launch
and omitted from host logs and session metadata. Game and RCON ports both bind
to loopback. Mods are copied into the isolated runtime before launch, so edits
are picked up by restarting this lab, without changing the user's mod junctions.
The manually launched client has its own write-data directory, so server/client
config locks do not overlap. A Steam build can show its confirmation during that
explicit manual graphical launch; automated tests still launch only headless.

The host executes the fixed `/scv-nav-agent` custom command carrying JSON. It
never creates Lua code from external result content. Requests use sequential
chunks, pinned session/query identity, and explicit commit. Frames have bounded
lengths; TCP fragmentation is handled by reading the full announced byte count.
Only one request is in flight per RCON connection. `rpc-trace.jsonl` records each
operation's duration, byte counts, and response status without credentials or
payloads, so a blocked capture can be distinguished from a transfer failure.
Authentication, malformed
frames, wrong IDs, connection loss and timeouts are errors, not empty successes.

The installed Factorio 2.0.77 `--help` exposes the headless scenario and RCON bind
flags used here. `--test` provides the actual runtime compatibility check; a
different game version must pass it before claiming live support.
