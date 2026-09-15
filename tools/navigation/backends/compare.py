#!/usr/bin/env python3
"""Compare every captured case with one bounded third-party topology backend."""

import argparse
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from canonical import content_hash
from solve import lua_module, read_json
from solver import PROTOCOL, sequence
from extremity import compare_case, verify_dependencies


def compare(bundle: dict) -> tuple[dict, dict]:
    if bundle.get("protocol") != PROTOCOL or bundle.get("kind") != "capture-bundle":
        raise ValueError("expected capture-bundle")
    solved = {"protocol": PROTOCOL, "kind": "solver-bundle", "cases": []}
    report = {"schema": "scv-topology-comparison/1", "versions": verify_dependencies(), "cases": [],
              "capture_errors": sequence(bundle.get("errors", []), "errors", 1000), "input_cases": 0}
    seen = set()
    for case in sequence(bundle.get("cases"), "cases", 1000):
        if case["id"] in seen:
            raise ValueError("duplicate case ID")
        seen.add(case["id"])
        started = time.perf_counter()
        output, record = compare_case(case)
        record["total_case_ms"] = (time.perf_counter() - started) * 1000
        report["cases"].append(record)
        solved["cases"].append(output)
    report["input_cases"] = len(seen) + len(report["capture_errors"])
    outcomes = [case["outcome"] for case in report["cases"]]
    report["outcomes"] = {name: outcomes.count(name) for name in sorted(set(outcomes))}
    report["dropped_cases"] = 0
    return solved, report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    bundle = read_json(args.bundle)
    solved, report = compare(bundle)
    (args.output_dir / "comparison.json").write_text(json.dumps(report, ensure_ascii=True, allow_nan=False, indent=2), encoding="utf-8")
    (args.output_dir / "solver-bundle.json").write_text(json.dumps(solved, ensure_ascii=True, allow_nan=False, separators=(",", ":")), encoding="utf-8")
    (args.output_dir / "imported_plans.lua").write_text(lua_module(solved), encoding="utf-8")
    print("SCV_TOPOLOGY_COMPLETE " + json.dumps({"input_cases": report["input_cases"], "outcomes": report["outcomes"],
                                               "capture_errors": len(report["capture_errors"])}))
    return 1 if report["outcomes"].get("error") or report["capture_errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
