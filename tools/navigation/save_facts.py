"""Validate native save observations and bind derived maps to their source.

The canonical checksum is an accidental-change detector, not a security hash.
The host's SHA-256 of the actual ZIP identifies the authoritative source save.
This contract certifies inputs, never a compiler's behavioral equivalence.
"""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import re
from typing import Any

from canonical import CanonicalError, canonical_bytes, content_hash

PROTOCOL = "scv-save-facts/1"
DERIVED_PROTOCOL = "scv-save-derived/1"
MAX_TILES = 65_536
MAX_ENTITIES = 4_096
MAX_FILE_BYTES = 16 * 1024 * 1024
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class FactsError(ValueError):
    """Malformed or semantically mismatched native save facts."""


def _fail(message: str) -> None:
    raise FactsError(message)


def _object(value: Any, path: str, required: set[str], optional: set[str] | None = None) -> dict:
    if not isinstance(value, dict):
        _fail(f"{path}: expected object")
    keys = set(value)
    if required - keys or keys - required - (optional or set()):
        _fail(f"{path}: missing/unknown fields")
    return value


def _string(value: Any, path: str, limit: int = 256) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > limit:
        _fail(f"{path}: expected bounded nonempty string")
    return value


def _number(value: Any, path: str, *, minimum: float = -1_000_000,
            maximum: float = 1_000_000, integer: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        _fail(f"{path}: expected finite number")
    if not minimum <= value <= maximum or integer and int(value) != value:
        _fail(f"{path}: number outside declared bounds")
    return value


def _boolean(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        _fail(f"{path}: expected boolean")
    return value


def _array(value: Any, path: str, limit: int) -> list:
    # Factorio plain empty tables may cross JSON as {}. Canonical v1 gives
    # both empty container forms the same identity; nonempty objects reject.
    if value == {}:
        return []
    if not isinstance(value, list) or len(value) > limit:
        _fail(f"{path}: expected bounded array")
    return value


def _point(value: Any, path: str, *, integer: bool = False) -> dict:
    value = _object(value, path, {"x", "y"})
    for axis in ("x", "y"):
        _number(value[axis], f"{path}.{axis}", integer=integer)
    return value


def _box(value: Any, path: str, *, integer: bool = False, nonempty: bool = False) -> dict:
    value = _object(value, path, {"left_top", "right_bottom"})
    first = _point(value["left_top"], path + ".left_top", integer=integer)
    second = _point(value["right_bottom"], path + ".right_bottom", integer=integer)
    if any(first[axis] > second[axis] or nonempty and first[axis] == second[axis] for axis in ("x", "y")):
        _fail(f"{path}: reversed or empty box")
    return value


def _mask(value: Any, path: str) -> None:
    value = _object(value, path, {"layers", "not_colliding_with_itself", "consider_tile_transitions", "colliding_with_tiles_only"})
    layers = _array(value["layers"], path + ".layers", 256)
    for item in layers:
        _string(item, path + ".layers[]")
    if layers != sorted(set(layers), key=lambda text: text.encode("utf-8")):
        _fail(f"{path}: collision layers must be unique and sorted")
    for name in value.keys() - {"layers"}:
        _boolean(value[name], f"{path}.{name}")


def _sorted(values: list, path: str) -> None:
    encoded = [canonical_bytes(value) for value in values]
    if encoded != sorted(encoded):
        _fail(f"{path}: records are not canonically sorted")


def _wall_control(value: Any, path: str) -> None:
    value = _object(value, path, {"configured"}, {"open_gate", "read_sensor", "circuit_condition"})
    configured = _boolean(value["configured"], path + ".configured")
    if configured:
        if set(value) != {"configured", "open_gate", "read_sensor", "circuit_condition"}:
            _fail(f"{path}: configured control requires its settings")
        _boolean(value["open_gate"], path + ".open_gate")
        _boolean(value["read_sensor"], path + ".read_sensor")
        if not isinstance(value["circuit_condition"], dict) or len(canonical_bytes(value["circuit_condition"])) > 8192:
            _fail(f"{path}: invalid bounded circuit condition")
    elif set(value) != {"configured"}:
        _fail(f"{path}: unconfigured control has settings")


def _reference(value: dict, path: str) -> None:
    for name in ("name", "type", "force"):
        _string(value[name], f"{path}.{name}")
    _point(value["position"], path + ".position")
    _number(value["direction"], path + ".direction", minimum=0, maximum=15, integer=True)


def fact_hash(value: dict) -> str:
    """Hash the declared observation, excluding only its checksum field."""
    try:
        return content_hash({key: item for key, item in value.items() if key != "facts_hash"})
    except (CanonicalError, AttributeError, TypeError) as error:
        raise FactsError(f"Invalid canonical facts: {error}") from error


def validate_facts(value: Any) -> dict:
    """Strictly validate a version 1 native capture without normalizing it."""
    value = _object(value, "facts", {"protocol", "facts_hash", "metadata", "coverage", "environment", "actor", "tiles", "entities"})
    # Validate canonical limits and finite/UTF-8 values before schema traversal.
    actual_hash = fact_hash(value)
    if value["protocol"] != PROTOCOL:
        _fail("Unsupported facts protocol")
    if value["facts_hash"] != actual_hash:
        _fail("Native facts checksum mismatch")
    meta = _object(value["metadata"], "metadata", {"case_id", "domain", "fixture_version", "goal", "state_key"}, {"start", "scenario", "scope"})
    for name in ("case_id", "domain", "state_key"):
        _string(meta[name], "metadata." + name)
    _number(meta["fixture_version"], "metadata.fixture_version", minimum=1, maximum=1_000_000, integer=True)
    for name in ("start", "goal"):
        if name in meta:
            _point(meta[name], "metadata." + name)
    if "scenario" in meta:
        _string(meta["scenario"], "metadata.scenario")
    if "scope" in meta and (not isinstance(meta["scope"], (str, dict)) or len(canonical_bytes(meta["scope"])) > 65_536):
        _fail("metadata.scope: expected bounded description or configuration")

    coverage = _object(value["coverage"], "coverage", {"bounds", "outside", "chunks", "tiles", "entities", "exclusions", "gate_neighbours", "identity"})
    declarations = {
        "outside": "unknown", "chunks": "generated", "tiles": "all-tile-centres-in-half-open-bounds",
        "entities": "bounding-box-intersection-collision-or-gate-or-belt",
        "gate_neighbours": "observed-immediate-neighbours-including-outside-bounds",
        "identity": "semantic-state-not-entity-incarnation",
        "exclusions": ["characters-other-than-actor-profile", "entity-ghost", "tile-ghost", "noncolliding-nonmotion-entities"],
    }
    for name, expected in declarations.items():
        if coverage[name] != expected:
            _fail(f"coverage.{name}: unsupported coverage declaration")
    bounds = _box(coverage["bounds"], "coverage.bounds", integer=True, nonempty=True)
    first, second = bounds["left_top"], bounds["right_bottom"]
    width, height = int(second["x"] - first["x"]), int(second["y"] - first["y"])
    if width * height > MAX_TILES:
        _fail("coverage.bounds: tile limit exceeded")
    for name in ("start", "goal"):
        if name in meta and any(not first[axis] <= meta[name][axis] <= second[axis] for axis in ("x", "y")):
            _fail(f"metadata.{name}: outside declared coverage")

    environment = _object(value["environment"], "environment", {"engine_version", "active_mods", "surface"})
    for name in ("engine_version", "surface"):
        _string(environment[name], "environment." + name)
    mods = _array(environment["active_mods"], "environment.active_mods", 1024)
    names = set()
    for mod in mods:
        _object(mod, "active_mods[]", {"name", "version"})
        _string(mod["name"], "mod.name")
        _string(mod["version"], "mod.version")
        if mod["name"] in names:
            _fail("Duplicate active mod")
        names.add(mod["name"])
    _sorted(mods, "active_mods")
    if not any(mod["name"] == "base" and mod["version"] == environment["engine_version"] for mod in mods):
        _fail("Engine version and base mod version disagree")

    actor = _object(value["actor"], "actor", {"name", "type", "force", "prototype_collision_box", "collision_mask", "running_speed", "running_speed_modifier", "prototype_running_speed", "prototype_belt_immunity", "armor", "equipment", "equipment_scope", "movement_bonus_inhibited"})
    for name in ("name", "force"):
        _string(actor[name], "actor." + name)
    if actor["type"] != "character":
        _fail("Only native character facts are supported")
    _box(actor["prototype_collision_box"], "actor.prototype_collision_box")
    _mask(actor["collision_mask"], "actor.collision_mask")
    for name in ("running_speed", "prototype_running_speed"):
        _number(actor[name], "actor." + name, minimum=0)
    _number(actor["running_speed_modifier"], "actor.running_speed_modifier", minimum=-1)
    for name in ("prototype_belt_immunity", "movement_bonus_inhibited"):
        _boolean(actor[name], "actor." + name)
    armor = _array(actor["armor"], "actor.armor", 16)
    equipment = _array(actor["equipment"], "actor.equipment", 1024)
    for item in armor:
        _object(item, "armor[]", {"name", "quality"})
        for name in item:
            _string(item[name], "armor." + name)
    for item in equipment:
        _object(item, "equipment[]", {"name", "quality", "position", "energy", "movement_bonus"})
        _string(item["name"], "equipment.name")
        _string(item["quality"], "equipment.quality")
        _point(item["position"], "equipment.position", integer=True)
        _number(item["energy"], "equipment.energy", minimum=0, maximum=1e15)
        _number(item["movement_bonus"], "equipment.movement_bonus", minimum=0)
    _sorted(armor, "actor.armor")
    _sorted(equipment, "actor.equipment")
    expected_scope = "unarmored-native-character-v1" if not armor and not equipment else "captured-equipment-unvalidated"
    if actor["equipment_scope"] != expected_scope:
        _fail("Equipment coverage claim disagrees with captured inventory")

    tiles = _array(value["tiles"], "tiles", MAX_TILES)
    if len(tiles) != width * height:
        _fail("Tile observations do not cover every declared coordinate")
    for index, tile in enumerate(tiles):
        _object(tile, "tiles[]", {"position", "name", "collision_mask", "walking_speed_modifier", "hidden_tile", "double_hidden_tile"})
        position = _point(tile["position"], "tile.position", integer=True)
        if position != {"x": first["x"] + index % width, "y": first["y"] + index // width}:
            _fail("Duplicate, missing or unsorted tile coordinate")
        _string(tile["name"], "tile.name")
        _mask(tile["collision_mask"], "tile.collision_mask")
        _number(tile["walking_speed_modifier"], "tile.walking_speed_modifier", minimum=0)
        for name in ("hidden_tile", "double_hidden_tile"):
            if tile[name] is not False:
                _string(tile[name], "tile." + name)

    entities = _array(value["entities"], "entities", MAX_ENTITIES)
    for item in entities:
        _object(item, "entities[]", {"name", "type", "position", "force", "direction", "bounding_box", "prototype_collision_box", "collision_mask", "orientation", "destructible", "minable", "quality", "force_relation"}, {"wall_control", "gate", "belt"})
        _reference(item, "entity")
        if item["type"] in ("character", "entity-ghost", "tile-ghost"):
            _fail("Captured entity contradicts coverage exclusions")
        entity_bounds = _box(item["bounding_box"], "entity.bounding_box")
        if any(entity_bounds["right_bottom"][axis] < first[axis] or entity_bounds["left_top"][axis] > second[axis] for axis in ("x", "y")):
            _fail("Entity does not intersect captured bounds")
        _box(item["prototype_collision_box"], "entity.prototype_collision_box")
        _mask(item["collision_mask"], "entity.collision_mask")
        _number(item["orientation"], "entity.orientation", minimum=0, maximum=1)
        _string(item["quality"], "entity.quality")
        for name in ("destructible", "minable"):
            _boolean(item[name], "entity." + name)
        relation = _object(item["force_relation"], "entity.force_relation", {"same", "friend", "cease_fire"})
        for name in relation:
            _boolean(relation[name], "force_relation." + name)
        if relation["same"] != (item["force"] == actor["force"]):
            _fail("Entity force relation contradicts actor force")
        if (item["type"] == "wall") != ("wall_control" in item):
            _fail("Wall control descriptor missing or on wrong entity")
        if "wall_control" in item:
            _wall_control(item["wall_control"], "entity.wall_control")
        if (item["type"] == "gate") != ("gate" in item):
            _fail("Gate state descriptor missing or on wrong entity")
        if "gate" in item:
            gate = _object(item["gate"], "gate", {"state", "neighbours", "opening_progress", "opened_collision_mask"})
            if gate["state"] not in {"opened", "opening", "closed", "closing", "unknown"}:
                _fail("Unknown gate state enum")
            for name in ("opening_progress", "opened_collision_mask"):
                if gate[name] != "unavailable-in-runtime-2.0.77":
                    _fail("Unsupported gate prototype coverage claim")
            neighbours = _array(gate["neighbours"], "gate.neighbours", 16)
            for neighbour in neighbours:
                _object(neighbour, "gate.neighbours[]", {"name", "type", "position", "force", "direction"}, {"wall_control"})
                _reference(neighbour, "gate.neighbour")
                if (neighbour["type"] == "wall") != ("wall_control" in neighbour):
                    _fail("Adjacent wall control coverage missing")
                if "wall_control" in neighbour:
                    _wall_control(neighbour["wall_control"], "gate.neighbour.wall_control")
            _sorted(neighbours, "gate.neighbours")
        belt_type = item["type"] in {"transport-belt", "underground-belt", "splitter", "linked-belt", "loader", "loader-1x1"}
        if belt_type != ("belt" in item):
            _fail("Belt descriptor missing or on wrong entity")
        if "belt" in item:
            belt = _object(item["belt"], "belt", {"speed"}, {"shape", "endpoint_type"})
            _number(belt["speed"], "belt.speed", minimum=0)
            if item["type"] == "transport-belt" and belt.get("shape") not in {"straight", "left", "right"}:
                _fail("Belt shape missing or invalid")
            if item["type"] in {"underground-belt", "linked-belt"} and belt.get("endpoint_type") not in {"input", "output"}:
                _fail("Belt endpoint type missing or invalid")
    _sorted(entities, "entities")
    return value


def _pairs(pairs: list[tuple[str, Any]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            _fail(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def read_facts(path: str | Path) -> dict:
    """Read bounded exact JSON; reject duplicate keys and nonfinite numbers."""
    path = Path(path)
    if path.stat().st_size > MAX_FILE_BYTES:
        _fail("Native facts file exceeds size bound")
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_pairs,
                           parse_constant=lambda value: _fail(f"Nonfinite JSON number: {value}"))
        return validate_facts(value)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise FactsError(f"Invalid native facts JSON: {error}") from error


def sha256_file(path: str | Path) -> str:
    """Hash the actual archive/artifact bytes without unpacking or regenerating."""
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bind_derived(facts: dict, save_sha256: str, compiler_id: str,
                 compiler_version: str, settings: dict) -> dict:
    """Describe inputs for a derived map; native replay is still required."""
    validate_facts(facts)
    if not isinstance(save_sha256, str) or not SHA256.fullmatch(save_sha256):
        _fail("Source save SHA-256 must be lowercase hexadecimal")
    _string(compiler_id, "compiler.id")
    _string(compiler_version, "compiler.version")
    if not isinstance(settings, dict) or len(canonical_bytes(settings)) > 65_536:
        _fail("Compiler settings must be a bounded object")
    binding = {"protocol": DERIVED_PROTOCOL,
               "source": {"save_sha256": save_sha256, "facts_hash": facts["facts_hash"],
                          "case_id": facts["metadata"]["case_id"],
                          "fixture_version": facts["metadata"]["fixture_version"],
                          "state_key": facts["metadata"]["state_key"]},
               "compiler": {"id": compiler_id, "version": compiler_version, "settings": settings},
               "equivalence": "unverified-until-native-replay"}
    binding["binding_hash"] = content_hash(binding)
    return binding


def validate_derived_binding(binding: Any, facts: dict, save_sha256: str) -> dict:
    """Reject reuse across source archives, state changes or compiler edits."""
    _object(binding, "binding", {"protocol", "source", "compiler", "equivalence", "binding_hash"})
    source = _object(binding["source"], "binding.source", {"save_sha256", "facts_hash", "case_id", "fixture_version", "state_key"})
    compiler = _object(binding["compiler"], "binding.compiler", {"id", "version", "settings"})
    expected = bind_derived(facts, save_sha256, compiler["id"], compiler["version"], compiler["settings"])
    if binding != expected:
        _fail("Derived map binding disagrees with source save, state facts or compiler settings")
    return binding
