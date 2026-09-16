"""Boundaries for recorded reference packaging; no Factorio process is started."""
from __future__ import annotations

import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from compare_saved import ALGORITHMS, CASE_IDS, PROTOCOL as COMPARISON_PROTOCOL
import unified_lab


def source_matrix(corpus: Path):
    cases = [{"id": identifier, "facts_hash": "facts:" + identifier,
              "save_sha256": "zip:" + identifier, "expected_path": identifier != "unreachable-box"}
             for identifier in CASE_IDS]
    rows = []
    for case in cases:
        complete = case["expected_path"]
        for algorithm in ALGORITHMS:
            native = {
                "protocol": COMPARISON_PROTOCOL, "case_id": case["id"], "algorithm": algorithm,
                "source_facts_hash": case["facts_hash"], "source_verified": True,
                "loaded_from_save": True, "runtime_build_calls": 0,
                "expected_path": complete, "passed": True,
                "source_snapshot_hash": "snapshot:" + case["id"],
                "source_query_hash": "query:" + case["id"],
                "assertions": [{"name": "native-terminal", "passed": True}],
                "plans": [{"algorithm": algorithm, "pass": "cold",
                           "outcome": "success" if complete else "no-path",
                           "final_path": [{"x": 0, "y": 0}, {"x": 3, "y": 4}] if complete else [],
                           "final_length": 5 if complete else 0}],
                "native": {"outcome": "arrived" if complete else "no-path",
                           "reason": "inside-goal" if complete else "bounded-no-path"},
            }
            rows.append({"case_id": case["id"], "algorithm": algorithm, "passed": True,
                         "source_facts_hash": case["facts_hash"], "source_save_sha256": case["save_sha256"],
                         "capture_identity": [native["source_snapshot_hash"], native["source_query_hash"]],
                         "native_report": native})
    report = {"protocol": COMPARISON_PROTOCOL, "schema_version": 1, "passed": 44, "failed": 0,
              "matrix_passed": True, "source_corpus": str(corpus), "rows": rows}
    return cases, report


def lab_status(case, index=1, phase="complete"):
    algorithm = ALGORITHMS[index - 1] if case["domain"] == "static" else "production-v1"
    result = {"passed": True, "assertions": [{"name": "native-terminal", "passed": True}]}
    if case["domain"] == "static":
        outcome = "no-path" if case["id"] == "unreachable-box" else "arrived"
        result.update(case_id=case["id"], algorithm=algorithm,
                      native={"outcome": outcome, "reason": "native-terminal"})
    else:
        result.update(id=case["id"], terminal_state="arrived", reason="native-terminal")
    return {"ok": True, "protocol": unified_lab.PROTOCOL, "case_id": case["id"],
            "domain": case["domain"], "algorithm_index": index, "algorithm": algorithm,
            "phase": phase, "paused": True, "free_mode": False,
            "child": {"case_id": case["id"]}, "result": result}


class UnifiedReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="scv-unified-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.report_path = self.root / "comparison.json"
        self.cases, self.report = source_matrix(self.root)

    def package(self, report=None, cases=None):
        value = self.report if report is None else report
        catalog = self.cases if cases is None else cases
        with patch.object(unified_lab, "read_json", side_effect=lambda path: value if path == self.report_path else {}), \
                patch.object(unified_lab, "source_cases", return_value=catalog) as source, \
                patch.object(unified_lab, "sha256", return_value="comparison-file-sha"):
            result = unified_lab.references(self.report_path)
            source.assert_called_once_with(self.root.resolve(), {})
            return result

    def assert_rejected(self, report):
        with self.assertRaises(ValueError):
            self.package(report)

    def test_complete_matrix_retains_eleven_cases_three_external_paths_and_source_identity(self):
        result = self.package()
        self.assertEqual(result["schema_version"], 1)
        self.assertEqual(result["comparison_sha256"], "comparison-file-sha")
        self.assertEqual([case["id"] for case in result["cases"]], list(CASE_IDS))
        for source, packaged in zip(self.cases, result["cases"]):
            self.assertEqual(packaged["source_facts_hash"], source["facts_hash"])
            self.assertEqual(packaged["source_save_sha256"], source["save_sha256"])
            self.assertEqual(packaged["fixture_version"], 4)
            self.assertEqual(set(packaged["algorithms"]), set(unified_lab.EXTERNAL))
            for reference in packaged["algorithms"].values():
                self.assertEqual(reference["outcome"], "complete" if source["expected_path"] else "no-path")
                self.assertEqual(reference["predicted_distance"], 5 if source["expected_path"] else 0)
                self.assertEqual(reference["source_snapshot_hash"], "snapshot:" + source["id"])
                self.assertEqual(reference["source_query_hash"], "query:" + source["id"])
        self.assertEqual(result["cases"][-1]["algorithms"]["grid-astar"]["points"], [])

    def test_summary_requires_complete_success_not_partial_or_truthy_values(self):
        for field, value in (("passed", 43), ("failed", 1), ("matrix_passed", False),
                             ("matrix_passed", "true")):
            altered = copy.deepcopy(self.report)
            altered[field] = value
            with self.subTest(field=field, value=value):
                self.assert_rejected(altered)

    def test_missing_and_duplicate_rows_cannot_disappear_from_denominator(self):
        for rows in (self.report["rows"][:-1],
                     self.report["rows"][:-1] + [copy.deepcopy(self.report["rows"][0])]):
            altered = copy.deepcopy(self.report)
            altered["rows"] = rows
            self.assert_rejected(altered)

    def test_unknown_algorithm_cannot_replace_a_production_matrix_member(self):
        altered = copy.deepcopy(self.report)
        altered["rows"][0]["algorithm"] = "unreviewed-backend"
        self.assert_rejected(altered)

    def test_false_or_nonboolean_row_passed_is_rejected_even_for_production(self):
        for index in (0, 1):
            for passed in (False, "false", "true", 1):
                altered = copy.deepcopy(self.report)
                altered["rows"][index]["passed"] = passed
                with self.subTest(algorithm=altered["rows"][index]["algorithm"], passed=passed):
                    self.assert_rejected(altered)

    def test_each_row_must_match_source_facts_and_zip(self):
        for index in (0, 1):
            for field in ("source_facts_hash", "source_save_sha256"):
                altered = copy.deepcopy(self.report)
                altered["rows"][index][field] = "another-source"
                with self.subTest(index=index, field=field):
                    self.assert_rejected(altered)

    def test_native_load_and_no_rebuild_are_strictly_verified(self):
        for field, value in (("source_verified", False), ("source_verified", 1),
                             ("loaded_from_save", False), ("loaded_from_save", 1),
                             ("runtime_build_calls", 1), ("runtime_build_calls", False),
                             ("runtime_build_calls", 0.0)):
            altered = copy.deepcopy(self.report)
            altered["rows"][1]["native_report"][field] = value
            with self.subTest(field=field, value=value):
                self.assert_rejected(altered)

    def test_inner_native_report_identity_cannot_be_relabelled_by_outer_row(self):
        for field, value in (("case_id", "other-map"), ("source_facts_hash", "other-facts"),
                             ("algorithm", "source-polygons"), ("expected_path", False),
                             ("source_snapshot_hash", "other-snapshot"), ("source_query_hash", "other-query")):
            altered = copy.deepcopy(self.report)
            altered["rows"][1]["native_report"][field] = value
            with self.subTest(field=field):
                self.assert_rejected(altered)

    def test_native_failed_assertions_or_guard_are_not_successful_recordings(self):
        mutations = (
            lambda native: native.update(passed=False),
            lambda native: native.update(assertions=[]),
            lambda native: native.update(assertions=[{"passed": False}]),
            lambda native: native.update(assertions=[{"passed": "true"}]),
            lambda native: native["native"].update(reason="tick-guard"),
        )
        for mutate in mutations:
            altered = copy.deepcopy(self.report)
            mutate(altered["rows"][1]["native_report"])
            self.assert_rejected(altered)

    def test_unreachable_requires_real_no_path_not_any_nonarrival(self):
        for outcome in ("failed", "timeout", "partial", "cancelled", "unsupported", "running"):
            altered = copy.deepcopy(self.report)
            row = next(row for row in altered["rows"] if row["case_id"] == "unreachable-box" and row["algorithm"] == "grid-astar")
            row["native_report"]["native"]["outcome"] = outcome
            with self.subTest(outcome=outcome):
                self.assert_rejected(altered)

    def test_plan_terminal_must_match_saved_task(self):
        for identifier, outcome in (("open-diagonal", "no-path"), ("unreachable-box", "success"),
                                    ("unreachable-box", "budget-exhausted")):
            altered = copy.deepcopy(self.report)
            row = next(row for row in altered["rows"] if row["case_id"] == identifier and row["algorithm"] == "grid-astar")
            row["native_report"]["plans"][-1]["outcome"] = outcome
            with self.subTest(case=identifier, outcome=outcome):
                self.assert_rejected(altered)

    def test_missing_source_catalog_case_is_not_an_eleven_case_package(self):
        with self.assertRaises(ValueError):
            self.package(cases=self.cases[:-1])

    def test_source_validation_failure_propagates_without_publishing_references(self):
        with patch.object(unified_lab, "read_json", return_value=self.report), \
                patch.object(unified_lab, "source_cases", side_effect=ValueError("archived source mods changed")):
            with self.assertRaisesRegex(ValueError, "archived source mods changed"):
                unified_lab.references(self.report_path)


class UnifiedPackageTests(unittest.TestCase):
    def test_archive_path_checksum_and_mod_changes_reject_before_native_launch(self):
        with tempfile.TemporaryDirectory(prefix="scv-unified-package-") as directory:
            package = Path(directory)
            original = {"protocol": unified_lab.PROTOCOL, "schema_version": 1,
                        "save_file": "saves/lab.zip", "save_sha256": "original-zip",
                        "mods_sha256": "original-mods", "cases": 56, "static_cases": 11}
            for mutation, archive_hash, mods_hash in (
                ({"save_file": "../escape.zip"}, "original-zip", "original-mods"),
                ({}, "changed-zip", "original-mods"),
                ({}, "original-zip", "changed-mods"),
            ):
                manifest = {**original, **mutation}
                with patch.object(unified_lab, "read_json", return_value=manifest), \
                        patch.object(unified_lab, "sha256", return_value=archive_hash), \
                        patch.object(unified_lab, "mod_fingerprint", return_value=mods_hash), \
                        patch.object(unified_lab, "native") as launch:
                    with self.subTest(mutation=mutation, zip=archive_hash, mods=mods_hash), self.assertRaises(ValueError):
                        unified_lab.test(Path("factorio.exe"), package, package / "artifacts", 1)
                    launch.assert_not_called()

    def test_native_status_requires_complete_true_pass(self):
        case = {"id": "open-diagonal", "domain": "static"}
        unified_lab.verify_native(lab_status(case), case, 1)
        for phase in ("failed", "running", "planned", "prepared"):
            with self.subTest(phase=phase), self.assertRaises(ValueError):
                unified_lab.verify_native(lab_status(case, phase=phase), case, 1)
        for passed in (False, "true", 1, None):
            status = lab_status(case)
            status["result"]["passed"] = passed
            with self.subTest(passed=passed), self.assertRaises(ValueError):
                unified_lab.verify_native(status, case, 1)
        status = lab_status(case)
        status["result"] = None
        with self.assertRaises(ValueError):
            unified_lab.verify_native(status, case, 1)

    def test_selection_requires_exact_case_domain_algorithm_and_paused_origin(self):
        case = {"id": "open-diagonal", "domain": "static"}
        for index in range(1, 5):
            unified_lab.verify_selection(lab_status(case, index, "prepared"), case, index)
        for field, value in (("case_id", "long-wall-return"), ("domain", "dynamic"),
                             ("algorithm_index", 1), ("algorithm", "production-v1"),
                             ("phase", "complete"), ("paused", False), ("paused", 1),
                             ("free_mode", True), ("free_mode", 0)):
            status = lab_status(case, 2, "prepared")
            status[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                unified_lab.verify_selection(status, case, 2)
        status = lab_status(case, 2, "prepared")
        status["child"]["case_id"] = "long-wall-return"
        with self.assertRaises(ValueError):
            unified_lab.verify_selection(status, case, 2)

    def test_terminal_cannot_reuse_another_case_or_algorithm_success(self):
        case = {"id": "open-diagonal", "domain": "static"}
        for field, value in (("case_id", "long-wall-return"), ("domain", "dynamic"),
                             ("algorithm_index", 1), ("algorithm_index", 2.0),
                             ("algorithm", "production-v1")):
            status = lab_status(case, 2)
            status[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                unified_lab.verify_native(status, case, 2)
        status = lab_status(case, 2)
        status["child"]["case_id"] = "long-wall-return"
        with self.assertRaises(ValueError):
            unified_lab.verify_native(status, case, 2)
        for field, value in (("case_id", "long-wall-return"), ("algorithm", "production-v1")):
            status = lab_status(case, 2)
            status["result"][field] = value
            with self.subTest(result_field=field), self.assertRaises(ValueError):
                unified_lab.verify_native(status, case, 2)

    def test_terminal_requires_nonempty_all_true_boolean_native_assertions(self):
        for case in ({"id": "open-diagonal", "domain": "static"},
                     {"id": "same-force-normal-follower", "domain": "gate-actions"}):
            for assertions in ([], None, [{"passed": False}], [{"passed": "true"}],
                               [{"passed": 1}], [{"passed": True}, {"passed": False}], [{}], ["bad"]):
                status = lab_status(case)
                status["result"]["assertions"] = assertions
                with self.subTest(case=case["id"], assertions=assertions), self.assertRaises(ValueError):
                    unified_lab.verify_native(status, case, 1)

    def test_static_terminal_must_agree_with_reachable_or_unreachable_case(self):
        for identifier in ("open-diagonal", "unreachable-box"):
            case = {"id": identifier, "domain": "static"}
            unified_lab.verify_native(lab_status(case, 4), case, 4)
            invalid = ("arrived", "failed", "running", "timeout") if identifier == "unreachable-box" \
                else ("no-path", "failed", "running", "timeout")
            for outcome in invalid:
                status = lab_status(case, 4)
                status["result"]["native"]["outcome"] = outcome
                with self.subTest(case=identifier, outcome=outcome), self.assertRaises(ValueError):
                    unified_lab.verify_native(status, case, 4)
            status = lab_status(case, 4)
            status["result"]["native"]["reason"] = "tick-guard"
            with self.assertRaises(ValueError):
                unified_lab.verify_native(status, case, 4)

    def test_domain_run_requires_own_id_fixed_configuration_and_terminal(self):
        for domain in ("gate-actions", "dynamic", "belt-controller"):
            case = {"id": "domain-specimen", "domain": domain}
            unified_lab.verify_selection(lab_status(case, phase="prepared"), case, 1)
            for terminal in ("arrived", "rejected", "replan-required"):
                status = lab_status(case)
                status["result"]["terminal_state"] = terminal
                unified_lab.verify_native(status, case, 1)
            for field, value in (("id", "another-case"), ("terminal_state", "failed"),
                                 ("terminal_state", "running"), ("terminal_state", "verified")):
                status = lab_status(case)
                status["result"][field] = value
                with self.subTest(domain=domain, field=field, value=value), self.assertRaises(ValueError):
                    unified_lab.verify_native(status, case, 1)
            status = lab_status(case)
            status.update(algorithm_index=2, algorithm="grid-astar")
            with self.subTest(domain=domain, wrong_configuration=True), self.assertRaises(ValueError):
                unified_lab.verify_native(status, case, 1)
            status = lab_status(case)
            status["result"]["reason"] = "tick-guard"
            with self.assertRaises(ValueError):
                unified_lab.verify_native(status, case, 1)


if __name__ == "__main__":
    unittest.main()
