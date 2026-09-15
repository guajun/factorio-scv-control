# Native save observations

`facts.lua` reads an existing `LuaSurface` and character. It does not construct
geometry from the fixture catalog. The save-corpus host creates the real ZIP,
records its SHA-256, reloads that ZIP, recaptures the bounded native world, and
compares the observation before beginning execution. Fixture configuration can
be retained under `metadata.scope.fixture_definition`; this binds action
schedules and controller settings as well as geometry. A prepared tick is not
part of identity.

```lua
local facts, err = Facts.capture(surface, actor, {
  left_top = {x = -24, y = -20}, right_bottom = {x = 24, y = 20}
}, {
  case_id = "gate-normal", domain = "gate-actions", fixture_version = 1,
  state_key = "baseline", start = {x = -13, y = 0}, goal = {x = 13, y = 0}
})
```

The returned `scv-save-facts/1` object contains `facts_hash`, `metadata`,
`coverage`, `environment`, `actor`, `tiles`, and `entities`. Capture returns
`nil, {code, message}` on unsupported input or a native API error. Bounds use
integer tile edges and half-open tile coverage; ungenerated chunks reject.
There are at most 65,536 tiles and 4,096 relevant entities, also subject to the
shared canonical encoder's 8 MiB limit. This is an intentionally synchronous,
bounded diagnostic capture, not a production incremental world cache.

Recorded facts include every tile's prototype collision mask, walking speed,
and hidden layers; intersecting collision entities and belts; native bounding
boxes, orientation, force relations, quality, destructibility and mineability;
gate state and immediate neighbor wall controls; belt speed and shape/endpoint
type; actor collision geometry, actual running speed, armor and equipment; and
engine/base version, active mods and surface name. Gate neighbors may be outside
the main rectangle, which the coverage declaration explicitly records.

`facts_hash` uses the existing cross-language canonical encoding. Entity and
equipment records sort by encoded semantic content; tiles have complete row
order. It excludes generated unit numbers and ticks. Other characters, ghosts,
and noncolliding nonmotion entities are explicitly outside this capture's
coverage. The actor profile is recorded separately, and the runtime asserts
the actor's initial position against the saved start. Spectator joins therefore
do not change the geometry checksum.

This is **semantic state identity**, not entity incarnation identity. Replacing
a gate with an identical one can preserve this checksum; execution must still
validate native handles/unit numbers before using a pending gate action. Gate
open/opening/closed/closing state is included, so opening a gate changes the
checksum. Exact opening progress and the opened prototype collision mask are
unavailable through the installed 2.0.77 runtime API and are declared unavailable.
Equipment is recorded but marked unvalidated rather than admitted to a motion
model. Dynamic populations, circuit-network simulation, belt item contents and
full engine internals are not claimed to be captured. The actual ZIP retains
the authoritative native state beyond this bounded projection.

The checksum is Adler32 plus canonical byte count, an accidental-change
detector. The host must independently SHA-256 the actual ZIP and facts file;
it must never treat the Lua checksum as authentication or use equal projected
facts as proof that two entire saves are equivalent.

## Derived map bindings

`tools/navigation/save_facts.py` supplies strict `read_facts` and
`validate_facts` functions. These reject malformed JSON, duplicate keys,
nonfinite values, incomplete/duplicate tiles, invalid coverage, missing semantic
fields and mismatched checksums. `test_save_facts.py` contains host contract
specimens, not synthetic replacements for native test maps.

`bind_derived(facts, save_sha256, compiler_id, compiler_version, settings)` creates
a `scv-save-derived/1` input binding. It records the source ZIP SHA-256, exact
facts hash, case and fixture version, explicit state key, and compiler/version/
settings. `validate_derived_binding` rejects reuse when any input differs.
A gate-state table or local-change lookup table can use one explicit binding
per captured state; no local-update algorithm or equivalence claim is implied.

Bindings are labelled `unverified-until-native-replay`. A compiler must declare
its supported coverage, representation loss and settings, and attach the
compiled artifact's own identity. Its candidate routes still need native
validation and measured execution in the source save. A matching binding only
proves which inputs the artifact claims to represent; it cannot prove that a
grid, table or mesh models those inputs correctly or runs fast in the game.
