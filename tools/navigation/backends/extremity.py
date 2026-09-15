"""Bounded source-geometry adapter for extremitypathfinder 2.7.2.

The preserved Factorio facts build rectangular configuration-space obstacles;
GEOS performs their union/difference, and the third-party library builds/searches
the resulting polygon visibility graph. The original captured grid is a control,
never an input to topology construction (its explicit clearance metadata is used).
"""

from __future__ import annotations

import copy
import importlib.metadata
import math
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from canonical import content_hash
from solver import PROTOCOL, base_result, query_hash, sequence, solve, validate_problem, validate_result

from extremitypathfinder import PolygonEnvironment
import networkx as nx
import shapely
from shapely import LineString, Point, box, union_all
from shapely.geometry.polygon import orient

BACKEND = "extremity-source-polygons-v1"
VERSIONS = {"extremitypathfinder": "2.7.2", "shapely": "2.1.2", "numpy": "1.26.4", "networkx": "3.5"}
DEFAULT_CONFIG = {"version": 1, "contact_guard_tiles": 1 / 256,
                  "max_polygon_vertices": 512, "geometry": "captured-instance-axis-aligned-bounds",
                  "actor_clearance": "exported-trajectory-envelope", "objective": "distance"}


class Unsupported(ValueError):
    pass


def verify_dependencies() -> dict:
    actual = {name: importlib.metadata.version(name) for name in VERSIONS}
    if actual != VERSIONS:
        raise Unsupported("dependency-version-mismatch")
    return {**actual, "geos": shapely.geos_version_string, "python": sys.version.split()[0]}


def layers(mask: dict) -> set[str]:
    if not isinstance(mask, dict) or not isinstance(mask.get("layers"), dict):
        raise Unsupported("missing-collision-mask")
    return {name for name, active in mask["layers"].items() if active is True}


def xy(point: dict) -> tuple[float, float]:
    return point["x"], point["y"]


def geometry(snapshot: dict, config: dict) -> tuple[object, dict]:
    actor = snapshot["actor"]
    envelope = actor["collision_box"]
    margin = (snapshot.get("graph") or {}).get("representation", {}).get("clearance_margin")
    if not isinstance(margin, (int, float)) or not math.isfinite(margin) or margin < 0:
        raise Unsupported("missing-explicit-trajectory-clearance")
    guard = config["contact_guard_tiles"]
    low, high = envelope["left_top"], envelope["right_bottom"]
    if low["x"] >= high["x"] or low["y"] >= high["y"]:
        raise Unsupported("invalid-actor-box")
    actor_layers = layers(actor["collision_mask"])
    # Character locations whose complete envelope stays inside known coverage.
    bounds = snapshot["coverage"]["bounds"]
    minimum = (bounds["left_top"]["x"] - low["x"] + margin + guard,
               bounds["left_top"]["y"] - low["y"] + margin + guard)
    maximum = (bounds["right_bottom"]["x"] - high["x"] - margin - guard,
               bounds["right_bottom"]["y"] - high["y"] - margin - guard)
    if minimum[0] >= maximum[0] or minimum[1] >= maximum[1]:
        raise Unsupported("coverage-smaller-than-actor-envelope")
    domain = box(*minimum, *maximum)
    obstacles = []
    def obstacle(bounds: dict):
        start, end = bounds["left_top"], bounds["right_bottom"]
        if start["x"] >= end["x"] or start["y"] >= end["y"]:
            raise Unsupported("degenerate-instance-bounds")
        obstacles.append(box(start["x"] - high["x"] - margin - guard,
                             start["y"] - high["y"] - margin - guard,
                             end["x"] - low["x"] + margin + guard,
                             end["y"] - low["y"] + margin + guard))
    for entity in sequence(snapshot["geometry"]["entities"], "entities", 100_000):
        # Walls are the calibrated fixture domain. Gates/movers/belts/custom
        # shapes are not silently treated as static rectangles.
        if entity.get("type") != "wall" or entity.get("name") != "stone-wall":
            raise Unsupported("unsupported-entity-semantics:" + str(entity.get("type")))
        if entity.get("direction") not in {0, 4, 8, 12}:
            raise Unsupported("non-cardinal-instance")
        if layers(entity["collision_mask"]) & actor_layers:
            obstacle(entity["bounding_box"])
    observed = {}
    for tile in sequence(snapshot["geometry"]["tiles"], "tiles", 100_000):
        x, y = xy(tile["position"])
        if x % 1 or y % 1 or (x, y) in observed:
            raise Unsupported("ambiguous-tile-coverage")
        observed[x, y] = tile
    # Missing tile facts are unknown and blocked even if the coarse coverage
    # rectangle was supplied. This first profile requires fully observed tiles.
    for x in range(math.floor(bounds["left_top"]["x"]), math.ceil(bounds["right_bottom"]["x"])):
        for y in range(math.floor(bounds["left_top"]["y"]), math.ceil(bounds["right_bottom"]["y"])):
            tile = observed.get((x, y))
            if tile is None:
                raise Unsupported("unknown-tile-inside-coverage")
            if layers(tile["collision_mask"]) & actor_layers:
                obstacle({"left_top": {"x": x, "y": y}, "right_bottom": {"x": x + 1, "y": y + 1}})
    merged = union_all(obstacles)
    # simplify(0) removes only redundant collinear vertices; no precision grid,
    # coarser geometry, approximate corridor bridging, or make-valid repair.
    free = domain.difference(merged).simplify(0, preserve_topology=True)
    if not free.is_valid:
        raise Unsupported("invalid-derived-polygon-topology")
    polygons = list(free.geoms) if free.geom_type == "MultiPolygon" else ([free] if free.geom_type == "Polygon" else [])
    return free, {"obstacle_rectangles": len(obstacles), "components": len(polygons),
                  "clearance_margin": margin, "contact_guard_tiles": guard,
                  "free_area_tiles2": float(free.area), "cell_inflation_used": False,
                  "polygons": polygons}


def bind_derived(source: dict, source_query: dict, graph: dict, config: dict) -> tuple[dict, dict]:
    snapshot = copy.deepcopy(source)
    snapshot["snapshot_id"] = source["snapshot_id"] + ":" + BACKEND
    snapshot["source_input"] = {"snapshot_id": source["snapshot_id"],
                               "snapshot_hash": content_hash(source), "query_hash": source_query["query_hash"]}
    snapshot["graph"] = graph
    query = copy.deepcopy(source_query)
    query["snapshot_id"] = snapshot["snapshot_id"]
    query["query_id"] = source_query["query_id"] + ":" + BACKEND
    query["data_ref"].update(backend_id=BACKEND, backend_version="1",
                             generation_id=source_query["data_ref"]["generation_id"] + ":" + BACKEND,
                             snapshot_id=snapshot["snapshot_id"], snapshot_hash=content_hash(snapshot),
                             config_hash=content_hash(config))
    query["start_node"], query["goal_node"] = "start", "goal"
    query["query_hash"] = query_hash(query)
    return snapshot, query


def make_graph(environment: PolygonEnvironment | None, start: dict, goal: dict,
               path: list, config: dict, free: object) -> dict:
    nodes = {"start": copy.deepcopy(start), "goal": copy.deepcopy(goal)}
    edges = {}
    def add(a: str, b: str):
        length = math.dist(xy(nodes[a]), xy(nodes[b]))
        edges[a, b] = {"from": a, "to": b, "distance": length}
    if environment is not None and environment.temp_graph is not None:
        graph = environment.temp_graph
        names = {}
        for identifier in sorted(graph.nodes):
            coordinates = environment._coords_tmp[identifier]
            name = "start" if tuple(coordinates) == xy(start) else "goal" if tuple(coordinates) == xy(goal) else "vertex:" + str(identifier)
            names[identifier] = name
            nodes[name] = {"x": float(coordinates[0]), "y": float(coordinates[1])}
        for a, b in graph.edges:
            add(names[a], names[b])
            if not graph.is_directed():
                add(names[b], names[a])
    elif path:
        # Library short-circuits a visible straight route without temp_graph.
        if len(path) != 2 and xy(start) != xy(goal):
            raise ValueError("library omitted a nontrivial query graph")
        add("start", "goal")
        add("goal", "start")
    # Independent GEOS checks on every library edge expose a bad topology or
    # library edge without repairing it into a different experiment.
    for edge in edges.values():
        a, b = nodes[edge["from"]], nodes[edge["to"]]
        segment = Point(*xy(a)) if a == b else LineString([xy(a), xy(b)])
        if not free.covers(segment):
            raise ValueError("third-party graph edge leaves configuration-space polygon")
    return {"nodes": [{"id": key, "position": value} for key, value in sorted(nodes.items())],
            "edges": [edges[key] for key in sorted(edges)], "representation": {"id": BACKEND, **config}}


def compare_case(case: dict, config: dict | None = None) -> tuple[dict, dict]:
    config = {**DEFAULT_CONFIG, **(config or {})}
    if set(config) != set(DEFAULT_CONFIG) or not math.isfinite(config["contact_guard_tiles"]) or not 0 <= config["contact_guard_tiles"] <= 1:
        raise ValueError("invalid topology configuration")
    if not isinstance(config["max_polygon_vertices"], int) or not 3 <= config["max_polygon_vertices"] <= 8192:
        raise ValueError("invalid polygon vertex budget")
    source, source_query = case["snapshot"], case["query"]
    validate_problem(source, source_query)
    record = {"id": case["id"], "source_snapshot_hash": source_query["data_ref"]["snapshot_hash"],
              "source_query_hash": source_query["query_hash"], "backend": BACKEND, "config": config,
              "versions": verify_dependencies(), "geometry_ms": 0, "build_ms": 0, "search_ms": 0}
    started = time.perf_counter()
    reference = solve(source, source_query, "dijkstra")
    record["captured_grid"] = {"outcome": reference["outcome"], "predicted": reference["predicted"],
                               "metrics": reference["metrics"], "solve_ms": (time.perf_counter() - started) * 1000}
    outcome, reason, path, length, environment, free, graph = "unsupported", None, [], None, None, None, None
    try:
        if source_query["objective"] != {"id": "distance", "units": "tiles"}:
            raise Unsupported("unsupported-objective")
        unknown = set(sequence(source_query["required_capabilities"], "capabilities", 100)) - {"directed-graph-v1", "distance", "finite-bounds"}
        if unknown:
            raise Unsupported("unsupported-query-capability:" + ",".join(sorted(unknown)))
        started = time.perf_counter()
        free, details = geometry(source, config)
        record["geometry_ms"] = (time.perf_counter() - started) * 1000
        polygons = details.pop("polygons")
        record["geometry"] = details
        start, goal = Point(*xy(source_query["start"])), Point(*xy(source_query["goal"]))
        # Touching-only corridors have no positive-width shared component after
        # the union; do not rely on the library's nonblocking shared-edge rule.
        component = next((polygon for polygon in polygons if polygon.contains(start)), None)
        if component is None or not component.contains(goal):
            outcome, reason = "no-path", "disconnected-positive-clearance-component"
        else:
            component = orient(component, sign=1.0)
            boundary = list(component.exterior.coords)[:-1]
            holes = [list(ring.coords)[:-1] for ring in component.interiors]
            vertices = len(boundary) + sum(map(len, holes))
            record["polygon_vertices"] = vertices
            if vertices > config["max_polygon_vertices"]:
                outcome, reason = "budget-exhausted", "polygon-vertex-budget"
            elif vertices + 2 > source_query["budget"]["max_expansions"]:
                # The library has no expansion callback. A geometry-consistent
                # A* never needs more unique expansions than polygon vertices +
                # endpoints; refuse the call when this sufficient bound fails.
                outcome, reason = "budget-exhausted", "conservative-expansion-bound"
            else:
                started = time.perf_counter()
                environment = PolygonEnvironment()
                environment.store(boundary, holes, validate=True)
                record["build_ms"] = (time.perf_counter() - started) * 1000
                started = time.perf_counter()
                path, length = environment.find_shortest_path(xy(source_query["start"]), xy(source_query["goal"]),
                                                              free_space_after=False, verify=True)
                record["search_ms"] = (time.perf_counter() - started) * 1000
                record["prepared_graph"] = {"nodes": len(environment.graph), "edges": environment.graph.number_of_edges()}
                started = time.perf_counter()
                warm_path, warm_length = environment.find_shortest_path(xy(source_query["start"]), xy(source_query["goal"]),
                                                                         free_space_after=False, verify=True)
                record["warm_search_ms"] = (time.perf_counter() - started) * 1000
                if warm_path != path or warm_length != length:
                    raise ValueError("repeated prepared-world query changed its result")
                outcome, reason = ("complete", "library-path") if path else ("no-path", "library-exhausted-polygon-graph")
        graph = make_graph(environment, source_query["start"], source_query["goal"], path, config, free)
    except Unsupported as error:
        reason = str(error)
    except (ValueError, AssertionError, nx.NetworkXException) as error:
        outcome, reason = "error", f"{type(error).__name__}:{error}"
    if graph is None:
        graph = {"nodes": [{"id": "start", "position": source_query["start"]},
                            {"id": "goal", "position": source_query["goal"]}], "edges": [],
                 "representation": {"id": BACKEND, **config}}
    snapshot, query = bind_derived(source, source_query, graph, config)
    result = base_result(validate_problem(snapshot, query), "dijkstra")
    result["solver"] = {"id": "extremitypathfinder", "version": VERSIONS["extremitypathfinder"]}
    result["outcome"] = outcome
    result["metrics"].update(reason=reason, backend=BACKEND,
                              expanded_nodes_reported=False, search_expansion_upper_bound=record.get("polygon_vertices", 0) + 2)
    if outcome == "complete":
        reference_derived = solve(snapshot, query, "dijkstra")
        record["same_graph_dijkstra"] = {"outcome": reference_derived["outcome"],
                                          "predicted": reference_derived["predicted"], "metrics": reference_derived["metrics"]}
        if reference_derived["outcome"] != "complete" or not math.isclose(length, reference_derived["predicted"]["distance"], abs_tol=1e-8):
            result["outcome"] = "error"
            result["metrics"]["reason"] = "library-distance-disagrees-with-same-graph-dijkstra"
        elif len(path) > query["budget"]["max_points"]:
            result["outcome"] = "budget-exhausted"
            result["metrics"]["reason"] = "max-points"
        else:
            result["points"] = [{"x": float(x), "y": float(y)} for x, y in path]
            result["predicted"] = {"distance": float(length)}
            names = {xy(node["position"]): node["id"] for node in graph["nodes"]}
            result["metrics"].update(path_node_ids=[names[tuple(point)] for point in path], objective_value=float(length), graph_optimal=True)
            # Resolve coincident start/goal IDs explicitly for the trivial path.
            result["metrics"]["path_node_ids"][0] = "start"
            result["metrics"]["path_node_ids"][-1] = "goal"
            validate_result(snapshot, query, result)
    record.update(outcome=result["outcome"], reason=result["metrics"]["reason"], predicted=result["predicted"],
                  source_geometry_unchanged=source["geometry"] == snapshot["geometry"],
                  replay_status="not-run")
    return {"id": case["id"], "snapshot": snapshot, "query": query, "result": result}, record
