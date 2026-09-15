"""Dependency-free reference search over one explicit, bounded directed graph.

This solver claims optimality only on the supplied graph under its declared
edge weights. It neither reconstructs Factorio collision nor certifies a route
safe for native movement; imported paths still need shared live validation.
"""

from __future__ import annotations

import copy
import heapq
import math
from dataclasses import dataclass

from canonical import CanonicalError, canonical_bytes, content_hash

PROTOCOL = "scv-navigation/1"
VERSION = "1.0.0"
MAX_NODES = 100_000
MAX_EDGES = 800_000
MAX_POINTS = 100_000
MAX_EXPANSIONS = 1_000_000
CAPABILITIES = frozenset({"directed-graph-v1", "directed-edge-costs", "distance",
                          "travel-time", "finite-bounds"})
OUTCOMES = frozenset({"complete", "partial", "no-path", "budget-exhausted",
                      "cancelled", "stale-world", "unsupported", "invalid-query", "error"})
IDENTITIES = ("query_id", "query_hash", "session_id", "command_id", "attempt_id", "snapshot_id")
REF_FIELDS = ("backend_id", "backend_version", "generation_id", "snapshot_id",
              "snapshot_hash", "config_hash", "actor_hash")


class ValidationError(ValueError):
    pass


def fail(message: str) -> None:
    raise ValidationError(message)


def mapping(value: object, label: str) -> dict:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def sequence(value: object, label: str, maximum: int) -> list:
    # The Factorio JSON encoder emits {} for an empty plain Lua table.
    if value == {}:
        return []
    if not isinstance(value, list) or len(value) > maximum:
        fail(f"{label} must be an array with at most {maximum} entries")
    return value


def string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 1024:
        fail(f"{label} must be a nonempty string of at most 1024 UTF-8 bytes")
    return value


def number(value: object, label: str, minimum: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail(f"{label} must be finite numeric data")
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite or minimum is not None and value < minimum:
        fail(f"{label} must be finite and >= {minimum}")
    return value


def integer(value: object, label: str, maximum: int | None = None) -> int:
    number(value, label, 0)
    if int(value) != value or maximum is not None and value > maximum:
        fail(f"{label} must be an integer in 0..{maximum}")
    return int(value)


def position(value: object, label: str) -> dict:
    value = mapping(value, label)
    number(value.get("x"), f"{label}.x")
    number(value.get("y"), f"{label}.y")
    if set(value) != {"x", "y"}:
        fail(f"{label} must contain exactly x and y")
    return value


def distance(a: dict, b: dict) -> float:
    return math.hypot(a["x"] - b["x"], a["y"] - b["y"])


def close(a: float, b: float) -> bool:
    return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-8)


def validate_plain(value: object) -> None:
    try:
        canonical_bytes(value)
    except CanonicalError as error:
        fail(str(error))


def validate_revisions(value: object, label: str) -> dict:
    value = mapping(value, label)
    integer(value.get("topology"), f"{label}.topology")
    integer(value.get("motion"), f"{label}.motion")
    return value


def query_hash(query: dict) -> str:
    return content_hash({key: value for key, value in query.items() if key != "query_hash"})


def inside(point: dict, coverage: dict) -> bool:
    bounds = coverage["bounds"]
    return (bounds["left_top"]["x"] <= point["x"] <= bounds["right_bottom"]["x"]
            and bounds["left_top"]["y"] <= point["y"] <= bounds["right_bottom"]["y"])


@dataclass
class Problem:
    snapshot: dict
    query: dict
    nodes: dict[str, dict]
    adjacency: dict[str, list[dict]]
    edges: dict[tuple[str, str], dict]


def validate_problem(snapshot: object, query: object) -> Problem:
    validate_plain(snapshot)
    validate_plain(query)
    snapshot = mapping(snapshot, "snapshot")
    query = mapping(query, "query")
    if snapshot.get("protocol") != PROTOCOL or snapshot.get("kind") != "world-snapshot":
        fail("unsupported snapshot protocol/kind")
    if query.get("protocol") != PROTOCOL or query.get("kind") != "navigation-query":
        fail("unsupported query protocol/kind")
    for key in ("snapshot_id", "world_id", "surface_id"):
        string(snapshot.get(key), f"snapshot.{key}")
    integer(snapshot.get("captured_tick"), "snapshot.captured_tick")
    mapping(snapshot.get("actor"), "snapshot.actor")
    validate_revisions(snapshot.get("revisions"), "snapshot.revisions")
    coverage = mapping(snapshot.get("coverage"), "snapshot.coverage")
    bounds = mapping(coverage.get("bounds"), "snapshot.coverage.bounds")
    low = position(bounds.get("left_top"), "bounds.left_top")
    high = position(bounds.get("right_bottom"), "bounds.right_bottom")
    if low["x"] >= high["x"] or low["y"] >= high["y"] or coverage.get("unknown") != "blocked":
        fail("coverage must be ordered bounds with unknown=blocked")
    geometry = mapping(snapshot.get("geometry"), "snapshot.geometry")
    for kind in ("entities", "tiles"):
        seen = set()
        for item in sequence(geometry.get(kind), f"geometry.{kind}", 200_000):
            item = mapping(item, f"geometry.{kind} entry")
            identifier = string(item.get("id"), f"geometry.{kind}.id")
            if identifier in seen:
                fail(f"duplicate geometry {kind} ID")
            seen.add(identifier)
    graph = mapping(snapshot.get("graph"), "snapshot.graph")
    nodes = {}
    for node in sequence(graph.get("nodes"), "graph.nodes", MAX_NODES):
        node = mapping(node, "graph node")
        node_id = string(node.get("id"), "node.id")
        point = position(node.get("position"), "node.position")
        if node_id in nodes:
            fail(f"duplicate graph node ID: {node_id}")
        if not inside(point, coverage):
            fail(f"node outside snapshot coverage: {node_id}")
        nodes[node_id] = point
    adjacency = {node_id: [] for node_id in nodes}
    edges = {}
    for edge in sequence(graph.get("edges"), "graph.edges", MAX_EDGES):
        edge = mapping(edge, "graph edge")
        source = string(edge.get("from"), "edge.from")
        target = string(edge.get("to"), "edge.to")
        if source not in nodes or target not in nodes:
            fail("edge references nonexistent graph node")
        if (source, target) in edges:
            fail("duplicate directed edge")
        edge_distance = number(edge.get("distance"), "edge.distance", 0)
        # Each edge represents the straight movement segment exported for it.
        if not close(edge_distance, distance(nodes[source], nodes[target])):
            fail("edge.distance must match its straight segment geometry")
        if "travel_ticks" in edge:
            number(edge["travel_ticks"], "edge.travel_ticks", 0)
        adjacency[source].append(edge)
        edges[source, target] = edge
    for outgoing in adjacency.values():
        outgoing.sort(key=lambda edge: edge["to"])
    for key in IDENTITIES:
        string(query.get(key), f"query.{key}")
    if query["query_hash"] != query_hash(query):
        fail("query content hash mismatch")
    ref = mapping(query.get("data_ref"), "query.data_ref")
    for key in REF_FIELDS:
        string(ref.get(key), f"query.data_ref.{key}")
    validate_revisions(ref.get("revisions"), "query.data_ref.revisions")
    if query["snapshot_id"] != snapshot["snapshot_id"] or ref["snapshot_id"] != snapshot["snapshot_id"]:
        fail("query snapshot binding mismatch")
    if ref["snapshot_hash"] != content_hash(snapshot):
        fail("query snapshot content hash mismatch")
    if ref["actor_hash"] != content_hash(snapshot["actor"]):
        fail("query actor hash mismatch")
    if ref["revisions"] != snapshot["revisions"]:
        fail("query committed revisions mismatch")
    for key in ("start", "goal"):
        point = position(query.get(key), f"query.{key}")
        node_id = string(query.get(key + "_node"), f"query.{key}_node")
        if node_id not in nodes:
            fail(f"query.{key}_node missing from graph")
        if point != nodes[node_id]:
            fail(f"query.{key} must equal its graph node position; projection is unsupported")
    number(query.get("goal_tolerance"), "query.goal_tolerance", 0)
    objective = mapping(query.get("objective"), "query.objective")
    string(objective.get("id"), "query.objective.id")
    string(objective.get("units"), "query.objective.units")
    known_units = {"distance": "tiles", "travel-time": "ticks"}
    if objective["id"] in known_units and objective["units"] != known_units[objective["id"]]:
        fail("objective units mismatch")
    requirements = sequence(query.get("required_capabilities"), "query.required_capabilities", 100)
    for requirement in requirements:
        string(requirement, "required capability")
    if len(set(requirements)) != len(requirements):
        fail("duplicate required capability")
    budget = mapping(query.get("budget"), "query.budget")
    integer(budget.get("max_expansions"), "query.budget.max_expansions", MAX_EXPANSIONS)
    integer(budget.get("max_points"), "query.budget.max_points", MAX_POINTS)
    return Problem(snapshot, query, nodes, adjacency, edges)


def base_result(problem: Problem, algorithm: str) -> dict:
    query = problem.query
    coverage = copy.deepcopy(problem.snapshot["coverage"])
    coverage["scope"] = "bounded-graph"
    return {
        "protocol": PROTOCOL, "kind": "solver-result",
        **{key: query[key] for key in IDENTITIES},
        "data_ref": copy.deepcopy(query["data_ref"]),
        "solver": {"id": f"python-graph-{algorithm}", "version": VERSION},
        "objective": copy.deepcopy(query["objective"]),
        "coverage": coverage,
        "outcome": "error", "points": [], "predicted": {},
        "metrics": {"algorithm": algorithm, "expanded_nodes": 0, "relaxed_edges": 0,
                    "graph_nodes": len(problem.nodes), "graph_edges": len(problem.edges),
                    "scope": "supplied-directed-graph", "path_node_ids": [],
                    "heuristic": "zero", "heuristic_scale": 0},
    }


def solve(snapshot: object, query: object, algorithm: str = "astar") -> dict:
    if algorithm not in {"dijkstra", "astar"}:
        fail("algorithm must be dijkstra or astar")
    problem = validate_problem(snapshot, query)
    result = base_result(problem, algorithm)
    objective = problem.query["objective"]["id"]
    required = set(sequence(problem.query["required_capabilities"], "required", 100))
    unsupported = required - CAPABILITIES
    if objective not in {"distance", "travel-time"} or unsupported:
        result.update(outcome="unsupported")
        result["metrics"]["reason"] = "unsupported-objective-or-capability"
        result["metrics"]["unsupported_capabilities"] = sorted(unsupported)
        return result
    weight = "distance" if objective == "distance" else "travel_ticks"
    if any(weight not in edge for edge in problem.edges.values()):
        result["outcome"] = "unsupported"
        result["metrics"]["reason"] = "missing-directed-travel-time-weights"
        return result
    # c(u,v) >= scale * Euclidean(u,v) for every edge, so by the triangle
    # inequality scale*Euclidean(u,goal) is a consistent lower bound. This
    # remains valid for directed costs, zero-cost edges, and belt-like speedup.
    ratios = [edge[weight] / distance(problem.nodes[edge["from"]], problem.nodes[edge["to"]])
              for edge in problem.edges.values()
              if distance(problem.nodes[edge["from"]], problem.nodes[edge["to"]]) > 0]
    scale = min(ratios, default=0) if algorithm == "astar" else 0
    if not math.isfinite(scale):
        scale = 0
    # Downward rounding avoids overstating a computed floating lower bound.
    scale = max(0.0, math.nextafter(scale, -math.inf)) if scale else 0.0
    result["metrics"].update(heuristic="graph-min-cost-per-tile" if scale else "zero",
                             heuristic_scale=scale)
    start, goal = problem.query["start_node"], problem.query["goal_node"]
    heuristic = lambda node: scale * distance(problem.nodes[node], problem.nodes[goal])
    frontier = [(heuristic(start), 0.0, start)]
    costs = {start: 0.0}
    previous: dict[str, str] = {}
    budget = problem.query["budget"]
    while frontier:
        _, cost, node = heapq.heappop(frontier)
        if cost != costs[node]:
            continue
        if node == goal:
            path = [goal]
            while path[-1] != start:
                path.append(previous[path[-1]])
            path.reverse()
            if len(path) > budget["max_points"]:
                result["outcome"] = "budget-exhausted"
                result["metrics"]["reason"] = "max-points"
                return result
            path_edges = [problem.edges[a, b] for a, b in zip(path, path[1:])]
            predicted = {"distance": sum(edge["distance"] for edge in path_edges)}
            if all("travel_ticks" in edge for edge in path_edges):
                predicted["travel_ticks"] = sum(edge["travel_ticks"] for edge in path_edges)
            result.update(outcome="complete", points=[copy.deepcopy(problem.nodes[key]) for key in path],
                          predicted=predicted)
            result["metrics"].update(path_node_ids=path, objective_value=cost,
                                     graph_optimal=True)
            validate_result(snapshot, query, result)
            return result
        if result["metrics"]["expanded_nodes"] >= budget["max_expansions"]:
            result["outcome"] = "budget-exhausted"
            result["metrics"]["reason"] = "max-expansions"
            return result
        result["metrics"]["expanded_nodes"] += 1
        for edge in problem.adjacency[node]:
            result["metrics"]["relaxed_edges"] += 1
            target = edge["to"]
            new_cost = cost + edge[weight]
            if not math.isfinite(new_cost):
                result["outcome"] = "error"
                result["metrics"]["reason"] = "nonfinite-accumulated-cost"
                return result
            if new_cost < costs.get(target, math.inf):
                costs[target] = new_cost
                previous[target] = node
                heapq.heappush(frontier, (new_cost + heuristic(target), new_cost, target))
    result["outcome"] = "no-path"
    result["metrics"]["reason"] = "supplied-graph-exhausted"
    return result


def validate_result(snapshot: object, query: object, result: object) -> None:
    problem = validate_problem(snapshot, query)
    validate_plain(result)
    result = mapping(result, "result")
    if result.get("protocol") != PROTOCOL or result.get("kind") != "solver-result":
        fail("unsupported result protocol/kind")
    for key in IDENTITIES:
        if result.get(key) != problem.query[key]:
            fail(f"result {key} binding mismatch")
    if result.get("data_ref") != problem.query["data_ref"]:
        fail("result data_ref binding mismatch")
    if result.get("objective") != problem.query["objective"]:
        fail("result objective mismatch")
    expected_coverage = copy.deepcopy(problem.snapshot["coverage"])
    expected_coverage["scope"] = "bounded-graph"
    if result.get("coverage") != expected_coverage:
        fail("result coverage mismatch")
    solver = mapping(result.get("solver"), "result.solver")
    string(solver.get("id"), "solver.id")
    string(solver.get("version"), "solver.version")
    if result.get("outcome") not in OUTCOMES:
        fail("unsupported result outcome")
    points = sequence(result.get("points"), "result.points", problem.query["budget"]["max_points"])
    for point in points:
        position(point, "result point")
        if not inside(point, problem.snapshot["coverage"]):
            fail("result point outside coverage")
    predicted = mapping(result.get("predicted"), "result.predicted")
    for key in ("distance", "travel_ticks"):
        if key in predicted:
            number(predicted[key], f"predicted.{key}", 0)
    metrics = mapping(result.get("metrics"), "result.metrics")
    if result["outcome"] != "complete":
        # This reference implementation emits no partial payloads. A future
        # adapter needs its own explicit partial-route validation contract.
        if points:
            fail("reference noncomplete result must have an empty route")
        return
    if not points or points[0] != problem.query["start"]:
        fail("complete result has missing/wrong start endpoint")
    if distance(points[-1], problem.query["goal"]) > problem.query["goal_tolerance"]:
        fail("complete result does not reach the query goal")
    path = sequence(metrics.get("path_node_ids"), "metrics.path_node_ids", MAX_POINTS)
    if len(path) != len(points) or path[0] != problem.query["start_node"] or path[-1] != problem.query["goal_node"]:
        fail("result graph path does not match endpoints/point count")
    for node_id, point in zip(path, points):
        if not isinstance(node_id, str) or problem.nodes.get(node_id) != point:
            fail("result graph path point mismatch")
    path_edges = []
    for pair in zip(path, path[1:]):
        if pair not in problem.edges:
            fail("result crosses nonexistent directed edge")
        path_edges.append(problem.edges[pair])
    if "distance" not in predicted or not close(predicted["distance"], sum(edge["distance"] for edge in path_edges)):
        fail("result distance does not match directed graph route")
    ticks = all("travel_ticks" in edge for edge in path_edges)
    if "travel_ticks" in predicted and (not ticks or not close(predicted["travel_ticks"], sum(edge["travel_ticks"] for edge in path_edges))):
        fail("result travel time does not match directed graph route")
    weight = "distance" if problem.query["objective"]["id"] == "distance" else "travel_ticks"
    if weight not in predicted:
        fail("result omitted its objective prediction")
    if not close(number(metrics.get("objective_value"), "metrics.objective_value", 0), predicted[weight]):
        fail("result objective value mismatch")
