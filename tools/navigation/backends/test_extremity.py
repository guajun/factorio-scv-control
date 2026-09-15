"""Executable backend contracts without requiring an installed Factorio process."""

import copy
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from canonical import content_hash
from solver import query_hash
from test_solver import example, bind
from extremity import BACKEND, compare_case, geometry, DEFAULT_CONFIG
from compare import compare


def fixture():
    snapshot, query = example()
    snapshot["actor"]["collision_mask"] = {"layers": {"player": True}}
    snapshot["graph"]["representation"] = {"clearance_margin": 0.1, "resolution": 0.5, "cell_inflation": 0.3535533905932738}
    snapshot["geometry"]["tiles"] = [
        {"id": f"tile:{x},{y}", "name": "refined-concrete", "position": {"x": x, "y": y},
         "collision_mask": {"layers": {"ground_tile": True}}}
        for x in range(-1, 11) for y in range(-1, 6)]
    query["required_capabilities"] = ["directed-graph-v1", "distance", "finite-bounds"]
    bind(snapshot, query)
    return {"id": "source-wall", "snapshot": snapshot, "query": query}


def wall(identifier, x1, y1, x2, y2):
    return {"id": identifier, "type": "wall", "name": "stone-wall", "direction": 0,
            "position": {"x": (x1 + x2) / 2, "y": (y1 + y2) / 2},
            "bounding_box": {"left_top": {"x": x1, "y": y1}, "right_bottom": {"x": x2, "y": y2}},
            "collision_mask": {"layers": {"player": True}}}


class BackendTests(unittest.TestCase):
    def test_real_library_changes_topology_without_using_grid_edges(self):
        case = fixture()
        case["snapshot"]["geometry"]["entities"] = [wall("barrier", 4, -1, 5, 2)]
        # Captured graph is deliberately empty: reference fails, source library
        # must discover a path from geometry instead of copying the grid.
        case["snapshot"]["graph"]["edges"] = []
        bind(case["snapshot"], case["query"])
        original = copy.deepcopy(case)
        output, report = compare_case(case)
        self.assertEqual(report["captured_grid"]["outcome"], "no-path")
        self.assertEqual(output["result"]["outcome"], "complete")
        self.assertGreater(output["result"]["predicted"]["distance"], 10)
        self.assertEqual(output["query"]["data_ref"]["backend_id"], BACKEND)
        self.assertEqual(output["snapshot"]["geometry"], original["snapshot"]["geometry"])
        self.assertEqual(case, original)
        self.assertEqual(report["same_graph_dijkstra"]["predicted"], output["result"]["predicted"])
        self.assertEqual(report["source_snapshot_hash"], original["query"]["data_ref"]["snapshot_hash"])
        self.assertNotEqual(output["query"]["data_ref"]["snapshot_hash"], report["source_snapshot_hash"])

    def test_source_grid_resolution_does_not_change_geometry_or_route(self):
        first = fixture()
        first["snapshot"]["geometry"]["entities"] = [wall("barrier", 4, -1, 5, 2)]
        bind(first["snapshot"], first["query"])
        second = copy.deepcopy(first)
        second["snapshot"]["graph"]["representation"].update(resolution=4, cell_inflation=100)
        bind(second["snapshot"], second["query"])
        a, _ = compare_case(first)
        b, _ = compare_case(second)
        self.assertEqual(a["result"]["points"], b["result"]["points"])
        self.assertEqual(a["result"]["predicted"], b["result"]["predicted"])

    def test_boundaries_block_route_around_a_full_barrier(self):
        case = fixture()
        case["snapshot"]["geometry"]["entities"] = [wall("barrier", 4, -1, 5, 6)]
        bind(case["snapshot"], case["query"])
        output, report = compare_case(case)
        self.assertEqual(output["result"]["outcome"], "no-path")
        self.assertEqual(output["result"]["coverage"]["scope"], "bounded-graph")
        self.assertEqual(report["reason"], "disconnected-positive-clearance-component")

    def test_touching_inflated_obstacles_are_not_a_zero_width_passage(self):
        case = fixture()
        # Leave exactly 0.6 tile between walls: actor width 0.4 plus trajectory
        # margins 2*0.1. The positive contact guard closes that touching case.
        case["snapshot"]["geometry"]["entities"] = [wall("a", 4, -1, 5, 2), wall("b", 4, 2.6, 5, 6)]
        bind(case["snapshot"], case["query"])
        output, _ = compare_case(case)
        self.assertEqual(output["result"]["outcome"], "no-path")

    def test_unsupported_gate_and_missing_tile_remain_in_report(self):
        gate = fixture()
        item = wall("gate", 4, -1, 5, 2)
        item.update(type="gate", name="gate")
        gate["snapshot"]["geometry"]["entities"] = [item]
        gate["id"] = "unsupported-gate"
        bind(gate["snapshot"], gate["query"])
        unknown = fixture()
        unknown["id"] = "unknown-tile"
        unknown["snapshot"]["geometry"]["tiles"].pop()
        bind(unknown["snapshot"], unknown["query"])
        outputs, report = compare({"protocol": "scv-navigation/1", "kind": "capture-bundle", "cases": [gate, unknown]})
        self.assertEqual(len(outputs["cases"]), 2)
        self.assertEqual(report["input_cases"], 2)
        self.assertEqual(report["outcomes"], {"unsupported": 2})
        self.assertEqual(report["dropped_cases"], 0)

    def test_expansion_or_vertex_bound_is_not_no_path(self):
        case = fixture()
        case["snapshot"]["geometry"]["entities"] = [wall("barrier", 4, -1, 5, 2)]
        case["query"]["budget"]["max_expansions"] = 3
        bind(case["snapshot"], case["query"])
        result, _ = compare_case(case)
        self.assertEqual(result["result"]["outcome"], "budget-exhausted")
        case["query"]["budget"]["max_expansions"] = 100
        bind(case["snapshot"], case["query"])
        result, _ = compare_case(case, {"max_polygon_vertices": 3})
        self.assertEqual(result["result"]["outcome"], "budget-exhausted")

    def test_travel_time_is_explicitly_unsupported(self):
        case = fixture()
        case["query"]["objective"] = {"id": "travel-time", "units": "ticks"}
        bind(case["snapshot"], case["query"])
        result, _ = compare_case(case)
        self.assertEqual(result["result"]["outcome"], "unsupported")


if __name__ == "__main__":
    unittest.main()
