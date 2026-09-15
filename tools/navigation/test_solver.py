"""Reference solver conformance, adversarial import, and objective regressions."""

from __future__ import annotations

import copy
import json
import math
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest

from canonical import CanonicalError, canonical_bytes, content_hash
from solve import lua_module, read_json, solve_bundle
from solver import PROTOCOL, ValidationError, query_hash, solve, validate_result


def example(objective: str = "distance", reverse: bool = False) -> tuple[dict, dict]:
    # Direct route S->G has distance 10 and time 10. Upper detour is distance
    # 20 but time 4. Its reverse takes 40 ticks, so G->S should use direct.
    nodes = {"S": {"x": 0, "y": 0}, "G": {"x": 10, "y": 0},
             "A": {"x": 0, "y": 5}, "B": {"x": 10, "y": 5}}
    edges = []
    for source, target, ticks in [("S", "G", 10), ("G", "S", 10),
                                  ("S", "A", 1), ("A", "B", 2), ("B", "G", 1),
                                  ("G", "B", 10), ("B", "A", 20), ("A", "S", 10)]:
        edges.append({"from": source, "to": target,
                      "distance": math.hypot(nodes[source]["x"] - nodes[target]["x"],
                                             nodes[source]["y"] - nodes[target]["y"]),
                      "travel_ticks": ticks})
    snapshot = {"protocol": PROTOCOL, "kind": "world-snapshot", "snapshot_id": "world:1",
                "world_id": "fixture-world", "surface_id": "surface:1", "captured_tick": 0,
                "actor": {"name": "character", "collision_box": {"left_top": {"x": -0.2, "y": -0.2},
                                                                  "right_bottom": {"x": 0.2, "y": 0.2}}},
                "revisions": {"topology": 1, "motion": 2},
                "coverage": {"bounds": {"left_top": {"x": -1, "y": -1},
                                        "right_bottom": {"x": 11, "y": 6}}, "unknown": "blocked"},
                "geometry": {"entities": [], "tiles": []},
                "graph": {"nodes": [{"id": key, "position": point} for key, point in nodes.items()],
                          "edges": edges}}
    start, goal = ("G", "S") if reverse else ("S", "G")
    query = {"protocol": PROTOCOL, "kind": "navigation-query", "query_id": "request:1",
             "session_id": "load:1", "command_id": "command:1", "attempt_id": "attempt:1",
             "snapshot_id": snapshot["snapshot_id"],
             "data_ref": {"backend_id": "fixture-directed-graph", "backend_version": "1",
                          "generation_id": "gen:1", "snapshot_id": snapshot["snapshot_id"],
                          "snapshot_hash": "", "config_hash": content_hash({}), "actor_hash": "",
                          "revisions": copy.deepcopy(snapshot["revisions"])},
             "start": copy.deepcopy(nodes[start]), "goal": copy.deepcopy(nodes[goal]),
             "start_node": start, "goal_node": goal, "goal_tolerance": 0.1,
             "objective": {"id": objective, "units": "tiles" if objective == "distance" else "ticks"},
             "required_capabilities": ["directed-graph-v1", "directed-edge-costs", objective],
             "budget": {"max_expansions": 100, "max_points": 100}}
    bind(snapshot, query)
    return snapshot, query


def bind(snapshot: dict, query: dict) -> None:
    query["data_ref"]["snapshot_hash"] = content_hash(snapshot)
    query["data_ref"]["actor_hash"] = content_hash(snapshot["actor"])
    query["query_hash"] = query_hash(query)


class CanonicalTests(unittest.TestCase):
    def test_binary_numbers_and_utf8_order(self):
        self.assertEqual(canonical_bytes({"b": False, "a": 0.1}),
                         b"o2:s1:an3602879701896397p-55;s1:bb0;")
        self.assertEqual(content_hash({"b": False, "a": 0.1}), "scv-c14n1-adler32:abc7092d:36")
        self.assertEqual(canonical_bytes(-0.0), b"n0p0;")
        self.assertEqual(canonical_bytes(2**100), b"n1p100;")
        self.assertEqual(canonical_bytes(math.ldexp(1.0, -1074)), b"n1p-1074;")
        self.assertEqual(canonical_bytes({"墙": "é", "a": [True, 1.5]}),
                         "o2:s1:aa2:b1;n3p-1;s3:墙s2:é".encode())
        self.assertEqual(content_hash({"墙": "é", "a": [True, 1.5]}), "scv-c14n1-adler32:91030aab:30")

    def test_empty_factorio_tables(self):
        self.assertEqual(content_hash([]), content_hash({}))
        self.assertEqual(content_hash({"a": 1, "b": 2}), content_hash({"b": 2.0, "a": 1.0}))

    def test_reject_lossy_or_nonplain_values(self):
        cycle = []
        cycle.append(cycle)
        for value in [float("inf"), float("nan"), 2**53 + 1, {1: 1}, "\ud800", cycle, object()]:
            with self.subTest(value=repr(value)), self.assertRaises(CanonicalError):
                canonical_bytes(value)


class SearchTests(unittest.TestCase):
    def test_longer_faster_and_reverse_asymmetry(self):
        for algorithm in ("dijkstra", "astar"):
            snapshot, query = example("distance")
            result = solve(snapshot, query, algorithm)
            self.assertEqual(result["metrics"]["path_node_ids"], ["S", "G"])
            self.assertEqual(result["predicted"], {"distance": 10, "travel_ticks": 10})
            snapshot, query = example("travel-time")
            result = solve(snapshot, query, algorithm)
            self.assertEqual(result["metrics"]["path_node_ids"], ["S", "A", "B", "G"])
            self.assertEqual(result["predicted"], {"distance": 20, "travel_ticks": 4})
            snapshot, query = example("travel-time", reverse=True)
            result = solve(snapshot, query, algorithm)
            self.assertEqual(result["metrics"]["path_node_ids"], ["G", "S"])
            self.assertEqual(result["predicted"]["travel_ticks"], 10)

    def test_astar_costs_match_dijkstra_on_deterministic_random_directed_graphs(self):
        rng = random.Random(20260915)
        for sample in range(25):
            snapshot, query = example("travel-time")
            nodes = [{"id": str(i), "position": {"x": rng.uniform(0, 10), "y": rng.uniform(0, 5)}}
                     for i in range(14)]
            edges = []
            for source in nodes:
                for target in nodes:
                    if source != target and rng.random() < 0.23:
                        edges.append({"from": source["id"], "to": target["id"],
                                      "distance": math.dist(source["position"].values(), target["position"].values()),
                                      "travel_ticks": rng.choice([0, 0.1, 1, 2, 17])})
            snapshot["graph"] = {"nodes": nodes, "edges": edges}
            query.update(start_node="0", goal_node="13", start=nodes[0]["position"], goal=nodes[-1]["position"])
            bind(snapshot, query)
            a, d = solve(snapshot, query, "astar"), solve(snapshot, query, "dijkstra")
            with self.subTest(sample=sample):
                self.assertEqual(a["outcome"], d["outcome"])
                if a["outcome"] == "complete":
                    self.assertAlmostEqual(a["predicted"]["travel_ticks"], d["predicted"]["travel_ticks"])

    def test_budget_and_exhaustive_no_path_are_different(self):
        snapshot, query = example()
        query["budget"]["max_expansions"] = 0
        bind(snapshot, query)
        limited = solve(snapshot, query)
        self.assertEqual(limited["outcome"], "budget-exhausted")
        self.assertEqual(limited["metrics"]["expanded_nodes"], 0)
        snapshot["graph"]["edges"] = []
        query["budget"]["max_expansions"] = 100
        bind(snapshot, query)
        exhausted = solve(snapshot, query)
        self.assertEqual(exhausted["outcome"], "no-path")
        self.assertEqual(exhausted["coverage"]["scope"], "bounded-graph")

    def test_output_budget_never_returns_truncated_success(self):
        snapshot, query = example("travel-time")
        query["budget"]["max_points"] = 3
        bind(snapshot, query)
        result = solve(snapshot, query)
        self.assertEqual(result["outcome"], "budget-exhausted")
        self.assertEqual(result["metrics"]["reason"], "max-points")
        self.assertEqual(result["points"], [])

    def test_trivial_goal_needs_no_expansions(self):
        snapshot, query = example()
        query.update(goal=query["start"], goal_node=query["start_node"])
        query["budget"]["max_expansions"] = 0
        bind(snapshot, query)
        result = solve(snapshot, query)
        self.assertEqual(result["outcome"], "complete")
        self.assertEqual(result["predicted"]["distance"], 0)

    def test_unsupported_cost_never_falls_back_to_distance(self):
        snapshot, query = example("travel-time")
        del snapshot["graph"]["edges"][0]["travel_ticks"]
        bind(snapshot, query)
        result = solve(snapshot, query)
        self.assertEqual(result["outcome"], "unsupported")
        self.assertEqual(result["points"], [])
        query["required_capabilities"].append("automatic-gate-actions")
        bind(snapshot, query)
        self.assertEqual(solve(snapshot, query)["outcome"], "unsupported")

    def test_zero_cost_cycle_terminates_and_preserves_optimum(self):
        snapshot, query = example("travel-time")
        for edge in snapshot["graph"]["edges"]:
            if {edge["from"], edge["to"]} == {"S", "A"}:
                edge["travel_ticks"] = 0
        bind(snapshot, query)
        result = solve(snapshot, query)
        self.assertEqual(result["predicted"]["travel_ticks"], 3)
        self.assertEqual(result["metrics"]["heuristic"], "zero")

    def test_cost_overflow_is_explicit_error_not_unreachable(self):
        snapshot, query = example("travel-time")
        snapshot["graph"]["edges"] = [edge for edge in snapshot["graph"]["edges"]
                                       if (edge["from"], edge["to"]) in [("S", "A"), ("A", "B"), ("B", "G")]]
        for edge in snapshot["graph"]["edges"]:
            edge["travel_ticks"] = 1e308
        bind(snapshot, query)
        result = solve(snapshot, query)
        self.assertEqual(result["outcome"], "error")
        self.assertEqual(result["metrics"]["reason"], "nonfinite-accumulated-cost")


class ValidationTests(unittest.TestCase):
    def test_query_full_content_and_snapshot_identity(self):
        snapshot, query = example()
        changed = copy.deepcopy(query)
        changed["budget"]["max_points"] -= 1
        with self.assertRaisesRegex(ValidationError, "query content hash"):
            solve(snapshot, changed)
        changed = copy.deepcopy(snapshot)
        changed["captured_tick"] += 1
        with self.assertRaisesRegex(ValidationError, "snapshot content hash"):
            solve(changed, query)

    def test_reject_graph_ambiguity_or_bad_geometry(self):
        for kind in ["duplicate-node", "duplicate-edge", "dangling-edge", "negative-cost", "nan", "outside", "bad-distance"]:
            snapshot, query = example()
            if kind == "duplicate-node":
                snapshot["graph"]["nodes"].append(copy.deepcopy(snapshot["graph"]["nodes"][0]))
            elif kind == "duplicate-edge":
                snapshot["graph"]["edges"].append(copy.deepcopy(snapshot["graph"]["edges"][0]))
            elif kind == "dangling-edge":
                snapshot["graph"]["edges"][0]["to"] = "missing"
            elif kind == "negative-cost":
                snapshot["graph"]["edges"][0]["travel_ticks"] = -1
            elif kind == "nan":
                snapshot["graph"]["edges"][0]["distance"] = math.nan
            elif kind == "outside":
                snapshot["graph"]["nodes"][0]["position"]["x"] = -100
            else:
                snapshot["graph"]["edges"][0]["distance"] = 1
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                bind(snapshot, query)
                solve(snapshot, query)

    def test_projection_units_and_negative_budget_rejected(self):
        for field in ["projection", "units", "budget"]:
            snapshot, query = example()
            if field == "projection":
                query["start"]["x"] = 0.125
            elif field == "units":
                query["objective"]["units"] = "seconds"
            else:
                query["budget"]["max_expansions"] = -1
            bind(snapshot, query)
            with self.subTest(field=field), self.assertRaises(ValidationError):
                solve(snapshot, query)

    def test_result_binding_and_route_tampering(self):
        for field in ["session_id", "query_hash", "generation", "point", "cost", "endpoint", "scope"]:
            snapshot, query = example()
            result = solve(snapshot, query)
            if field in ("session_id", "query_hash"):
                result[field] = "different"
            elif field == "generation":
                result["data_ref"]["generation_id"] = "old"
            elif field == "point":
                result["points"][0]["x"] = 0.01
            elif field == "cost":
                result["predicted"]["distance"] = 0
            elif field == "endpoint":
                result["points"][-1]["x"] = 7
            else:
                result["coverage"]["scope"] = "global"
            with self.subTest(field=field), self.assertRaises(ValidationError):
                validate_result(snapshot, query, result)

    def test_lua_import_strings_are_data_and_null_is_rejected(self):
        dangerous = '\"); os.execute("bad"); --\n墙\\001'
        module = lua_module({"text": dangerous, "flag": True, "path": []})
        self.assertNotIn("os.execute", module)
        self.assertNotIn(dangerous, module)
        self.assertIn("\\010", module)
        with self.assertRaises(ValidationError):
            lua_module({"null": None})

    def test_json_duplicate_keys_and_nonfinite_rejected(self):
        with tempfile.TemporaryDirectory(prefix="scv-solver-tests-") as folder:
            path = Path(folder) / "bad.json"
            for content in ['{"x":1,"x":2}', '{"x":NaN}', '{"x":Infinity}']:
                path.write_text(content, encoding="utf-8")
                with self.subTest(content=content), self.assertRaises(ValidationError):
                    read_json(path)

    def test_bundle_cli_produces_correlated_artifacts(self):
        snapshot, query = example("travel-time")
        bundle = {"protocol": PROTOCOL, "kind": "capture-bundle",
                  "cases": [{"id": "longer-faster", "snapshot": snapshot, "query": query}]}
        with tempfile.TemporaryDirectory(prefix="scv-solver-tests-") as folder:
            source, output, lua = [Path(folder) / name for name in ["capture.json", "plans.json", "plans.lua"]]
            source.write_text(json.dumps(bundle), encoding="utf-8")
            process = subprocess.run([sys.executable, str(Path(__file__).with_name("solve.py")),
                                      "--bundle", str(source), "--output", str(output), "--lua-output", str(lua)],
                                     capture_output=True, text=True, timeout=30)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertIn("SCV_SOLVER_COMPLETE", process.stdout)
            actual = read_json(output)
            self.assertEqual(actual["cases"][0]["result"]["predicted"]["travel_ticks"], 4)
            self.assertEqual(lua.read_text(encoding="utf-8"), lua_module(actual))
            self.assertEqual(actual["cases"][0]["query"]["query_hash"], query["query_hash"])

    def test_bundle_duplicate_case_rejected(self):
        snapshot, query = example()
        case = {"id": "same", "snapshot": snapshot, "query": query}
        with self.assertRaisesRegex(ValidationError, "duplicate bundle case"):
            solve_bundle({"protocol": PROTOCOL, "kind": "capture-bundle", "cases": [case, case]}, "astar")

    def test_capture_errors_cannot_disappear_from_denominator(self):
        with self.assertRaisesRegex(ValidationError, "export errors"):
            solve_bundle({"protocol": PROTOCOL, "kind": "capture-bundle", "cases": [],
                          "errors": [{"id": "uncaptured", "error": "capture limit"}]}, "astar")


if __name__ == "__main__":
    unittest.main()
