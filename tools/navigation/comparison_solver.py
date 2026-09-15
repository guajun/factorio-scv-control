#!/usr/bin/env python3
"""One captured saved-map query, one solver, explicit timing and admission data.

This process never authors a map or simulates native movement. The caller binds
the capture to its source ZIP/facts and reloads that ZIP for final admission and
execution. Timing the dependency-free solver includes its own validation and
graph indexing; repeating it is deliberately not labelled a warm-cache query.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import statistics
import sys
import time

from canonical import content_hash
from solve import read_json
from solver import (VERSION as SOLVER_VERSION, ValidationError, base_result,
                    mapping, solve, string, validate_problem,
                    validate_result)

PROTOCOL = "scv-navigation-comparison-worker/1"
VERSION = "1"
ALGORITHMS = ("grid-astar", "grid-dijkstra", "source-polygons")
BACKEND = "extremity-source-polygons-v1"
SNAPSHOT_CHANGES = frozenset({"snapshot_id", "source_input", "graph"})
QUERY_CHANGES = frozenset({"snapshot_id", "query_id", "data_ref", "start_node",
                           "goal_node", "query_hash"})
REF_CHANGES = frozenset({"backend_id", "backend_version", "generation_id",
                         "snapshot_id", "snapshot_hash", "config_hash"})


def measure(call):
    started = time.perf_counter()
    value = call()
    return value, (time.perf_counter() - started) * 1000


def unchanged_except(before: dict, after: dict, allowed: frozenset[str], label: str) -> None:
    if {key: value for key, value in before.items() if key not in allowed} != {
            key: value for key, value in after.items() if key not in allowed}:
        raise ValidationError(f"{label} changed outside the derived-data boundary")


def admission_delta(source_case: dict, solved_case: dict) -> dict:
    """Lossless transport patch with no authority to replace observed geometry."""
    source, original_query = source_case["snapshot"], source_case["query"]
    snapshot, query, result = (solved_case[key] for key in ("snapshot", "query", "result"))
    if source_case["id"] != solved_case["id"]:
        raise ValidationError("solver changed the captured case identity")
    validate_problem(source, original_query)
    validate_result(snapshot, query, result)
    delta = {"source_snapshot_hash": original_query["data_ref"]["snapshot_hash"],
             "source_query_hash": original_query["query_hash"], "result": copy.deepcopy(result)}
    if snapshot == source:
        if query != original_query:
            raise ValidationError("query changed without a derived snapshot")
        return delta
    unchanged_except(source, snapshot, SNAPSHOT_CHANGES, "snapshot")
    unchanged_except(original_query, query, QUERY_CHANGES, "query")
    unchanged_except(original_query["data_ref"], query["data_ref"], REF_CHANGES, "data_ref")
    expected_source = {"snapshot_id": source["snapshot_id"],
                       "snapshot_hash": content_hash(source), "query_hash": original_query["query_hash"]}
    if snapshot.get("source_input") != expected_source:
        raise ValidationError("derived snapshot source_input binding mismatch")
    if (snapshot["snapshot_id"] != source["snapshot_id"] + ":" + BACKEND
            or query["query_id"] != original_query["query_id"] + ":" + BACKEND
            or query["data_ref"]["backend_id"] != BACKEND
            or query["data_ref"]["backend_version"] != "1"
            or query["data_ref"]["generation_id"] != original_query["data_ref"]["generation_id"] + ":" + BACKEND
            or query["start_node"] != "start" or query["goal_node"] != "goal"):
        raise ValidationError("unexpected derived backend identity")
    delta["derived"] = {key: copy.deepcopy(snapshot[key]) for key in SNAPSHOT_CHANGES}
    delta["derived"]["query"] = copy.deepcopy(query)
    reconstructed = copy.deepcopy(source)
    reconstructed.update({key: delta["derived"][key] for key in SNAPSHOT_CHANGES})
    if reconstructed != snapshot or content_hash(reconstructed) != query["data_ref"]["snapshot_hash"]:
        raise ValidationError("admission delta does not reconstruct the exact derived snapshot")
    return delta


def reference_record(result: dict, reference: dict, elapsed: float | None = None) -> dict:
    complete = result["outcome"] == reference["outcome"] == "complete"
    exhausted = result["outcome"] == reference["outcome"] == "no-path"
    record = {"algorithm": "dijkstra", "scope": "same-supplied-directed-graph",
              "outcome": reference["outcome"], "predicted": reference["predicted"],
              "metrics": reference["metrics"], "cost_comparison_available": complete,
              "bounded_no_path_agreement": exhausted,
              "native_passability_proof": False}
    if elapsed is not None:
        record["solve_end_to_end_ms"] = elapsed
    if complete:
        actual = result["metrics"]["objective_value"]
        optimal = reference["metrics"]["objective_value"]
        record.update(objective_difference=actual - optimal,
                      objective_matches=math.isclose(actual, optimal, rel_tol=1e-9, abs_tol=1e-8))
    return record


def dependency_failure(case: dict, reason: str) -> dict:
    result = base_result(validate_problem(case["snapshot"], case["query"]), "dijkstra")
    result["solver"] = {"id": "source-polygons-worker", "version": VERSION}
    result["outcome"] = "unsupported"
    result["metrics"]["reason"] = reason
    return {**copy.deepcopy(case), "result": result}


def polygon_backend():
    # Optional dependencies must not become a production or grid-worker import.
    from backends.extremity import compare_case
    return compare_case


def signature(case: dict) -> str:
    # Only timing is nondeterministic; the complete result and derived identities
    # must be repeatable. No successful-only filtering hides a changed outcome.
    return content_hash({key: case[key] for key in ("id", "snapshot", "query", "result")})


def compare(captured_case: object, algorithm: str, repeats: int = 3) -> dict:
    if algorithm not in ALGORITHMS:
        raise ValidationError("unknown comparison algorithm")
    if isinstance(repeats, bool) or not isinstance(repeats, int) or not 0 <= repeats <= 20:
        raise ValidationError("repeats must be an integer in 0..20")
    case = mapping(captured_case, "captured case")
    string(case.get("id"), "case.id")
    source, source_query = case.get("snapshot"), case.get("query")
    _, validation_ms = measure(lambda: validate_problem(source, source_query))
    original_signature = content_hash(case)
    captured = {key: copy.deepcopy(case[key]) for key in ("id", "snapshot", "query")}
    timings = {"units": "milliseconds", "clock": "host-perf-counter",
               "source_validation_ms": validation_ms,
               "repeated_end_to_end_count": repeats,
               "repeated_end_to_end_ms": [], "repeated_end_to_end_reuses_prepared_map": False,
               "cold_process_scope": "backend work only; interpreter/import/read/write excluded"}
    metrics = {"native_execution": "not-run", "native_performance_evidence": False,
               "source_geometry_unchanged": True, "comparison_issues": []}
    versions = {"worker": VERSION, "python": sys.version.split()[0], "graph_solver": SOLVER_VERSION}
    if algorithm in {"grid-astar", "grid-dijkstra"}:
        name = "astar" if algorithm == "grid-astar" else "dijkstra"
        run = lambda: {**captured, "result": solve(source, source_query, name)}
        solved, timings["cold_solve_end_to_end_ms"] = measure(run)
        timings["solve_scope"] = "query validation, graph indexing, search, result construction and validation"
        timings["graph_build"] = "captured in Factorio; no external geometry build"
        timings["warm_prepared_search_available"] = False
        if name == "dijkstra":
            reference, reference_ms = solved["result"], timings["cold_solve_end_to_end_ms"]
        else:
            reference, reference_ms = measure(lambda: solve(source, source_query, "dijkstra"))
        metrics["same_graph_dijkstra"] = reference_record(solved["result"], reference, reference_ms)
    else:
        backend, load_error = None, None
        try:
            backend = polygon_backend()
        except ImportError as error:
            load_error = f"optional-backend-dependency-unavailable:{error}"
        if load_error:
            solved = dependency_failure(captured, load_error)
            timings["cold_solve_end_to_end_ms"] = 0.0
            timings["warm_prepared_search_available"] = False
            run = lambda: dependency_failure(captured, load_error)
        else:
            (solved, record), timings["cold_solve_end_to_end_ms"] = measure(lambda: backend(captured))
            run = lambda: backend(captured)[0]
            metrics["backend_record"] = record
            versions.update(record["versions"])
            timings.update(geometry_compile_ms=record["geometry_ms"],
                           prepared_map_build_ms=record["build_ms"],
                           cold_search_ms=record["search_ms"],
                           warm_prepared_search_available="warm_search_ms" in record,
                           solve_scope="full backend compare_case, including captured-grid and derived-graph references",
                           search_scope="library query on one prepared polygon environment")
            if "warm_search_ms" in record:
                timings["warm_prepared_search_ms"] = [record["warm_search_ms"]]
            if "same_graph_dijkstra" in record:
                metrics["same_graph_dijkstra"] = reference_record(solved["result"], record["same_graph_dijkstra"])
            elif solved["result"]["outcome"] == "no-path":
                reference, elapsed = measure(lambda: solve(solved["snapshot"], solved["query"], "dijkstra"))
                metrics["same_graph_dijkstra"] = reference_record(solved["result"], reference, elapsed)
                metrics["same_graph_dijkstra"]["scope_note"] = (
                    "Derived graph can contain only disconnected endpoints when geometry proves disconnection; "
                    "this agreement is not an independent polygon-topology proof.")
    expected = signature(solved)
    for index in range(repeats):
        repeated, elapsed = measure(run)
        timings["repeated_end_to_end_ms"].append(elapsed)
        if signature(repeated) != expected:
            metrics["comparison_issues"].append(f"repeated-result-changed:{index + 1}")
    if repeats:
        timings["repeated_end_to_end_median_ms"] = statistics.median(timings["repeated_end_to_end_ms"])
    metrics["repeat_results_identical"] = not metrics["comparison_issues"]
    reference = metrics.get("same_graph_dijkstra", {})
    if reference.get("cost_comparison_available") and not reference["objective_matches"]:
        metrics["comparison_issues"].append("same-graph-objective-disagreement")
    if content_hash(case) != original_signature:
        raise ValidationError("backend mutated the captured input")
    admission, timings["output_contract_validation_ms"] = measure(lambda: admission_delta(captured, solved))
    metrics["comparison_passed"] = not metrics["comparison_issues"]
    files = [Path(__file__), Path(__file__).with_name("solver.py")]
    if algorithm == "source-polygons":
        files.append(Path(__file__).parent / "backends" / "extremity.py")
    return {"protocol": PROTOCOL, "schema_version": 1, "id": case["id"], "algorithm": algorithm,
            "versions": versions,
            "implementation_sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in files},
            "source": {"snapshot_id": source["snapshot_id"],
                       "snapshot_hash": source_query["data_ref"]["snapshot_hash"],
                       "query_hash": source_query["query_hash"],
                       "geometry_hash": content_hash(source["geometry"]),
                       "graph_hash": content_hash(source["graph"])},
            "case": solved, "admission": admission, "timing": timings, "metrics": metrics}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--algorithm", required=True, choices=ALGORITHMS)
    parser.add_argument("--repeats", type=int, default=3, help="additional end-to-end runs; 0..20")
    args = parser.parse_args(argv)
    if args.input.resolve() == args.output.resolve():
        parser.error("output must not overwrite the captured input")
    try:
        report = compare(read_json(args.input), args.algorithm, args.repeats)
        rendered = json.dumps(report, ensure_ascii=False, allow_nan=False, indent=2) + "\n"
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
        print("SCV_COMPARISON_SOLVER_COMPLETE " + json.dumps({"id": report["id"], "algorithm": args.algorithm,
              "outcome": report["case"]["result"]["outcome"], "comparison_passed": report["metrics"]["comparison_passed"]}))
        return 0
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        print(f"SCV_COMPARISON_SOLVER_ERROR {type(error).__name__}:{error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
