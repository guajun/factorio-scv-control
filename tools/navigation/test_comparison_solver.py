"""Saved-query worker tests; Factorio replay remains the native oracle."""

import copy
import importlib.metadata
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from canonical import content_hash
from comparison_solver import BACKEND, admission_delta, compare
from solver import ValidationError, solve, validate_result
from test_solver import bind, example


def captured():
    snapshot, query = example()
    return {"id": "saved-query", "snapshot": snapshot, "query": query}


def derived(case):
    """Transport fixture, not another solver or native geometry simulator."""
    source, source_query = case["snapshot"], case["query"]
    snapshot, query = copy.deepcopy(source), copy.deepcopy(source_query)
    snapshot["snapshot_id"] += ":" + BACKEND
    snapshot["source_input"] = {"snapshot_id": source["snapshot_id"],
                                "snapshot_hash": content_hash(source), "query_hash": source_query["query_hash"]}
    snapshot["graph"] = {"nodes": [{"id": "start", "position": query["start"]},
                                    {"id": "goal", "position": query["goal"]}],
                         "edges": [{"from": "start", "to": "goal", "distance": 10}]}
    query.update(snapshot_id=snapshot["snapshot_id"], query_id=query["query_id"] + ":" + BACKEND,
                 start_node="start", goal_node="goal")
    query["data_ref"].update(backend_id=BACKEND, backend_version="1", snapshot_id=snapshot["snapshot_id"],
                              generation_id=query["data_ref"]["generation_id"] + ":" + BACKEND,
                              config_hash=content_hash({"test": "derived-transport"}))
    bind(snapshot, query)
    return {"id": case["id"], "snapshot": snapshot, "query": query,
            "result": solve(snapshot, query)}


def polygon_fixture():
    case = captured()
    snapshot, query = case["snapshot"], case["query"]
    snapshot["actor"]["collision_mask"] = {"layers": {"player": True}}
    snapshot["graph"]["representation"] = {"clearance_margin": 0.1}
    snapshot["geometry"]["tiles"] = [
        {"id": f"tile:{x},{y}", "position": {"x": x, "y": y},
         "name": "refined-concrete", "collision_mask": {"layers": {"ground_tile": True}}}
        for x in range(-1, 11) for y in range(-1, 6)]
    snapshot["geometry"]["entities"] = [{
        "id": "barrier", "type": "wall", "name": "stone-wall", "direction": 0,
        "position": {"x": 4.5, "y": 0.5},
        "bounding_box": {"left_top": {"x": 4, "y": -1}, "right_bottom": {"x": 5, "y": 2}},
        "collision_mask": {"layers": {"player": True}}}]
    snapshot["graph"]["edges"] = []
    query["required_capabilities"] = ["directed-graph-v1", "distance", "finite-bounds"]
    bind(snapshot, query)
    return case


def pinned_polygon_dependencies():
    expected = {"extremitypathfinder": "2.7.2", "shapely": "2.1.2", "numpy": "1.26.4", "networkx": "3.5"}
    try:
        return all(importlib.metadata.version(name) == version for name, version in expected.items())
    except importlib.metadata.PackageNotFoundError:
        return False


class ComparisonSolverTests(unittest.TestCase):
    def test_grid_reference_and_repeated_runs_preserve_saved_input(self):
        case = captured()
        original = copy.deepcopy(case)
        astar = compare(case, "grid-astar", repeats=2)
        dijkstra = compare(case, "grid-dijkstra", repeats=0)
        self.assertEqual(case, original)
        self.assertEqual(astar["case"]["result"]["outcome"], "complete")
        self.assertEqual(astar["case"]["result"]["predicted"], dijkstra["case"]["result"]["predicted"])
        self.assertTrue(astar["metrics"]["same_graph_dijkstra"]["objective_matches"])
        self.assertEqual(astar["source"]["snapshot_hash"], case["query"]["data_ref"]["snapshot_hash"])
        self.assertEqual(astar["source"]["query_hash"], case["query"]["query_hash"])
        self.assertNotIn("derived", astar["admission"])
        self.assertEqual(len(astar["timing"]["repeated_end_to_end_ms"]), 2)
        self.assertFalse(astar["timing"]["repeated_end_to_end_reuses_prepared_map"])
        self.assertFalse(astar["timing"]["warm_prepared_search_available"])
        self.assertFalse(astar["metrics"]["native_performance_evidence"])

    def test_budget_no_path_and_unsupported_are_not_dropped(self):
        for expected in ("no-path", "budget-exhausted", "unsupported"):
            case = captured()
            if expected == "no-path":
                case["snapshot"]["graph"]["edges"] = []
            elif expected == "budget-exhausted":
                case["query"]["budget"]["max_expansions"] = 0
            else:
                case["query"]["required_capabilities"].append("automatic-gate-actions")
            bind(case["snapshot"], case["query"])
            with self.subTest(expected=expected):
                report = compare(case, "grid-astar", repeats=1)
                self.assertEqual(report["id"], case["id"])
                self.assertEqual(report["case"]["result"]["outcome"], expected)
                self.assertEqual(report["case"]["result"]["points"], [])
                self.assertTrue(report["metrics"]["comparison_passed"])
                self.assertFalse(report["metrics"]["same_graph_dijkstra"]["cost_comparison_available"])

    def test_delta_reconstructs_derived_identity_without_resending_geometry(self):
        case = captured()
        solved = derived(case)
        delta = admission_delta(case, solved)
        self.assertEqual(set(delta["derived"]), {"snapshot_id", "source_input", "graph", "query"})
        rebuilt = copy.deepcopy(case["snapshot"])
        rebuilt.update({key: value for key, value in delta["derived"].items() if key != "query"})
        self.assertEqual(rebuilt, solved["snapshot"])
        self.assertEqual(content_hash(rebuilt), solved["query"]["data_ref"]["snapshot_hash"])
        validate_result(rebuilt, delta["derived"]["query"], delta["result"])

    def test_hash_rebinding_cannot_authorize_changed_geometry_or_task(self):
        for mutation in ("geometry", "actor", "coverage", "budget", "attempt", "source_input", "revision"):
            case = captured()
            solved = derived(case)
            snapshot, query = solved["snapshot"], solved["query"]
            if mutation == "geometry":
                snapshot["geometry"]["entities"] = [{"id": "invented-wall"}]
            elif mutation == "actor":
                snapshot["actor"]["collision_box"]["left_top"]["x"] -= 0.1
            elif mutation == "coverage":
                snapshot["coverage"]["bounds"]["left_top"]["x"] -= 1
            elif mutation == "budget":
                query["budget"]["max_expansions"] += 1
            elif mutation == "attempt":
                query["attempt_id"] += ":other"
            elif mutation == "source_input":
                snapshot["source_input"]["query_hash"] = "unrelated"
            else:
                snapshot["revisions"]["topology"] += 1
                query["data_ref"]["revisions"] = copy.deepcopy(snapshot["revisions"])
            bind(snapshot, query)
            solved["result"] = solve(snapshot, query)
            with self.subTest(mutation=mutation), self.assertRaises(ValidationError):
                admission_delta(case, solved)

    def test_grid_query_cannot_be_replaced_without_a_derived_snapshot(self):
        case = captured()
        solved = {**copy.deepcopy(case), "result": solve(case["snapshot"], case["query"])}
        solved["query"]["attempt_id"] = "other-attempt"
        bind(solved["snapshot"], solved["query"])
        solved["result"] = solve(solved["snapshot"], solved["query"])
        with self.assertRaisesRegex(ValidationError, "without a derived snapshot"):
            admission_delta(case, solved)

    def test_missing_optional_backend_is_explicit_unsupported_case(self):
        case = captured()
        with patch("comparison_solver.polygon_backend", side_effect=ModuleNotFoundError("extremitypathfinder")):
            report = compare(case, "source-polygons", repeats=1)
        self.assertEqual(report["case"]["result"]["outcome"], "unsupported")
        self.assertIn("dependency-unavailable", report["case"]["result"]["metrics"]["reason"])
        self.assertEqual(report["case"]["snapshot"], case["snapshot"])
        self.assertFalse(report["timing"]["warm_prepared_search_available"])

    def test_repeated_outcome_change_is_visible_in_comparison(self):
        case = captured()
        actual_solve = solve
        calls = 0
        def changes(snapshot, query, algorithm):
            nonlocal calls
            calls += 1
            result = actual_solve(snapshot, query, algorithm)
            if calls > 1:
                result["metrics"]["unexpected_new_field"] = True
            return result
        with patch("comparison_solver.solve", side_effect=changes):
            report = compare(case, "grid-dijkstra", repeats=1)
        self.assertFalse(report["metrics"]["comparison_passed"])
        self.assertEqual(report["metrics"]["comparison_issues"], ["repeated-result-changed:1"])

    def test_stale_source_query_and_invalid_repeat_budget_fail(self):
        case = captured()
        case["query"]["budget"]["max_points"] += 1
        with self.assertRaises(ValidationError):
            compare(case, "grid-astar")
        for repeats in (-1, 21, True, 0.5):
            with self.subTest(repeats=repeats), self.assertRaises(ValidationError):
                compare(captured(), "grid-astar", repeats)

    def test_cli_preserves_input_and_keeps_no_path_as_valid_output(self):
        case = captured()
        case["snapshot"]["graph"]["edges"] = []
        bind(case["snapshot"], case["query"])
        with tempfile.TemporaryDirectory(prefix="scv-comparison-worker-") as folder:
            source, output = Path(folder) / "capture.json", Path(folder) / "result.json"
            source.write_text(json.dumps(case), encoding="utf-8")
            before = source.read_bytes()
            command = [sys.executable, str(Path(__file__).with_name("comparison_solver.py")),
                       "--input", str(source), "--output", str(output), "--algorithm", "grid-dijkstra", "--repeats", "0"]
            result = subprocess.run(command, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["case"]["result"]["outcome"], "no-path")
            self.assertEqual(source.read_bytes(), before)

    @unittest.skipUnless(pinned_polygon_dependencies(), "optional pinned polygon environment unavailable")
    def test_real_polygon_backend_keeps_geometry_and_uses_prepared_warm_query(self):
        case = polygon_fixture()
        report = compare(case, "source-polygons", repeats=1)
        self.assertEqual(report["case"]["result"]["outcome"], "complete")
        self.assertEqual(report["metrics"]["backend_record"]["captured_grid"]["outcome"], "no-path")
        self.assertTrue(report["metrics"]["same_graph_dijkstra"]["objective_matches"])
        self.assertEqual(report["case"]["snapshot"]["geometry"], case["snapshot"]["geometry"])
        self.assertTrue(report["timing"]["warm_prepared_search_available"])
        self.assertEqual(len(report["timing"]["warm_prepared_search_ms"]), 1)
        self.assertEqual(report["case"]["query"]["data_ref"]["backend_id"], BACKEND)
        self.assertTrue(report["metrics"]["comparison_passed"])


if __name__ == "__main__":
    unittest.main()
