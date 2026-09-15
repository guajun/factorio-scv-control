import copy
from pathlib import Path
import tempfile
import unittest

from savebench import PROTOCOL, RPC_PROTOCOL, relative_file, save_slug, validate_corpus, validate_replay, script_performance, expected_terminal


class SavedMapBoundaryTests(unittest.TestCase):
    def test_artifact_paths_cannot_escape_corpus(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for value in ("../elsewhere.zip", "/elsewhere.zip", "C:/elsewhere.zip", "saves\\elsewhere.zip", ""):
                with self.subTest(value=value), self.assertRaises(ValueError):
                    relative_file(root, value)
            self.assertEqual(relative_file(root, "saves/map.zip"), root / "saves/map.zip")

    def test_slug_is_safe_bounded_and_avoids_normalization_collisions(self):
        self.assertNotEqual(save_slug("a/b"), save_slug("a:b"))
        self.assertLessEqual(len(save_slug("x" * 1000)), 128)
        self.assertRegex(save_slug("../a:$name"), r"^[a-z0-9-]+$")

    def test_full_corpus_cannot_silently_drop_cases(self):
        manifest = {"protocol": PROTOCOL, "schema_version": 1, "catalog_complete": True,
                    "case_count": 1, "cases": [{"id": "gate", "domain": "gate-actions"}]}
        with self.assertRaisesRegex(ValueError, "missing native cases"):
            validate_corpus(Path("."), manifest)

    def test_generated_map_cannot_masquerade_as_loaded_source(self):
        case = {"id": "gate", "domain": "gate-actions", "facts_hash": "observed-source", "expected_terminal": "arrived"}
        report = {"protocol": RPC_PROTOCOL, "case_id": "gate", "domain": "gate-actions",
                  "source_facts_hash": "observed-source", "source_verified": True,
                  "loaded_from_save": True, "runtime_build_calls": 0,
                  "result": {"id": "gate", "passed": True, "terminal_state": "arrived",
                             "reason": "inside-goal", "assertions": [{"passed": True}],
                             "metrics": {}, "timeline": [{"tick": 1}]}}
        self.assertEqual(validate_replay(report, case)["terminal_state"], "arrived")
        for field, value in (("runtime_build_calls", 1), ("loaded_from_save", False),
                             ("source_verified", False), ("source_facts_hash", "changed")):
            altered = copy.deepcopy(report)
            altered[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_replay(altered, case)
        for field, value in (("passed", False), ("id", "another-case"),
                             ("terminal_state", "running"), ("reason", "tick-guard"),
                             ("terminal_state", "rejected"),
                             ("assertions", []), ("assertions", [{"passed": "true"}])):
            altered = copy.deepcopy(report)
            altered["result"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_replay(altered, case)

    def test_terminal_expectation_comes_from_saved_task(self):
        for fixture, expected in (({}, "arrived"), ({"rejection": "enemy"}, "rejected"),
                                  ({"change": "remove"}, "replan-required")):
            facts = {"metadata": {"domain": "gate-actions", "scope": {"fixture_definition": fixture}}}
            self.assertEqual(expected_terminal(facts), expected)

    def test_native_profiler_reports_frame_overrun_without_hiding_nested_work(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profile.jsonl"
            path.write_text('{"kind":"hook","hook":"on_tick","duration":"Duration: 25.0ms"}\n'
                            '{"kind":"aggregate","hook":"on_tick","count":1,"duration":"Duration: 25.0ms"}\n')
            result = script_performance(path)
            self.assertTrue(result["single_hook_exceeds_60ups_budget"])
            self.assertTrue(result["nested_event_hooks_included_in_on_tick_do_not_sum_twice"])
            self.assertEqual(result["hooks"]["on_tick"]["max_ms"], 25)
            path.write_text('{"kind":"hook","hook":"on_tick","duration":"LuaProfiler"}\n')
            with self.assertRaises(ValueError):
                script_performance(path)


if __name__ == "__main__":
    unittest.main()
