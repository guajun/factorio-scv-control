# Static source-save comparison runtime

The `navigation-comparison` marker scenario enables this local companion-mod
service. `prepare` is the only authoring operation: it builds a shared fixture-v4
map once, creates a real character, and makes tiles outside navigation coverage
`out-of-map`. Source facts include a two-tile boundary ring. The ZIP is published
before capture/planning. A normal evaluation loads that ZIP in another process;
it never calls `Fixtures.build`, `Capture.fixture`, or `Replay.prepare` again.

The RCON command is `/scv-compare-agent <JSON>`, with
`protocol: "scv-compare/1"` and `operation`:

| Operation | Arguments and behavior |
| --- | --- |
| `catalog` | Returns the eleven shared fixture descriptors. |
| `prepare` | `id`; author one map in a fresh marker scenario. |
| `save` | `name`; publish a paused, pre-capture source ZIP. |
| `status` | Phase, actor position, source identity, plan count, report paths. |
| `facts` | Server-only bulk JSON descriptor `{path, bytes, facts_hash}`. |
| `capture` | Optional `resolution` (default 0.5) and `include_graph`; captures the saved actor/surface and returns a server-only bulk file descriptor. |
| `plan` | `algorithm: "production-v1"`, `pass: "cold"` then `"repeat"`; uses the shared production PlanningRun in its original serial engine-provider order. |
| `upload` | `index`, `text` (1–3000 bytes), and `reset: true` on first chunk. Ordered and idempotent; at most 1 MiB. |
| `commit` | `algorithm: "grid-astar"`, `"grid-dijkstra"`, or `"source-polygons"`; `pass: "cold"` then `"repeat"`. Imports the uploaded result through shared boundary validators and PlanningRun. |
| `execute` | Execute the latest accepted plan with the native character and shared Replay/Follower; report an expected no-path without moving. |
| `clock` | Native debug `action: "pause"`, `"resume"`, `"status"`, or `"step"` with `ticks`. |

Capture files contain `{protocol, kind: "comparison-work", id,
source_facts_hash, snapshot, query}`. IDs are based on the saved case/tick, not
the algorithm. External uploads contain `{source_facts_hash,
source_snapshot_hash, source_query_hash, result}`. Source polygon uploads also
contain `derived: {snapshot_id, source_input, graph, query}`. The resident source
geometry is never accepted over this wire. The runtime reconstructs a derived
snapshot from the resident capture, checks its hash, and forbids changes to the
command, budget, actor, world identity or revisions. Live validators still judge
accepted geometry; the derived binding alone is not an equivalence proof.

Both cold and repeat queries start from the exact saved actor origin. Production
asynchronous planning advances native engine updates while the actor is stopped;
external capture/solver/admission remains paused. One algorithm is allowed per
loaded process. Planning ends at `phase: "planned"`, with a distinct
`planning_outcome`; execution then produces `phase: "complete"` and a final
report. Runtime failures use `phase: "failed"`. Tick limits only fail.

`scv-control/comparison/result.json` retains every planning pass and its full
shared PlanningRun result, raw/final paths and lengths, plus native distance,
arrival ticks/error, direction switches and cross-track error. Raw production
grid output is explicitly unavailable if the shared provider did not retain it;
the final smoothed path is never mislabelled as raw. Script-only LuaProfiler
samples go to `performance.jsonl`, with `cold:`/`repeat:` hook prefixes and
terminal aggregate rows. These timings do not include full engine update CPU;
paused external correctness is not realtime performance evidence.

GUI source maps open paused with a spectator and labels. `/scv-compare plan`
previews production, `/scv-compare run` plans/executes it, and `pause` freezes the
world. Reload the original ZIP to restore its factual state. No automated test
launches a graphical client.
