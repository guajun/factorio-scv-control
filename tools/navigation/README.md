# Offline navigation solver

This dependency-free Python reference consumes a bounded directed graph captured
by TestKit. It compares Dijkstra and A* on the **same representation**, preserving
distance and directed travel ticks as separate objectives. Python 3.10 or newer
is sufficient; no package installation or Factorio GUI is needed.

```powershell
python .\tools\navigation\solve.py --capabilities
python -m unittest discover -s .\tools\navigation -p 'test_*.py' -v
python .\tools\navigation\solve.py --bundle capture.json --algorithm astar --output plans.json --lua-output imported_plans.lua
```

Alternatively use `--snapshot snapshot.json --query query.json` for one request.
Bundle input is `{protocol="scv-navigation/1", kind="capture-bundle", cases=[{id,
snapshot,query}]}` in JSON; output has `kind="solver-bundle"` and adds each case's
`result`. The optional Lua module contains only escaped data and is installed
into TestKit **before an isolated Factorio load**. Factorio never reads host JSON
at runtime. Only live Factorio validation and follower execution establish safety
and arrival.

Each query carries the complete NavigationData reference plus `query_hash`,
computed using the shared canonical checksum with the `query_hash` field omitted.
The snapshot hash covers the entire snapshot. Hashes identify values; Adler-32 is
not authentication. Identity admission is still required on the Factorio side.

Supported capability IDs: `directed-graph-v1`, `directed-edge-costs`, `distance`,
`travel-time`, `finite-bounds`. Unknown objectives/capabilities return `unsupported`.
Travel-time search requires a nonnegative `travel_ticks` value on every directed
edge. This supplies an algorithm test for belt-like weights; it is **not a
calibrated Factorio belt physics model**. Gate actions, mesh generation, world
deltas, live cancellation, and RCON are not implemented in this reference.

The A* heuristic is Euclidean distance times the minimum cost per geometric tile
among all graph edges, rounded downward. Every edge bounds that potential, so it
is consistent for nonnegative directed weights. A zero-cost edge can reduce A*
to Dijkstra. Dijkstra remains the objective reference. Edges represent straight
segments: their `distance` must match endpoint geometry. IDs must be unique;
parallel duplicate edges are rejected in this first graph profile.

Start/goal positions must equal their referenced graph nodes; projection is not
implicit. Search completes at the goal node. A complete result echoes identities,
the full data reference, objective, bounded coverage, graph node sequence,
geometric distance, optional travel ticks, and deterministic work metrics.
`no-path` only means the supplied bounded graph was exhausted. Expansion/output
limits return `budget-exhausted`; the CLI never truncates a route into success.
Malformed input exits 2 with `SCV_SOLVER_ERROR`; valid unsupported/no-path/budget
outcomes produce artifacts and exit 0 with `SCV_SOLVER_COMPLETE`. Episode assertions
decide which of those outcomes a fixture expects.

Input limits include 32 MiB JSON files, canonical nesting 64, 1,000,000 canonical
values and 8 MiB encoded canonical data, 100,000 graph nodes, 800,000 edges,
1,000,000 expansions, and 100,000 output points. All applicable limits apply, so the canonical
value bound can limit a graph before the node/edge bound. Nonfinite numbers,
inexact large integer values, duplicate JSON keys, duplicate IDs, mismatched
hashes, invalid endpoints/units, and routes contradicting graph weights are
rejected. Nulls are rejected when writing Lua import data because plain Lua tables
cannot preserve explicit null entries.
