# Source geometry topology experiment (#17)

This optional offline backend uses **extremitypathfinder 2.7.2** to build and query
an optimized polygon visibility graph. **Shapely 2.1.2 / GEOS** unions rectangular
configuration-space obstacles and subtracts them from bounded known space. The
original captured grid remains a separate Dijkstra control. Its cells, occupied
bits, resolution and extra half-cell-diagonal inflation do not build this backend.

Create an isolated **Python 3.12** environment and install pinned dependencies:

```powershell
python3.12 -m venv .\tools\navigation\backends\.venv312
.\tools\navigation\backends\.venv312\Scripts\python.exe -m pip install --require-hashes --only-binary=:all: -r .\tools\navigation\backends\requirements-win-py312.lock
.\tools\navigation\backends\.venv312\Scripts\python.exe -m unittest discover -s .\tools\navigation\backends -p 'test_*.py' -v
.\tools\navigation\backends\.venv312\Scripts\python.exe .\tools\navigation\backends\compare.py --bundle CAPTURE.json --output-dir .\tools\navigation\backends\artifacts\comparison
```

Use an explicit Python 3.12 executable if `python3.12` is unavailable. The tested
Codex bundled interpreter is 3.12.14. The initial Python 3.14 installation attempt
failed dependency resolution: extremitypathfinder 2.7.2 requires NumPy <2, whose
1.26.4 wheel targets Python up to 3.12. Dependencies were not overridden, vendored,
or installed globally. Numba is optional upstream and is not installed here.

The command writes `comparison.json`, `solver-bundle.json`, and data-only
`imported_plans.lua`. Every input case is retained, including unsupported and
resource-limited results. Export failures remain in `capture_errors` and make the
command fail. A library/geometry error also returns nonzero; a valid bounded
`no-path` result does not. Files already present in the explicit output directory
are replaced by this experiment's new reports.

## Declared geometry and limitations

Supported domain: static distance queries, fully enumerated tiles, the captured
character envelope, and axis-aligned `stone-wall` instances. The world-coordinate
`bounding_box` is deliberately used for walls to agree conservatively with the
current `find_entities(area)`-based runtime validator. Actor collision extents and
the **exported trajectory clearance margin** are Minkowski-expanded around each
obstacle. Tile collision layers determine blocking tiles. Missing tile facts,
gates, belts, non-wall entities, unrecognized capabilities and time objectives are
explicitly unsupported. This is not exact Factorio engine collision emulation.

The contact guard defaults to **1/256 tile**, separately named in the backend
configuration and hash. It keeps a geometric shortest route off the expanded
obstacle boundary at Factorio's position quantum; it is not via placement or grid
inflation. Its effect is visible and can be evaluated separately. Actor clearance
plus this guard also shrinks coverage. GEOS derives disconnected free components
before library search; a zero-width touching passage never becomes a connection
through the library's permissive overlapping-edge convention. `simplify(0)` removes
redundant collinear vertices only. No snapping or repair changes the topology.

The library accepts one counterclockwise boundary and clockwise obstacle rings.
We supply the connected free-space polygon containing both endpoints. Every
library query-graph edge is independently checked with GEOS `covers`; a bad edge
fails the case without repair. The library's A* result is compared against the
existing Python Dijkstra on **that exact exported query graph**, separately from
the captured-grid control. Ordinary line-of-sight queries use the library's direct
path shortcut and a two-node graph. Every case also measures a repeated query on
the same prepared environment.

Resource limits: at most 512 simplified polygon vertices by default. The adapter
uses `vertices + 2` as a sufficient upper bound for unique graph expansions under
the library's Euclidean consistent heuristic; smaller query budgets return
`budget-exhausted` before search. The library does not expose an actual expansion
counter, and reports label that value as an upper bound rather than a measurement.
The backend does not offer dynamic update, cancellation callbacks, sliced native
build work, or a production live cache. Future large-world use needs explicit
process watchdog and incremental build integration beyond this bounded proof.

## Input identity and replay integration

The derived snapshot preserves all `geometry`, actor, coverage, revision and
exporter facts. It replaces only optional `graph`, records the original snapshot
and query hashes, and receives a new snapshot ID, query hash and data reference:
`backend_id = extremity-source-polygons-v1`. It must not impersonate the captured
grid generation. Original and derived graph paths are not claimed to have the
same discretization.

Native replay needs the integration owner to allow this backend ID for
`imported-route` in the candidate provider registry. The emitted bundle then uses
the existing import validator, distance scorer, and follower without another
acceptance path. Until that integration executes, `replay_status = not-run` is
explicit in the report. No GUI or Factorio process is started by this backend CLI.

## Primary sources and licenses

- [extremitypathfinder 2.7.2 source](https://github.com/jannikmi/extremitypathfinder/tree/2.7.2),
  [MIT license](https://github.com/jannikmi/extremitypathfinder/blob/2.7.2/LICENSE),
  [algorithm and overlapping-edge caveat](https://extremitypathfinder.readthedocs.io/en/latest/3_about.html).
  The selected library supports a bounded polygon with holes, avoiding the extra
  coverage-boundary adapter needed by the initially surveyed pyvisgraph.
- [Shapely 2.1.2](https://github.com/shapely/shapely/tree/2.1.2),
  [BSD 3-Clause license](https://github.com/shapely/shapely/blob/2.1.2/LICENSE.txt),
  [union precision behavior](https://shapely.readthedocs.io/en/2.1.2/reference/shapely.unary_union.html).
  The wheel includes GEOS, whose [LGPL 2.1 license](https://libgeos.org/usage/download/)
  remains part of that distribution.
- [NumPy 1.26.4 license](https://github.com/numpy/numpy/blob/v1.26.4/LICENSE.txt)
  and [NetworkX 3.5 license](https://github.com/networkx/networkx/blob/networkx-3.5/LICENSE.txt)
  are BSD 3-Clause. See each wheel's bundled notices for transitive native code.

The tested Windows CPython 3.12 wheel hashes are locked separately. No third-party
code or binary is redistributed in the mod; these are optional host dependencies.
