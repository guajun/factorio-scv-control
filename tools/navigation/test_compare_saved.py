"""Host acceptance boundaries; native loading is covered by the saved-map suite."""

import copy
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from compare_saved import (CORPUS_PROTOCOL, PROTOCOL, check_matrix, mod_fingerprint,
                           main, profile_report, published, sha256, source_cases,
                           verify_capture, verify_origin, verify_result)
from test_solver import example


def source_case(expected_path=True):
    return {"id": "open-diagonal" if expected_path else "unreachable-box",
            "facts_hash": "source-facts", "save_sha256": "source-zip-sha256",
            "expected_path": expected_path}


def native_report(case, algorithm="grid-astar"):
    return {"protocol": PROTOCOL, "case_id": case["id"], "algorithm": algorithm,
            "source_facts_hash": case["facts_hash"], "source_verified": True,
            "loaded_from_save": True, "runtime_build_calls": 0,
            "expected_path": case["expected_path"], "passed": True,
            "assertions": [{"name": "expected-native-outcome", "passed": True}],
            "plans": [{"algorithm": algorithm, "pass": "cold",
                       "outcome": "success" if case["expected_path"] else "no-path"}],
            "native": {"outcome": "arrived" if case["expected_path"] else "no-path",
                       "reason": "goal-reached" if case["expected_path"] else "planner-bounded-no-path"}}


def matrix_rows(case, algorithms):
    return [{"case_id": case["id"], "algorithm": algorithm, "passed": False,
             "source_save_sha256": case["save_sha256"], "source_facts_hash": case["facts_hash"],
             "capture_identity": ["snapshot-hash", "query-hash"]} for algorithm in algorithms]


class SavedComparisonBoundaryTests(unittest.TestCase):
    def test_matrix_denominator_keeps_failed_members_and_rejects_missing_or_duplicates(self):
        case, algorithms = source_case(), ["production-v1", "grid-astar", "grid-dijkstra", "source-polygons"]
        rows = matrix_rows(case, algorithms)
        # A valid failed row stays in the matrix instead of disappearing from
        # the denominator and making a misleading all-success report.
        rows[1]["error"] = "external solver timeout"
        check_matrix(rows, [case], algorithms)
        for altered in (rows[:-1], rows + [copy.deepcopy(rows[0])], rows[1:] + [copy.deepcopy(rows[1])]):
            with self.subTest(size=len(altered)), self.assertRaisesRegex(ValueError, "dropped or duplicated"):
                check_matrix(altered, [case], algorithms)

    def test_matrix_requires_identical_source_zip_facts_and_captured_query(self):
        case, algorithms = source_case(), ["production-v1", "grid-astar"]
        for field, value in (("source_save_sha256", "other-zip"), ("source_facts_hash", "other-facts"),
                             ("capture_identity", ["other-snapshot", "query-hash"]),
                             ("capture_identity", ["snapshot-hash", "other-query"])):
            rows = matrix_rows(case, algorithms)
            rows[1][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                check_matrix(rows, [case], algorithms)

    def test_grid_reference_disagreement_fails_matrix(self):
        case, algorithms = source_case(), ["grid-astar", "grid-dijkstra"]
        rows = matrix_rows(case, algorithms)
        for row in rows:
            row["solver"] = {"metrics": {"same_graph_dijkstra": {
                "outcome": "complete", "predicted": {"distance": 10}}}}
        check_matrix(rows, [case], algorithms)
        rows[1]["solver"]["metrics"]["same_graph_dijkstra"]["predicted"]["distance"] = 11
        with self.assertRaisesRegex(ValueError, "inconsistent Dijkstra"):
            check_matrix(rows, [case], algorithms)

    def test_origin_requires_fresh_load_and_zero_geometry_setup(self):
        case = source_case()
        report = native_report(case)
        verify_origin(report, case)
        for field, value in (("loaded_from_save", False), ("loaded_from_save", 1),
                             ("runtime_build_calls", 1), ("runtime_build_calls", False),
                             ("runtime_build_calls", 0.0), ("source_facts_hash", "changed"),
                             ("case_id", "another-map")):
            altered = copy.deepcopy(report)
            altered[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                verify_origin(altered, case)

    def test_capture_requires_map_identity_and_valid_exact_query_hash(self):
        case = source_case()
        snapshot, query = example()
        work = {"id": case["id"], "source_facts_hash": case["facts_hash"], "snapshot": snapshot, "query": query}
        self.assertEqual(verify_capture(work, case), (query["data_ref"]["snapshot_hash"], query["query_hash"]))
        for field, value in (("id", "another-map"), ("source_facts_hash", "changed")):
            altered = copy.deepcopy(work)
            altered[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                verify_capture(altered, case)
        altered = copy.deepcopy(work)
        altered["query"]["budget"]["max_points"] -= 1
        with self.assertRaises(ValueError):
            verify_capture(altered, case)

    def test_native_result_requires_actual_boolean_assertions_and_matching_plans(self):
        case = source_case()
        report = native_report(case)
        self.assertTrue(verify_result(report, case, "grid-astar"))
        for assertions in ([], None, [{"passed": "true"}], [{"passed": 1}], ["malformed"], [None]):
            altered = copy.deepcopy(report)
            altered["assertions"] = assertions
            with self.subTest(assertions=assertions), self.assertRaises(ValueError):
                verify_result(altered, case, "grid-astar")
        for plans in ([], None, [{"algorithm": "source-polygons"}], ["malformed"], [None]):
            altered = copy.deepcopy(report)
            altered["plans"] = plans
            with self.subTest(plans=plans), self.assertRaises(ValueError):
                verify_result(altered, case, "grid-astar")
        altered = copy.deepcopy(report)
        altered["assertions"][0]["passed"] = False
        self.assertFalse(verify_result(altered, case, "grid-astar"))

    def test_no_path_must_match_saved_expectation_and_true_planning_exhaustion(self):
        reachable, unreachable = source_case(), source_case(False)
        report = native_report(reachable)
        report["native"]["outcome"] = "no-path"
        self.assertFalse(verify_result(report, reachable, "grid-astar"))
        report = native_report(unreachable)
        self.assertTrue(verify_result(report, unreachable, "grid-astar"))
        for outcome in ("budget-exhausted", "unsupported", "error", "cancelled", "partial", "success"):
            altered = copy.deepcopy(report)
            altered["plans"][-1]["outcome"] = outcome
            with self.subTest(outcome=outcome):
                try:
                    success = verify_result(altered, unreachable, "grid-astar")
                except ValueError:
                    success = False
                self.assertFalse(success, "non-no-path planner outcome accepted as native no-path")

    def test_guard_and_wrong_case_outcomes_cannot_be_success(self):
        for expected in (True, False):
            case = source_case(expected)
            report = native_report(case)
            report["native"]["reason"] = "tick-guard"
            with self.subTest(expected=expected), self.assertRaisesRegex(ValueError, "watchdog"):
                verify_result(report, case, "grid-astar")

    def test_native_outcome_requires_object_and_string_status(self):
        case = source_case()
        for native in (None, [], "arrived", {}, {"outcome": True}, {"outcome": 1}):
            report = native_report(case)
            report["native"] = native
            with self.subTest(native=native), self.assertRaisesRegex(ValueError, "outcome absent or malformed"):
                verify_result(report, case, "grid-astar")

    def test_nonfinite_watchdog_is_rejected_before_any_server_or_corpus_work(self):
        for timeout in ("inf", "-inf", "nan", "0", "-1"):
            with self.subTest(timeout=timeout), patch("compare_saved.executable_path") as binary, \
                    patch("compare_saved.tempfile.mkdtemp") as artifact, \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                main(["--timeout=" + timeout])
            self.assertEqual(raised.exception.code, 2)
            binary.assert_not_called()
            artifact.assert_not_called()
        case = source_case()
        for field, value in (("source_verified", False), ("expected_path", False),
                             ("algorithm", "source-polygons"), ("protocol", "old-protocol")):
            report = native_report(case)
            report[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                verify_result(report, case, "grid-astar")

    def test_source_manifest_rejects_changed_archive_and_saved_task(self):
        with tempfile.TemporaryDirectory(prefix="scv-static-source-contract-") as folder:
            corpus = Path(folder)
            (corpus / "saves").mkdir()
            (corpus / "facts").mkdir()
            (corpus / "mods").mkdir()
            archive, facts_file = corpus / "saves/map.zip", corpus / "facts/map.json"
            # A format-only archive checks the host's digest boundary here.
            # Actual openability is tested by launching each real source ZIP.
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("map/level-init.dat", b"format-only-unit-fixture")
            facts = {"facts_hash": "source-facts", "metadata": {"case_id": "open-diagonal",
                     "scope": {"fixture_definition": {"expected_path": True}}}}
            facts_file.write_text(json.dumps(facts), encoding="utf-8")
            case = {**source_case(), "save_file": "saves/map.zip", "facts_file": "facts/map.json",
                    "save_sha256": sha256(archive), "facts_sha256": sha256(facts_file)}
            manifest = {"protocol": CORPUS_PROTOCOL, "schema_version": 1, "case_count": 1,
                        "catalog_complete": False, "source_mods_sha256": mod_fingerprint(corpus / "mods"), "cases": [case]}
            # Facts' full schema/canonical validation has its own shared tests;
            # this test isolates source-file and task binding at the host.
            with patch("compare_saved.read_facts", return_value=facts):
                self.assertEqual(source_cases(corpus, manifest), [case])
                altered = copy.deepcopy(manifest)
                altered["cases"][0]["expected_path"] = False
                with self.assertRaisesRegex(ValueError, "task expectation"):
                    source_cases(corpus, altered)
                with zipfile.ZipFile(archive, "a") as output:
                    output.writestr("map/modified.dat", b"changed native source")
                with self.assertRaisesRegex(ValueError, "file checksum"):
                    source_cases(corpus, manifest)

    def test_complete_source_catalog_cannot_be_relabelled_after_dropping_cases(self):
        manifest = {"protocol": CORPUS_PROTOCOL, "schema_version": 1, "case_count": 1,
                    "catalog_complete": True, "cases": [source_case()]}
        with self.assertRaisesRegex(ValueError, "incomplete static source matrix"):
            source_cases(Path("."), manifest)

    def test_published_artifact_has_confined_path_and_exact_byte_count(self):
        with tempfile.TemporaryDirectory(prefix="scv-static-publication-") as folder:
            data = Path(folder)
            (data / "script-output").mkdir()
            path = data / "script-output/capture.json"
            path.write_text("{}", encoding="utf-8")
            self.assertEqual(published(data, {"path": "capture.json", "bytes": 2}), path)
            for descriptor in ({"path": "../capture.json", "bytes": 2},
                               {"path": "capture.json", "bytes": 1},
                               {"path": "capture.json", "bytes": 2.0}):
                with self.subTest(descriptor=descriptor), self.assertRaises(ValueError):
                    published(data, descriptor)

    def test_profiler_preserves_peak_and_marks_real_hook_budget_overrun(self):
        with tempfile.TemporaryDirectory(prefix="scv-static-profile-") as folder:
            path = Path(folder) / "profile.jsonl"
            records = [{"kind": "hook", "hook": "plan", "duration": "Duration: 1.0ms"},
                       {"kind": "hook", "hook": "plan", "duration": "Duration: 20.0ms"},
                       {"kind": "aggregate", "hook": "plan", "count": 2, "duration": "Duration: 21.0ms"}]
            path.write_text("\n".join(json.dumps(item) for item in records), encoding="utf-8")
            result = profile_report(path)
            self.assertTrue(result["single_hook_over_60ups_budget"])
            self.assertEqual(result["hooks"]["plan"], {"count": 2, "total_ms": 21, "mean_ms": 10.5,
                                                        "max_ms": 20, "p95_ms": 20})

    def test_profiler_rejects_lost_samples_invalid_durations_and_noninteger_counts(self):
        hook = {"kind": "hook", "hook": "plan", "duration": "Duration: 1.0ms"}
        aggregate = {"kind": "aggregate", "hook": "plan", "count": 1, "duration": "Duration: 1.0ms"}
        variants = [[], [hook], [aggregate], [hook, aggregate, aggregate], [None], [[]], ["not-an-object"],
                    [hook, {**aggregate, "count": 2}], [hook, {**aggregate, "count": True}],
                    [hook, {**aggregate, "count": 1.0}],
                    [{**hook, "duration": "LuaProfiler"}, aggregate],
                    [{**hook, "duration": "Duration: -1.0ms"}, aggregate],
                    [{**hook, "duration": "Duration: " + "9" * 400 + "ms"}, aggregate],
                    [hook, {**aggregate, "hook": "unmatched"}]]
        with tempfile.TemporaryDirectory(prefix="scv-static-profile-boundary-") as folder:
            path = Path(folder) / "profile.jsonl"
            for index, records in enumerate(variants):
                path.write_text("\n".join(json.dumps(item) for item in records), encoding="utf-8")
                with self.subTest(index=index), self.assertRaises(ValueError):
                    profile_report(path)


if __name__ == "__main__":
    unittest.main()
