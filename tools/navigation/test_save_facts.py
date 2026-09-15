"""Host boundary regressions; native captures/reloads are tested by savebench."""
from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest

from canonical import canonical_bytes
from save_facts import (FactsError, bind_derived, fact_hash, read_facts,
                        sha256_file, validate_derived_binding, validate_facts)


def mask(layers=()):
    return {"layers": sorted(layers), "not_colliding_with_itself": False,
            "consider_tile_transitions": False, "colliding_with_tiles_only": False}


def box(left, top, right, bottom):
    return {"left_top": {"x": left, "y": top}, "right_bottom": {"x": right, "y": bottom}}


def entity(kind, name):
    result = {"name": name, "type": kind, "position": {"x": 0.5, "y": 0.5}, "force": "player",
              "direction": 4, "bounding_box": box(0.1, 0.1, 0.9, 0.9),
              "prototype_collision_box": box(-0.4, -0.4, 0.4, 0.4), "collision_mask": mask(["player"]),
              "orientation": 0.25, "destructible": False, "minable": True, "quality": "normal",
              "force_relation": {"same": True, "friend": True, "cease_fire": True}}
    if kind == "gate":
        result["gate"] = {"state": "closed", "neighbours": [],
                          "opening_progress": "unavailable-in-runtime-2.0.77",
                          "opened_collision_mask": "unavailable-in-runtime-2.0.77"}
    if kind == "transport-belt":
        result["belt"] = {"speed": 0.09375, "shape": "straight"}
    return result


def sealed(value):
    value["facts_hash"] = fact_hash(value)
    return value


def sample():
    """Small contract specimen, deliberately not a claimed game observation."""
    tiles = [{"position": {"x": x, "y": y}, "name": "refined-concrete", "collision_mask": mask(),
              "walking_speed_modifier": 1.5, "hidden_tile": "grass-1", "double_hidden_tile": False}
             for y in range(2) for x in range(2)]
    return sealed({"protocol": "scv-save-facts/1",
                   "metadata": {"case_id": "host-contract-specimen", "domain": "gates", "fixture_version": 1,
                                "state_key": "baseline", "goal": {"x": 1.5, "y": 1.5},
                                "scope": {"fixture_definition": {"opening_ticks": 16}}},
                   "coverage": {"bounds": box(0, 0, 2, 2), "outside": "unknown", "chunks": "generated",
                                "tiles": "all-tile-centres-in-half-open-bounds",
                                "entities": "bounding-box-intersection-collision-or-gate-or-belt",
                                "exclusions": ["characters-other-than-actor-profile", "entity-ghost", "tile-ghost", "noncolliding-nonmotion-entities"],
                                "gate_neighbours": "observed-immediate-neighbours-including-outside-bounds",
                                "identity": "semantic-state-not-entity-incarnation"},
                   "environment": {"engine_version": "2.0.77", "active_mods": [{"name": "base", "version": "2.0.77"}], "surface": "test"},
                   "actor": {"name": "character", "type": "character", "force": "player",
                             "prototype_collision_box": box(-0.2, -0.2, 0.2, 0.2), "collision_mask": mask(["player"]),
                             "running_speed": 0.15, "running_speed_modifier": 0, "prototype_running_speed": 0.1,
                             "prototype_belt_immunity": False, "armor": [], "equipment": [],
                             "equipment_scope": "unarmored-native-character-v1", "movement_bonus_inhibited": False},
                   "tiles": tiles, "entities": [entity("gate", "gate")]})


class SaveFactsTests(unittest.TestCase):
    def test_observation_and_derived_binding_roundtrip(self):
        facts = sample()
        self.assertIs(validate_facts(facts), facts)
        binding = bind_derived(facts, "a" * 64, "example-grid", "1", {"cell_size": 0.5, "unknown": "blocked"})
        self.assertEqual(validate_derived_binding(binding, facts, "a" * 64), binding)
        self.assertEqual(binding["equivalence"], "unverified-until-native-replay")

    def test_semantic_gate_belt_tile_changes_reject_old_map(self):
        base = sample()
        base["entities"].append(entity("transport-belt", "express-transport-belt"))
        base["entities"].sort(key=canonical_bytes)
        sealed(base)
        binding = bind_derived(base, "a" * 64, "state-table", "1", {"lookup": "explicit-state"})
        mutations = {
            "gate-opened": lambda value: next(item for item in value["entities"] if item["type"] == "gate")["gate"].update(state="opened"),
            "belt-rotated": lambda value: next(item for item in value["entities"] if item["type"] == "transport-belt").update(direction=12, orientation=0.75),
            "belt-tier": lambda value: next(item for item in value["entities"] if item["type"] == "transport-belt")["belt"].update(speed=0.03125),
            "water-tile": lambda value: value["tiles"][0].update(name="water", collision_mask=mask(["player"])),
            "tile-speed": lambda value: value["tiles"][0].update(walking_speed_modifier=1),
            "actor-speed": lambda value: value["actor"].update(running_speed=0.75, running_speed_modifier=4),
            "action-schedule": lambda value: value["metadata"]["scope"]["fixture_definition"].update(opening_ticks=20),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                changed = deepcopy(base)
                mutate(changed)
                changed["entities"].sort(key=canonical_bytes)
                sealed(changed)
                validate_facts(changed)
                self.assertNotEqual(changed["facts_hash"], base["facts_hash"])
                with self.assertRaisesRegex(FactsError, "binding disagrees"):
                    validate_derived_binding(binding, changed, "a" * 64)

    def test_configured_adjacent_wall_is_source_semantics(self):
        facts = sample()
        neighbour = {"name": "stone-wall", "type": "wall", "position": {"x": 0.5, "y": -0.5},
                     "force": "player", "direction": 0, "wall_control": {"configured": False}}
        facts["entities"][0]["gate"]["neighbours"] = [neighbour]
        sealed(facts)
        binding = bind_derived(facts, "a" * 64, "gate-table", "1", {})
        changed = deepcopy(facts)
        changed["entities"][0]["gate"]["neighbours"][0]["wall_control"] = {
            "configured": True, "open_gate": False, "read_sensor": True,
            "circuit_condition": {"condition": {"constant": 5, "comparator": ">"}}}
        sealed(changed)
        validate_facts(changed)
        with self.assertRaises(FactsError):
            validate_derived_binding(binding, changed, "a" * 64)

    def test_state_table_key_and_source_archive_are_both_bound(self):
        facts = sample()
        binding = bind_derived(facts, "a" * 64, "state-table", "1", {})
        with self.assertRaises(FactsError):
            validate_derived_binding(binding, facts, "b" * 64)
        changed = deepcopy(facts)
        changed["metadata"]["state_key"] = "wall-added-1"
        sealed(changed)
        with self.assertRaises(FactsError):
            validate_derived_binding(binding, changed, "a" * 64)
        self.assertNotEqual(bind_derived(changed, "a" * 64, "state-table", "1", {})["binding_hash"], binding["binding_hash"])

    def test_compiler_settings_tampering_is_not_reusable(self):
        facts = sample()
        binding = bind_derived(facts, "a" * 64, "grid", "1", {"resolution": 0.5})
        binding["compiler"]["settings"]["resolution"] = 1
        with self.assertRaises(FactsError):
            validate_derived_binding(binding, facts, "a" * 64)

    def test_unrecorded_change_fails_checksum(self):
        facts = sample()
        facts["entities"][0]["gate"]["state"] = "opened"
        with self.assertRaisesRegex(FactsError, "checksum mismatch"):
            validate_facts(facts)

    def test_missing_or_duplicate_tile_is_not_complete_coverage(self):
        for mutation in (lambda facts: facts["tiles"].pop(),
                         lambda facts: facts["tiles"].__setitem__(1, deepcopy(facts["tiles"][0]))):
            facts = sample()
            mutation(facts)
            sealed(facts)
            with self.assertRaises(FactsError):
                validate_facts(facts)

    def test_duplicate_mod_and_unsorted_layers_fail_even_with_matching_hash(self):
        facts = sample()
        facts["environment"]["active_mods"] *= 2
        with self.assertRaisesRegex(FactsError, "Duplicate active mod"):
            validate_facts(sealed(facts))
        facts = sample()
        facts["actor"]["collision_mask"]["layers"] = ["water", "player"]
        with self.assertRaisesRegex(FactsError, "layers must be unique and sorted"):
            validate_facts(sealed(facts))

    def test_unknown_coverage_and_unscoped_equipment_reject(self):
        facts = sample()
        facts["coverage"]["outside"] = "free"
        with self.assertRaises(FactsError):
            validate_facts(sealed(facts))
        facts = sample()
        facts["actor"]["armor"] = [{"name": "power-armor", "quality": "normal"}]
        with self.assertRaisesRegex(FactsError, "Equipment coverage"):
            validate_facts(sealed(facts))

    def test_generated_ids_and_ticks_cannot_silently_enter_semantic_identity(self):
        for target, name in (("metadata", "prepared_tick"), ("actor", "unit_number")):
            facts = sample()
            facts[target][name] = 1
            with self.assertRaisesRegex(FactsError, "missing/unknown fields"):
                validate_facts(sealed(facts))

    def test_bounds_and_metadata_limits_fail(self):
        for mutate in (lambda facts: facts["metadata"].update(fixture_version=True),
                       lambda facts: facts["metadata"].update(state_key="x" * 257),
                       lambda facts: facts["metadata"].update(goal={"x": 3, "y": 1}),
                       lambda facts: facts["coverage"]["bounds"]["right_bottom"].update(x=100_000)):
            facts = sample()
            mutate(facts)
            with self.assertRaises(FactsError):
                validate_facts(sealed(facts))

    def test_duplicate_json_keys_nonfinite_values_and_file_hash(self):
        with tempfile.TemporaryDirectory(prefix="scv-facts-contract-") as directory:
            path = Path(directory) / "facts.json"
            path.write_text(json.dumps(sample()), encoding="utf-8")
            self.assertEqual(read_facts(path)["facts_hash"], sample()["facts_hash"])
            original_sha = sha256_file(path)
            path.write_text('{"metadata": {}, "metadata": {}}', encoding="utf-8")
            with self.assertRaisesRegex(FactsError, "Duplicate JSON key"):
                read_facts(path)
            self.assertNotEqual(sha256_file(path), original_sha)
            for token in ("NaN", "Infinity", "-Infinity", "1e999"):
                path.write_text(json.dumps(sample()).replace('"running_speed": 0.15', f'"running_speed": {token}'), encoding="utf-8")
                with self.subTest(token=token), self.assertRaises(FactsError):
                    read_facts(path)

    def test_empty_lua_container_interoperability(self):
        facts = sample()
        facts["actor"]["armor"] = {}
        facts["actor"]["equipment"] = {}
        self.assertEqual(facts["facts_hash"], fact_hash(facts))
        validate_facts(facts)


if __name__ == "__main__":
    unittest.main()
