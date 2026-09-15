#!/usr/bin/env python3
"""Compare algorithms by loading the same native source ZIP for every run."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import secrets
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

from live import executable_path, hidden_flags, json_text
from rcon import RconError
from savebench import (check_zip, copy_mods, manual_profile, mod_fingerprint, read_json,
                       relative_file, save_slug, server, sha256, wait_save)
from save_facts import bind_derived, read_facts
from solve import reject_constant, reject_pairs
from solver import validate_problem, validate_result

PROTOCOL = "scv-compare/1"
CORPUS_PROTOCOL = "scv-static-corpus/1"
ALGORITHMS = ("production-v1", "grid-astar", "grid-dijkstra", "source-polygons")
CASE_IDS = ("open-diagonal", "long-wall-return", "long-wall-enter", "narrow-corridor",
            "tight-clearance-corridor", "u-trap", "slalom", "captured-slalom-return",
            "gate-open", "gate-closed", "unreachable-box")
SCENARIO = "scv-control-testkit/navigation-comparison"


def rpc(client, operation: str, **fields) -> dict:
    raw = client.command("/scv-compare-agent " + json_text({"protocol": PROTOCOL, "operation": operation, **fields}))
    value = json.loads(raw.strip(), object_pairs_hook=reject_pairs, parse_constant=reject_constant)
    if not isinstance(value, dict) or value.get("ok") is not True:
        raise RconError("comparison operation rejected: " + json_text(value))
    return value


def native_server(binary, mods, artifact, timeout, save=None):
    return server(binary, mods, artifact, timeout, save, scenario=SCENARIO,
                  ready=lambda client: rpc(client, "status"))


def published(data: Path, descriptor: dict) -> Path:
    path = relative_file(data / "script-output", descriptor["path"])
    if type(descriptor.get("bytes")) is not int or path.stat().st_size != descriptor["bytes"]:
        raise ValueError("published comparison artifact byte count differs")
    return path


def source_cases(corpus: Path, manifest: dict) -> list[dict]:
    if manifest.get("protocol") != CORPUS_PROTOCOL or manifest.get("schema_version") != 1:
        raise ValueError("unknown static source corpus")
    cases = manifest.get("cases")
    if not isinstance(cases, list) or manifest.get("case_count") != len(cases):
        raise ValueError("static source denominator mismatch")
    ids = [case.get("id") for case in cases]
    if len(ids) != len(set(ids)) or any(identifier not in CASE_IDS for identifier in ids):
        raise ValueError("duplicate/unknown static source case")
    if type(manifest.get("catalog_complete")) is not bool or manifest["catalog_complete"] and set(ids) != set(CASE_IDS):
        raise ValueError("incomplete static source matrix")
    if mod_fingerprint(corpus / "mods") != manifest.get("source_mods_sha256"):
        raise ValueError("archived source mods changed")
    for case in cases:
        archive, facts_path = relative_file(corpus, case["save_file"]), relative_file(corpus, case["facts_file"])
        if sha256(archive) != case.get("save_sha256") or sha256(facts_path) != case.get("facts_sha256"):
            raise ValueError("static source file checksum changed")
        check_zip(archive)
        facts = read_facts(facts_path)
        if facts["facts_hash"] != case.get("facts_hash") or facts["metadata"]["case_id"] != case["id"]:
            raise ValueError("static source facts identity differs")
        expected = facts["metadata"]["scope"]["fixture_definition"]["expected_path"]
        if type(expected) is not bool or case.get("expected_path") is not expected:
            raise ValueError("static source task expectation differs")
    return cases


def build_corpus(root: Path, binary: Path, corpus: Path, artifact: Path, timeout: float, selected: list[str]) -> dict:
    corpus.mkdir(parents=True, exist_ok=False)
    (corpus / "saves").mkdir()
    (corpus / "facts").mkdir()
    copy_mods(root, corpus / "mods")
    with native_server(binary, corpus / "mods", artifact / "catalog", timeout) as (client, _):
        catalog = rpc(client, "catalog")["cases"]
    if [item["id"] for item in catalog] != list(CASE_IDS):
        raise ValueError("shared static catalog changed; review corpus version and denominator")
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, check=True, capture_output=True,
                              text=True, creationflags=hidden_flags()).stdout.strip()
    manifest = {"protocol": CORPUS_PROTOCOL, "schema_version": 1, "fixture_version": 4,
                "catalog_complete": set(selected) == set(CASE_IDS), "case_count": len(selected),
                "created_utc": datetime.now(timezone.utc).isoformat(), "source_revision": revision, "cases": []}
    for index, identifier in enumerate(selected, 1):
        slug = save_slug(identifier)
        print(f"[compare-build] {index}/{len(selected)} {identifier}", flush=True)
        with native_server(binary, corpus / "mods", artifact / ("build-" + slug), timeout) as (client, data):
            rpc(client, "prepare", id=identifier)
            descriptor = rpc(client, "facts")
            fact_path = published(data, descriptor)
            facts = read_facts(fact_path)
            saved = rpc(client, "save", name=slug)
            source = relative_file(data / "saves", saved["filename"])
            wait_save(source, timeout)
            save_file, facts_file = "saves/" + slug + ".zip", "facts/" + slug + ".json"
            shutil.copy2(source, corpus / save_file)
            shutil.copy2(fact_path, corpus / facts_file)
            manifest["cases"].append({"id": identifier, "save_file": save_file, "facts_file": facts_file,
                "save_sha256": sha256(corpus / save_file), "facts_sha256": sha256(corpus / facts_file),
                "facts_hash": facts["facts_hash"],
                "expected_path": facts["metadata"]["scope"]["fixture_definition"]["expected_path"]})
    manifest["source_mods_sha256"] = mod_fingerprint(corpus / "mods")
    source_cases(corpus, manifest)
    (corpus / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    manual_profile(corpus, binary, manifest["cases"][0]["save_file"])
    (corpus / "OPEN-MAPS.txt").write_text(
        "These exact source ZIPs are loaded by every comparison algorithm.\n"
        "Manually run open-save.ps1 [-Save saves/<filename>.zip] with the archived mod set.\n"
        "The native map opens paused. /scv-compare plan then /scv-compare run executes production.\n"
        "Use /scv-compare status for state. Reload the source ZIP to reset; save edits under another name.\n"
        "External algorithms are submitted by the comparison host and use the same native follower.\n",
        encoding="utf-8")
    return manifest


def await_phase(client, wanted: set[str], timeout: float) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = rpc(client, "status")
        if value.get("phase") in wanted:
            return value
        if value.get("phase") == "failed":
            raise ValueError("native comparison runtime failed: " + json_text(value))
        time.sleep(0.02)
    raise ValueError("comparison host wall-time watchdog")


def verify_origin(status: dict, case: dict) -> None:
    if status.get("loaded_from_save") is not True or type(status.get("runtime_build_calls")) is not int \
            or status["runtime_build_calls"] != 0 or status.get("source_facts_hash") != case["facts_hash"] \
            or status.get("case_id") != case["id"]:
        raise ValueError("comparison must load the exact source map without geometry setup")


def verify_capture(work: dict, case: dict) -> tuple[str, str]:
    if work.get("id") != case["id"] or work.get("source_facts_hash") != case["facts_hash"]:
        raise ValueError("capture belongs to another source map")
    validate_problem(work["snapshot"], work["query"])
    return work["query"]["data_ref"]["snapshot_hash"], work["query"]["query_hash"]


def upload(client, payload: dict, algorithm: str) -> dict:
    encoded = json_text(payload)
    if len(encoded.encode("utf-8")) > 1024 * 1024:
        raise ValueError("comparison result upload exceeds protocol limit")
    for offset in range(0, len(encoded), 3000):
        rpc(client, "upload", index=offset // 3000 + 1, text=encoded[offset:offset + 3000], reset=offset == 0)
    return rpc(client, "commit", algorithm=algorithm, **{"pass": "cold"})


def profile_report(path: Path) -> dict:
    samples, aggregates = {}, {}
    for line in path.read_text(encoding="utf-8").splitlines():
        item = json.loads(line, object_pairs_hook=reject_pairs, parse_constant=reject_constant)
        if not isinstance(item, dict):
            raise ValueError("native profiler record must be an object")
        match = re.fullmatch(r"Duration:\s*([0-9]+(?:\.[0-9]+)?)ms", item.get("duration", ""))
        if not match or not isinstance(item.get("hook"), str):
            raise ValueError("invalid native profiler output")
        duration = float(match[1])
        if not math.isfinite(duration):
            raise ValueError("nonfinite native profiler duration")
        if item.get("kind") == "hook":
            samples.setdefault(item["hook"], []).append(duration)
        elif item.get("kind") == "aggregate" and item["hook"] not in aggregates:
            if type(item.get("count")) is not int or item["count"] < 1:
                raise ValueError("invalid profiler sample count")
            aggregates[item["hook"]] = (item["count"], duration)
        else:
            raise ValueError("duplicate/unknown profiler record")
    if not samples or set(samples) != set(aggregates):
        raise ValueError("native profiling incomplete")
    hooks = {}
    for hook, times in samples.items():
        if aggregates[hook][0] != len(times):
            raise ValueError("profiler sample denominator mismatch")
        hooks[hook] = {"count": len(times), "total_ms": aggregates[hook][1], "mean_ms": statistics.mean(times),
                       "max_ms": max(times), "p95_ms": sorted(times)[math.ceil(len(times) * .95) - 1]}
    return {"hooks": hooks, "single_hook_over_60ups_budget": any(v["max_ms"] > 1000 / 60 for v in hooks.values()),
            "scope": "instrumented-native-Lua-hooks-not-full-engine-CPU", "reference_budget_ms": 1000 / 60}


def verify_result(report: dict, case: dict, algorithm: str) -> bool:
    verify_origin(report, case)
    if report.get("protocol") != PROTOCOL or report.get("algorithm") != algorithm \
            or report.get("source_verified") is not True or report.get("expected_path") is not case["expected_path"]:
        raise ValueError("comparison result correlation differs")
    assertions = report.get("assertions")
    if not isinstance(assertions, list) or not assertions or any(not isinstance(a, dict) or type(a.get("passed")) is not bool for a in assertions):
        raise ValueError("native comparison assertions absent or malformed")
    plans = report.get("plans")
    if not isinstance(plans, list) or not plans or any(not isinstance(p, dict) or p.get("algorithm") != algorithm for p in plans):
        raise ValueError("native comparison planning passes absent or mixed")
    if not isinstance(report.get("native"), dict) or not isinstance(report["native"].get("outcome"), str):
        raise ValueError("native comparison outcome absent or malformed")
    expected = "arrived" if case["expected_path"] else "no-path"
    expected_plan = "success" if case["expected_path"] else "no-path"
    success = report.get("passed") is True and all(a["passed"] for a in assertions) \
        and report["native"]["outcome"] == expected and plans[-1].get("outcome") == expected_plan
    if success and "guard" in str(report["native"].get("reason", "")):
        raise ValueError("watchdog cannot be a successful comparison")
    return success


def compare_row(root, binary, python, mods, corpus, case, algorithm, artifact, timeout) -> dict:
    row = {"case_id": case["id"], "algorithm": algorithm, "source_save_sha256": case["save_sha256"],
           "source_facts_hash": case["facts_hash"], "source_save_file": case["save_file"], "passed": False}
    try:
        with native_server(binary, mods, artifact, timeout, relative_file(corpus, case["save_file"])) as (client, data):
            verify_origin(rpc(client, "status"), case)
            descriptor = rpc(client, "facts")
            facts = read_facts(published(data, descriptor))
            if facts["facts_hash"] != case["facts_hash"]:
                raise ValueError("loaded world facts changed before comparison")
            started = time.perf_counter()
            capture = rpc(client, "capture")
            capture_rpc_ms = (time.perf_counter() - started) * 1000
            capture_path = published(data, capture)
            work = read_json(capture_path)
            row["capture_identity"] = list(verify_capture(work, case))
            shutil.copy2(capture_path, artifact / "capture.json")
            timings = {"capture_rpc_ms": capture_rpc_ms, "server_startup_included": False}
            if algorithm == "production-v1":
                timings["planning_passes"] = []
                for label in ("cold", "repeat"):
                    started = time.perf_counter()
                    rpc(client, "plan", algorithm=algorithm, **{"pass": label})
                    await_phase(client, {"planned"}, timeout)
                    timings["planning_passes"].append({"pass": label, "wall_ms": (time.perf_counter() - started) * 1000})
            else:
                output = artifact / "solver.json"
                started = time.perf_counter()
                worker = subprocess.run([str(python), str(root / "tools/navigation/comparison_solver.py"),
                    "--input", str(capture_path), "--output", str(output), "--algorithm", algorithm],
                    capture_output=True, text=True, timeout=timeout, creationflags=hidden_flags())
                timings["solver_process_wall_ms"] = (time.perf_counter() - started) * 1000
                (artifact / "solver-console.log").write_text(worker.stdout + worker.stderr, encoding="utf-8")
                if worker.returncode != 0:
                    raise ValueError("external comparison worker failed: " + (worker.stderr or worker.stdout)[-1000:])
                solved = read_json(output)
                candidate = solved["case"]
                validate_result(candidate["snapshot"], candidate["query"], candidate["result"])
                if candidate["id"] != case["id"]:
                    raise ValueError("external worker changed case ID")
                payload = {**solved["admission"], "source_facts_hash": case["facts_hash"]}
                if payload["source_snapshot_hash"] != row["capture_identity"][0] \
                        or payload["source_query_hash"] != row["capture_identity"][1]:
                    raise ValueError("external worker changed source identity")
                row["solver"] = {key: value for key, value in solved.items() if key not in {"case", "admission"}}
                row["solver_outcome"] = candidate["result"]["outcome"]
                row["derived_binding"] = bind_derived(facts, case["save_sha256"],
                    candidate["query"]["data_ref"]["backend_id"], candidate["query"]["data_ref"]["backend_version"],
                    candidate["snapshot"]["graph"].get("representation", {}))
                started = time.perf_counter()
                upload(client, payload, algorithm)
                await_phase(client, {"planned"}, timeout)
                timings["upload_admission_wall_ms"] = (time.perf_counter() - started) * 1000
            started = time.perf_counter()
            rpc(client, "execute")
            terminal = await_phase(client, {"complete"}, timeout)
            timings["native_execution_wall_ms"] = (time.perf_counter() - started) * 1000
            report_path = relative_file(data / "script-output", terminal["report_path"])
            report = read_json(report_path)
            if [report.get("source_snapshot_hash"), report.get("source_query_hash")] != row["capture_identity"]:
                raise ValueError("native execution report belongs to another captured problem")
            row["passed"] = verify_result(report, case, algorithm)
            if algorithm != "production-v1":
                row["passed"] = row["passed"] and row["solver"]["metrics"].get("comparison_passed") is True
            row["native_report"] = report
            row["host_timing"] = timings
            row["script_performance"] = profile_report(relative_file(data / "script-output", report["performance_path"]))
            row["solver_wait_paused"] = algorithm != "production-v1"
            row["native_execution_realtime"] = True
        if sha256(relative_file(corpus, case["save_file"])) != case["save_sha256"]:
            raise ValueError("comparison modified authoritative source ZIP")
    except (OSError, ValueError, KeyError, RconError, subprocess.SubprocessError) as error:
        row["passed"], row["error"] = False, str(error)
    artifact.mkdir(parents=True, exist_ok=True)
    (artifact / "correlated-result.json").write_text(json.dumps(row, indent=2, allow_nan=False), encoding="utf-8")
    return row


def check_matrix(rows: list[dict], cases: list[dict], algorithms: list[str]) -> None:
    expected = {(case["id"], algorithm) for case in cases for algorithm in algorithms}
    actual = [(row["case_id"], row["algorithm"]) for row in rows]
    if len(actual) != len(set(actual)) or set(actual) != expected:
        raise ValueError("comparison dropped or duplicated a matrix member")
    for case in cases:
        group = [row for row in rows if row["case_id"] == case["id"]]
        if any(row.get("source_save_sha256") != case["save_sha256"] or row.get("source_facts_hash") != case["facts_hash"] for row in group):
            raise ValueError("algorithms compared different source maps")
        identities = {tuple(row["capture_identity"]) for row in group if "capture_identity" in row}
        if len(identities) > 1:
            raise ValueError("algorithms compared different captured problems")
        grids = [row for row in group if row["algorithm"] in {"grid-astar", "grid-dijkstra"} and "solver" in row]
        if len(grids) == 2:
            references = [row["solver"]["metrics"].get("same_graph_dijkstra", {}) for row in grids]
            if references[0].get("outcome") != references[1].get("outcome") or references[0].get("predicted") != references[1].get("predicted"):
                raise ValueError("same captured graph has inconsistent Dijkstra references")


def markdown(report: dict) -> str:
    lines = ["# Saved-map solver comparison", "", f"Source corpus: `{report['source_corpus']}`", "",
             f"Rows: {report['passed']} passed, {report['failed']} failed. Matrix checks: {'PASS' if report.get('matrix_passed', True) else 'FAIL'}.",
             *[f"Matrix error: {error}" for error in report.get("matrix_errors", [])], "",
             "Every algorithm loads the same source ZIP in a fresh headless process. Distance is in tiles; native time is in ticks.", "",
             "| Case | Algorithm | Check | Outcome | Accepted length | Native ticks | Arrival error |",
             "| --- | --- | --- | --- | ---: | ---: | ---: |"]
    for row in report["rows"]:
        native = row.get("native_report", {})
        result = native.get("native", {})
        plan = (native.get("plans") or [{}])[-1]
        def number(value):
            return f"{value:.4f}" if isinstance(value, (int, float)) and not isinstance(value, bool) else "—"
        lines.append(f"| {row['case_id']} | {row['algorithm']} | {'PASS' if row['passed'] else 'FAIL'} | {result.get('outcome', row.get('error', 'failed'))} | "
                     f"{number(plan.get('final_length'))} | {number(result.get('actual_travel_ticks'))} | {number(result.get('arrival_error'))} |")
    lines += ["", "Full timings, source identities, solver work, validation and native outcomes are in comparison.json.",
              "Paused external solver wait is correctness evidence; real wall latency is reported separately. Native execution runs at game speed 1.",
              "Production includes its existing postprocessing; imported graph/polygon routes remain exact. This compares complete configurations, not search alone.",
              "Historical gate-open/gate-closed fixtures are wall-gap controls, not automatic gate semantics.", ""]
    lines += ["## Timing samples", "",
              "One cold pass per saved-map row; values are milliseconds. External process time includes repeated experiments and references.",
              "The common capture/source verification is testbench overhead for production, not a production planner requirement.", "",
              "| Case | Algorithm | Capture RPC | Cold solve E2E | Polygon build | Polygon query / prepared repeat | Upload + admission | Movement hook p95 |",
              "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in report["rows"]:
        host = row.get("host_timing", {})
        solver = row.get("solver", {}).get("timing", {})
        hooks = row.get("script_performance", {}).get("hooks", {})
        warm = (solver.get("warm_prepared_search_ms") or [None])[0]
        cold = solver.get("cold_solve_end_to_end_ms")
        if row["algorithm"] == "production-v1":
            cold = (host.get("planning_passes") or [{}])[0].get("wall_ms")
        lines.append(f"| {row['case_id']} | {row['algorithm']} | {number(host.get('capture_rpc_ms'))} | {number(cold)} | "
                     f"{number(solver.get('prepared_map_build_ms'))} | {number(solver.get('cold_search_ms'))} / {number(warm)} | "
                     f"{number(host.get('upload_admission_wall_ms'))} | {number(hooks.get('on_tick', {}).get('p95_ms'))} |")
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--factorio-exe")
    parser.add_argument("--topology-python", type=Path)
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--case", action="append", choices=CASE_IDS, dest="cases")
    parser.add_argument("--algorithm", action="append", choices=ALGORITHMS, dest="algorithms")
    parser.add_argument("--timeout", type=float, default=90)
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0 or args.build and args.corpus:
        parser.error("positive timeout required; --build and --corpus are alternatives")
    root = args.project_root.resolve(strict=True)
    depot = root.parent / "factorio-scv-testbench"
    artifact = Path(tempfile.mkdtemp(prefix="scv-static-compare-"))
    try:
        binary = executable_path(args.factorio_exe)
        stamp = "v1-" + datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(3)
        if args.corpus:
            corpus = args.corpus.resolve(strict=True)
        elif not args.build and (depot / "latest-static.json").is_file():
            corpus = Path(read_json(depot / "latest-static.json")["corpus"]).resolve(strict=True)
        else:
            corpus = depot / "static-corpora" / stamp
            manifest = build_corpus(root, binary, corpus, artifact, args.timeout, args.cases or list(CASE_IDS))
            if manifest["catalog_complete"]:
                (depot / "latest-static.json").write_text(json_text({"corpus": str(corpus)}), encoding="utf-8")
        manifest = read_json(corpus / "manifest.json")
        cases = source_cases(corpus, manifest)
        if args.cases:
            if set(args.cases) - {case["id"] for case in cases}:
                raise ValueError("requested comparison case missing from source corpus")
            cases = [case for case in cases if case["id"] in args.cases]
        elif not manifest["catalog_complete"]:
            raise ValueError("default comparison requires all 11 source saves")
        algorithms = list(dict.fromkeys(args.algorithms or ALGORITHMS))
        python = args.topology_python or depot / "runtime-static/Scripts/python.exe"
        if any(algorithm != "production-v1" for algorithm in algorithms) and not python.is_file():
            raise ValueError("comparison Python runtime missing; pass --topology-python with pinned backend dependencies")
        mods = artifact / "evaluation-mods"
        copy_mods(root, mods)
        rows = []
        for case in cases:
            for algorithm in algorithms:
                row = compare_row(root, binary, python, mods, corpus, case, algorithm,
                                  artifact / (save_slug(case["id"]) + "--" + algorithm), args.timeout)
                rows.append(row)
                outcome = row.get("native_report", {}).get("native", {}).get("outcome", row.get("error", "failed"))
                print(f"[compare] {'PASS' if row['passed'] else 'FAIL'} {len(rows)}/{len(cases)*len(algorithms)} {case['id']} / {algorithm}: {outcome}", flush=True)
        matrix_errors = []
        try:
            check_matrix(rows, cases, algorithms)
        except ValueError as error:
            matrix_errors.append(str(error))
        report = {"protocol": PROTOCOL, "schema_version": 1, "source_corpus": str(corpus),
                  "source_manifest_sha256": sha256(corpus / "manifest.json"), "algorithms": algorithms,
                  "source_cases": len(cases), "matrix_size": len(rows), "rows": rows,
                  "passed": sum(row["passed"] for row in rows), "failed": sum(not row["passed"] for row in rows),
                  "matrix_errors": matrix_errors, "matrix_passed": not matrix_errors,
                  "runtime_mods_sha256": mod_fingerprint(mods), "artifacts": str(artifact)}
        destination = depot / "comparisons" / stamp
        destination.mkdir(parents=True)
        for directory in (artifact, destination):
            (directory / "comparison.json").write_text(json.dumps(report, indent=2, allow_nan=False), encoding="utf-8")
            (directory / "comparison.md").write_text(markdown(report), encoding="utf-8")
        print(f"SCV_COMPARE_COMPLETE passed={report['passed']} failed={report['failed']} matrix_failed={int(not report['matrix_passed'])}", flush=True)
        print("Comparison report: " + str(destination / "comparison.json"), flush=True)
        print("Source corpus: " + str(corpus), flush=True)
        return int(report["failed"] != 0 or not report["matrix_passed"])
    except (OSError, ValueError, KeyError, RconError, subprocess.SubprocessError) as error:
        (artifact / "failure.json").write_text(json.dumps({"error": str(error)}, indent=2), encoding="utf-8")
        print("SCV_COMPARE_FAILED " + str(error), flush=True)
        return 1
    finally:
        print("Artifacts: " + str(artifact), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
