#!/usr/bin/env python3
"""Offline artifact entry point; never launches Factorio or opens a transport."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from canonical import canonical_bytes
from solver import CAPABILITIES, PROTOCOL, VERSION, ValidationError, mapping, sequence, solve, string, validate_result

MAX_ARTIFACT_BYTES = 32 * 1024 * 1024


def reject_pairs(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def reject_constant(value: str) -> None:
    raise ValidationError(f"nonfinite JSON constant: {value}")


def read_json(path: Path) -> object:
    if path.stat().st_size > MAX_ARTIFACT_BYTES:
        raise ValidationError("artifact exceeds 32 MiB")
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=reject_pairs,
                          parse_constant=reject_constant)
    except (json.JSONDecodeError, RecursionError) as error:
        raise ValidationError(f"invalid JSON: {error}") from error


def lua_string(value: str) -> str:
    # Fixed-width decimal byte escapes cannot end the quoted Lua literal or
    # consume digits from the next character. UTF-8 survives all host locales.
    return '"' + "".join(f"\\{byte:03d}" for byte in value.encode("utf-8")) + '"'


def lua_value(value: object) -> str:
    if value is None:
        # None would remove fields or make holes in Lua sequences. The first
        # import profile forbids null rather than silently losing structure.
        raise ValidationError("null has no data-preserving Lua import encoding")
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return lua_string(value)
    if isinstance(value, (int, float)):
        canonical_bytes(value)
        return repr(value)
    if isinstance(value, list):
        return "{" + ",".join(lua_value(child) for child in value) + "}"
    if isinstance(value, dict):
        return "{" + ",".join("[" + lua_string(key) + "]=" + lua_value(value[key])
                               for key in sorted(value)) + "}"
    raise ValidationError("unsupported Lua import value")


def lua_module(value: object) -> str:
    return "-- Generated offline navigation data. No executable solver payload.\nreturn " + lua_value(value) + "\n"


def solve_bundle(bundle: object, algorithm: str) -> dict:
    bundle = mapping(bundle, "bundle")
    if bundle.get("protocol") != PROTOCOL or bundle.get("kind") != "capture-bundle":
        raise ValidationError("unsupported capture bundle protocol/kind")
    capture_errors = sequence(bundle.get("errors", []), "bundle.errors", 1000)
    if capture_errors:
        # Do not improve the apparent pass rate by silently dropping fixtures
        # whose capture failed before the solver saw them.
        raise ValidationError(f"capture bundle contains {len(capture_errors)} export errors")
    output = {"protocol": PROTOCOL, "kind": "solver-bundle", "cases": []}
    seen = set()
    for case in sequence(bundle.get("cases"), "bundle.cases", 1000):
        case = mapping(case, "bundle case")
        case_id = string(case.get("id"), "case.id")
        if case_id in seen:
            raise ValidationError("duplicate bundle case ID")
        seen.add(case_id)
        result = solve(case.get("snapshot"), case.get("query"), algorithm)
        validate_result(case["snapshot"], case["query"], result)
        output["cases"].append({**case, "result": result})
    return output


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--query", type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--lua-output", type=Path)
    parser.add_argument("--algorithm", choices=("dijkstra", "astar"), default="astar")
    parser.add_argument("--capabilities", action="store_true")
    args = parser.parse_args(argv)
    if args.capabilities:
        print(json.dumps({"protocol": PROTOCOL, "solver": "python-directed-graph", "version": VERSION,
                          "capabilities": sorted(CAPABILITIES), "mode": "offline",
                          "algorithms": ["dijkstra", "astar"], "partial_results": False}))
        return 0
    if not args.output or bool(args.bundle) == bool(args.snapshot or args.query) or not args.bundle and not (args.snapshot and args.query):
        parser.error("supply --output and either --bundle or both --snapshot and --query")
    inputs = [path.resolve() for path in (args.snapshot, args.query, args.bundle) if path]
    outputs = [path.resolve() for path in (args.output, args.lua_output) if path]
    if len(set(outputs)) != len(outputs) or set(inputs) & set(outputs):
        parser.error("output paths must be distinct from input paths and each other")
    try:
        if args.bundle:
            result = solve_bundle(read_json(args.bundle), args.algorithm)
            outcomes = [case["result"]["outcome"] for case in result["cases"]]
        else:
            snapshot, query = read_json(args.snapshot), read_json(args.query)
            result = solve(snapshot, query, args.algorithm)
            validate_result(snapshot, query, result)
            outcomes = [result["outcome"]]
        # Build both outputs before writing either; malformed imports cannot
        # leave a plausible fresh JSON alongside an old Lua module.
        json_output = json.dumps(result, ensure_ascii=False, allow_nan=False, indent=2) + "\n"
        module_output = lua_module(result) if args.lua_output else None
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json_output, encoding="utf-8")
        if args.lua_output:
            args.lua_output.parent.mkdir(parents=True, exist_ok=True)
            args.lua_output.write_text(module_output, encoding="utf-8")
        counts = {outcome: outcomes.count(outcome) for outcome in sorted(set(outcomes))}
        print("SCV_SOLVER_COMPLETE " + json.dumps(counts, sort_keys=True))
        return 0
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        print(f"SCV_SOLVER_ERROR {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
