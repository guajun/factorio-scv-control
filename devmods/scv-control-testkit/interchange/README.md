# Bounded capture and offline replay

`capture.lua` exports original entity positions, prototype collision masks/boxes,
instance bounds, tiles, actor descriptor, exact endpoints and fixture-v4 metadata.
The optional conservative grid is additional data; it never replaces the source
geometry. Its resolution, trajectory clearance, half-cell inflation and endpoint
connector policy are recorded. This permits a future portal or mesh adapter to
rebuild from source geometry without inheriting grid clearance loss.

The current exporter supports bounded static distance cases. Actual gates, belts,
vehicles and moving actors cause `unsupported-world-semantics`; an ignored gate
or belt is not an accepted approximation. Tile walking speed is exported but the
distance graph does not pretend to predict travel time. Unknown space is blocked,
and graph nodes/endpoint connectors keep the actor envelope inside coverage.
Resource limits fail explicitly; capture never silently coarsens a grid.

The default fixture bundle is written to
`script-output/scv-control/navigation/fixture-v4-capture.json` by the isolated
`-Suite interchange` scenario. It has `protocol = scv-navigation/1`, `kind = capture-bundle`, and a `cases`
array whose entries contain `id`, `snapshot`, and `query`. Export failures are
retained in `errors`. Each query binds a committed NavigationData reference and
canonical query hash. Lua/JSON round trips are checked in the engine.

Host tooling emits a data-only `interchange/imported_plans.lua` in an isolated
TestKit copy. That catalog has `kind = solver-bundle`; every case additionally
contains `result`. The checked-in empty catalog makes the normal mod independent
of any Python process. Imported cases are recreated on a dedicated replay surface,
admitted by the shared `PlanningRun` `interchange-distance-v1` profile and its
production validators, then executed with the production `Follower`. Raw solver
results and final accepted routes remain separate in `replay-results.json`.

Arrival is a semantic terminal outcome checked against measured endpoint error.
A replay tick limit is only a failure guard. A rejected `no-path` result is retained
with its bounded graph meaning and never called global physical unreachability.
Replay currently requires the same Factorio version and a matching reconstructed
actor descriptor. Unsupported actor modifiers fail explicitly.

The isolated scenario wires `interchange_tests.start(expect)` during test setup,
`interchange_tests.on_tick(expect, tick)` until it returns true, and includes that
completion flag in the suite terminal condition. The `interchange.runtime`
event library is registered in TestKit's `control.lua` for interactive commands. Automated suites
never start a GUI client.

In the marked GUI test save:

- `/scv-nav-capture all` exports the shared fixture-v4 catalog.
- `/scv-nav-capture tight-clearance-corridor` exports one shared fixture.
- `/scv-nav-capture live 10 20 8` captures from the current character position to
  `(10, 20)` with eight tiles of padding and the same static-domain restrictions.
- `/scv-nav-replay list` lists the host-generated imported catalog after reload.
- `/scv-nav-replay case-id` displays raw orange and accepted cyan routes and moves
  a separate real character on the isolated replay surface. The player spectates.
- `/scv-nav-replay return` restores the original character and lab location.

The GUI replay uses the same importer and follower as headless integration.
