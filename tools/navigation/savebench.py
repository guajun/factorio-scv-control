#!/usr/bin/env python3
"""Build inspectable Factorio saves, then evaluate the loaded saves as map truth.

All processes started here are headless. open-save.ps1 is generated for explicit
human use only. A fresh replay never calls the scenario's geometry builder.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import secrets
import statistics
import shutil
import socket
import subprocess
import tempfile
import time
import zipfile

from live import executable_path, free_port, hidden_flags, json_text
from rcon import Rcon, RconError
from save_facts import read_facts
from solve import reject_constant, reject_pairs

PROTOCOL = "scv-save-corpus/1"
RPC_PROTOCOL = "scv-savebench/1"
EXPECTED_DOMAINS = {"gate-actions": 10, "dynamic": 5, "belt-controller": 30}


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=reject_pairs,
                       parse_constant=reject_constant)
    if not isinstance(value, dict):
        raise ValueError("expected JSON object: " + str(path))
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def mod_fingerprint(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        digest.update(path.relative_to(root).as_posix().encode("utf-8") + b"\0")
        digest.update(bytes.fromhex(sha256(path)))
    return digest.hexdigest()


def relative_file(root: Path, value: str) -> Path:
    if not isinstance(value, str) or "\\" in value:
        raise ValueError("artifact reference must be a relative POSIX path")
    part = PurePosixPath(value)
    if part.is_absolute() or not part.parts or any(p in {".", ".."} or ":" in p for p in part.parts):
        raise ValueError("artifact reference escapes corpus")
    result = (root / part).resolve()
    if not result.is_relative_to(root.resolve()):
        raise ValueError("artifact reference escapes corpus")
    return result


def save_slug(case_id: str) -> str:
    return re.sub(r"[^a-z0-9-]+", "-", case_id.lower())[:119] + "-" + hashlib.sha256(case_id.encode()).hexdigest()[:8]


def check_zip(path: Path) -> None:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if not any(name.endswith("/level-init.dat") for name in names) or archive.testzip() is not None:
            raise ValueError("invalid Factorio source save: " + str(path))


def expected_terminal(facts: dict) -> str:
    metadata = facts["metadata"]
    fixture = metadata.get("scope", {}).get("fixture_definition", {})
    if metadata["domain"] == "gate-actions":
        if fixture.get("rejection"):
            return "rejected"
        if fixture.get("change"):
            return "replan-required"
    return "arrived"


def validate_corpus(root: Path, manifest: dict) -> list[dict]:
    if manifest.get("protocol") != PROTOCOL or manifest.get("schema_version") != 1:
        raise ValueError("unsupported save corpus")
    cases = manifest.get("cases")
    if not isinstance(cases, list) or not cases or any(not isinstance(case, dict) for case in cases) \
            or manifest.get("case_count") != len(cases):
        raise ValueError("corpus denominator mismatch")
    if type(manifest.get("catalog_complete")) is not bool:
        raise ValueError("corpus completeness must be explicit")
    if manifest["catalog_complete"] and {domain: sum(case.get("domain") == domain for case in cases)
                                        for domain in EXPECTED_DOMAINS} != EXPECTED_DOMAINS:
        raise ValueError("full corpus is missing native cases")
    if mod_fingerprint(root / "mods") != manifest.get("source_mods_sha256"):
        raise ValueError("source corpus mod copies changed")
    seen, checked_cases = set(), []
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str) or not case["id"] or case["id"] in seen:
            raise ValueError("missing/duplicate corpus case")
        seen.add(case["id"])
        if case.get("domain") not in EXPECTED_DOMAINS or case.get("fixture_version") != 1:
            raise ValueError("unsupported corpus case domain/version")
        source, fact_file = relative_file(root, case["save_file"]), relative_file(root, case["facts_file"])
        if sha256(source) != case.get("save_sha256") or sha256(fact_file) != case.get("facts_sha256"):
            raise ValueError("corpus file checksum mismatch: " + case["id"])
        check_zip(source)
        facts = read_facts(fact_file)
        if facts["facts_hash"] != case.get("facts_hash"):
            raise ValueError("corpus facts identity mismatch")
        metadata = facts.get("metadata", {})
        if metadata.get("case_id") != case["id"] or metadata.get("domain") != case["domain"]:
            raise ValueError("corpus facts case identity mismatch")
        terminal = expected_terminal(facts)
        if "expected_terminal" in case and case["expected_terminal"] != terminal:
            raise ValueError("corpus terminal expectation differs from saved task")
        checked_cases.append({**case, "expected_terminal": terminal})
    return checked_cases


def copy_mods(root: Path, destination: Path) -> None:
    destination.mkdir(parents=True)
    for name, source in [("factorio-scv-control", root), ("scv-control-testkit", root / "devmods/scv-control-testkit")]:
        shutil.copytree(source, destination / name, ignore=shutil.ignore_patterns(
            ".git", "__pycache__", "tools", "devmods", "docs", "artifacts"))
    (destination / "mod-list.json").write_text(json_text({"mods": [
        {"name": name, "enabled": name in {"base", "factorio-scv-control", "scv-control-testkit"}}
        for name in ["base", "factorio-scv-control", "scv-control-testkit", "space-age", "quality", "elevated-rails"]
    ]}), encoding="utf-8")


def config_file(path: Path, binary: Path, data: Path) -> None:
    path.write_text("[path]\nread-data=" + (binary.parents[2] / "data").as_posix()
                    + "\nwrite-data=" + data.as_posix()
                    + "\n\n[general]\nlocale=en\n\n[other]\nenable-new-mods=false\n", encoding="utf-8")


def rpc(client: Rcon, operation: str, **fields: object) -> dict:
    response = client.command("/scv-savebench-agent " + json_text(
        {"protocol": RPC_PROTOCOL, "operation": operation, **fields}))
    try:
        reply = json.loads(response.strip(), object_pairs_hook=reject_pairs, parse_constant=reject_constant)
    except ValueError as error:
        raise RconError("savebench RPC invalid JSON: " + response[:180]) from error
    if not isinstance(reply, dict) or reply.get("ok") is not True:
        raise RconError("savebench RPC rejected: " + json_text(reply))
    return reply


@contextmanager
def server(binary: Path, mods: Path, artifact: Path, timeout: float, save: Path | None = None,
           *, scenario: str = "scv-control-testkit/navigation-savebench", ready=None):
    artifact.mkdir(parents=True)
    data = artifact / "write-data"
    (data / "saves").mkdir(parents=True)
    config = artifact / "config.ini"
    config_file(config, binary, data)
    settings = artifact / "server-settings.json"
    settings.write_text(json_text({"name": "SCV saved-map testbench", "description": "Native saved-map replay",
        "visibility": {"public": False, "lan": False}, "auto_pause": False, "autosave_interval": 0,
        "require_user_verification": False}), encoding="utf-8")
    rcon_port, password = free_port(socket.SOCK_STREAM), secrets.token_urlsafe(32)
    arguments = [str(binary), "--config", str(config), "--mod-directory", str(mods)]
    arguments += (["--start-server", str(save)] if save else
                  ["--start-server-load-scenario", scenario, "--map-gen-seed", "424242"])
    arguments += ["--server-settings", str(settings), "--bind", "127.0.0.1:" + str(free_port(socket.SOCK_DGRAM)),
                  "--rcon-bind", "127.0.0.1:" + str(rcon_port), "--rcon-password", password, "--disable-audio"]
    client = None
    with (artifact / "server-console.log").open("w", encoding="utf-8") as console:
        process = subprocess.Popen(arguments, stdout=console, stderr=subprocess.STDOUT, creationflags=hidden_flags())
        try:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RconError("saved-map server exited; see " + str(artifact))
                try:
                    client = Rcon("127.0.0.1", rcon_port, password, timeout=min(timeout, 10))
                    (ready or (lambda connection: rpc(connection, "status")))(client)
                    break
                except (OSError, RconError):
                    if client:
                        client.close()
                        client = None
                    time.sleep(0.1)
            if client is None:
                raise RconError("saved-map startup watchdog; see " + str(artifact))
            yield client, data
        finally:
            if client:
                client.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def export_facts(client: Rcon, data: Path) -> tuple[Path, dict]:
    descriptor = rpc(client, "facts")
    source = relative_file(data / "script-output", descriptor["path"])
    if source.stat().st_size != descriptor["bytes"]:
        raise ValueError("facts publication byte count mismatch")
    facts = read_facts(source)
    if facts["facts_hash"] != descriptor["facts_hash"]:
        raise ValueError("facts publication identity mismatch")
    return source, facts


def wait_save(path: Path, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if path.is_file():
                check_zip(path)
                return
        except (OSError, ValueError, zipfile.BadZipFile):
            pass
        time.sleep(0.1)
    raise ValueError("source save publication watchdog: " + str(path))


def manual_profile(corpus: Path, binary: Path, first_save: str) -> None:
    config_file(corpus / "client-config.ini", binary, corpus)
    quote = lambda value: "'" + str(value).replace("'", "''") + "'"
    (corpus / "open-save.ps1").write_text(
        "# Explicit human action only. Automated tests never execute this file.\n"
        + "param([string]$Save = " + quote(first_save) + ")\n$ErrorActionPreference = 'Stop'\n"
        + "$selectedSave = Join-Path $PSScriptRoot $Save\n"
        + "& " + quote(binary) + " --config (Join-Path $PSScriptRoot 'client-config.ini')"
        + " --mod-directory (Join-Path $PSScriptRoot 'mods') --load-game $selectedSave\n", encoding="utf-8")
    (corpus / "OPEN-MAPS.txt").write_text(
        "These are the actual saved maps used by the headless testbench.\n"
        "Open open-save.ps1 manually, or run it with -Save saves/<name>.zip.\n"
        "It uses this corpus's exact copied mods and leaves normal saves/mods alone.\n"
        "The map opens paused before the first command. Use /scv-savebench run to execute the stored case.\n"
        "Use /scv-savebench status to inspect it and /scv-savebench pause to pause.\n"
        "Reload the original ZIP to reset. It is the source artifact; do not overwrite it when experimenting.\n",
        encoding="utf-8")


def build(root: Path, binary: Path, corpus: Path, artifact: Path, timeout: float,
          selected: list[str] | None) -> dict:
    corpus.mkdir(parents=True, exist_ok=False)
    (corpus / "saves").mkdir()
    (corpus / "facts").mkdir()
    copy_mods(root, corpus / "mods")
    with server(binary, corpus / "mods", artifact / "catalog", timeout) as (client, _):
        catalog = rpc(client, "catalog")["cases"]
    counts = {domain: sum(case["domain"] == domain for case in catalog) for domain in EXPECTED_DOMAINS}
    if counts != EXPECTED_DOMAINS or len({case["id"] for case in catalog}) != sum(EXPECTED_DOMAINS.values()):
        raise ValueError("native save catalog denominator changed; review the versioned matrix")
    if selected:
        unknown = set(selected) - {case["id"] for case in catalog}
        if unknown:
            raise ValueError("unknown saved cases: " + repr(sorted(unknown)))
        catalog = [case for case in catalog if case["id"] in selected]
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True,
        text=True, check=True, creationflags=hidden_flags()).stdout.strip()
    manifest = {"protocol": PROTOCOL, "schema_version": 1, "fixture_version": 1,
        "source_revision": revision, "source_project": str(root), "cases": [], "case_count": len(catalog),
        "catalog_complete": not selected, "factual_source": "factorio-save-zip",
        "created_utc": datetime.now(timezone.utc).isoformat(), "source_mods_sha256": mod_fingerprint(corpus / "mods")}
    for index, entry in enumerate(catalog, 1):
        case_id, slug = entry["id"], save_slug(entry["id"])
        print(f"[save-build] {index}/{len(catalog)} {case_id}", flush=True)
        with server(binary, corpus / "mods", artifact / ("build-" + slug), timeout) as (client, data):
            prepared = rpc(client, "prepare", id=case_id)
            if prepared.get("state") != "prepared" or prepared.get("paused") is not True:
                raise ValueError("source was not frozen before execution")
            facts_path, facts = export_facts(client, data)
            reply = rpc(client, "save", name=slug)
            source = relative_file(data / "saves", reply["filename"])
            wait_save(source, timeout)
            save_name, facts_name = "saves/" + slug + ".zip", "facts/" + slug + ".json"
            shutil.copy2(source, corpus / save_name)
            shutil.copy2(facts_path, corpus / facts_name)
            manifest["cases"].append({"id": case_id, "domain": entry["domain"], "fixture_version": 1,
                "save_file": save_name, "save_sha256": sha256(corpus / save_name), "facts_file": facts_name,
                "facts_sha256": sha256(corpus / facts_name), "facts_hash": facts["facts_hash"],
                "source_revision": revision, "expected_terminal": expected_terminal(facts)})
    manifest["source_mods_sha256"] = mod_fingerprint(corpus / "mods")
    validate_corpus(corpus, manifest)
    (corpus / "manifest.json").write_text(json.dumps(manifest, indent=2, allow_nan=False), encoding="utf-8")
    manual_profile(corpus, binary, manifest["cases"][0]["save_file"])
    return manifest


def validate_replay(report: dict, case: dict) -> dict:
    if report.get("protocol") != RPC_PROTOCOL or report.get("case_id") != case["id"] \
            or report.get("domain") != case["domain"] or report.get("source_facts_hash") != case["facts_hash"]:
        raise ValueError("loaded-map report identity mismatch")
    if report.get("source_verified") is not True or report.get("loaded_from_save") is not True \
            or report.get("runtime_build_calls") != 0:
        raise ValueError("replay did not use unchanged loaded-save geometry")
    result = report.get("result", {})
    assertions = result.get("assertions")
    if not isinstance(assertions, list) or not assertions or any(not isinstance(a, dict) or
            type(a.get("passed")) is not bool for a in assertions):
        raise ValueError("loaded-map assertions missing or malformed")
    if result.get("id") != case["id"] or result.get("passed") is not True or not all(a["passed"] for a in assertions) \
            or result.get("terminal_state") != case["expected_terminal"]:
        raise ValueError("saved-map case failed: " + case["id"] + ": " + json_text(result))
    if not isinstance(result.get("metrics"), dict) or not isinstance(result.get("timeline"), list) \
            or not result["timeline"] or "guard" in str(result.get("reason", "")):
        raise ValueError("loaded-map terminal diagnostics missing or guard masquerades as completion")
    return result


def script_performance(path: Path) -> dict:
    samples, aggregates = {}, {}
    for line in path.read_text(encoding="utf-8").splitlines():
        row = json.loads(line, object_pairs_hook=reject_pairs, parse_constant=reject_constant)
        match = re.fullmatch(r"Duration:\s*([0-9]+(?:\.[0-9]+)?)ms", row.get("duration", ""))
        if not match or row.get("hook") not in {"begin", "on_tick", "path_result", "script_raised_built", "script_raised_destroy"}:
            raise ValueError("unrecognized native script profiler record")
        duration, hook = float(match[1]), row["hook"]
        if row.get("kind") == "hook":
            samples.setdefault(hook, []).append(duration)
        elif row.get("kind") == "aggregate" and hook not in aggregates:
            aggregates[hook] = (row.get("count"), duration)
        else:
            raise ValueError("invalid/duplicate profiler aggregate")
    if not samples or set(samples) != set(aggregates):
        raise ValueError("native script profiling did not finish")
    hooks = {}
    for hook, values in samples.items():
        if aggregates[hook][0] != len(values):
            raise ValueError("native profiler sample denominator mismatch")
        ordered = sorted(values)
        hooks[hook] = {"count": len(values), "total_ms": aggregates[hook][1],
            "mean_ms": statistics.mean(values), "max_ms": max(values),
            "p95_ms": ordered[max(0, (95 * len(values) + 99) // 100 - 1)]}
    frame_ms = 1000 / 60
    return {"hooks": hooks, "reference_frame_budget_ms": frame_ms,
        "single_hook_exceeds_60ups_budget": any(value["max_ms"] > frame_ms for value in hooks.values()),
        "scope": "real-loaded-map-script-hooks-not-full-engine-update-cpu",
        "nested_event_hooks_included_in_on_tick_do_not_sum_twice": True,
        "instrumented": True}


def evaluate(binary: Path, mods: Path, corpus: Path, cases: list[dict], artifact: Path, timeout: float) -> dict:
    results = []
    for index, case in enumerate(cases, 1):
        case_artifact = artifact / ("replay-" + save_slug(case["id"]))
        with server(binary, mods, case_artifact, timeout, relative_file(corpus, case["save_file"])) as (client, data):
            before = rpc(client, "status")
            if before.get("loaded_from_save") is not True or before.get("state") != "prepared" \
                    or before.get("runtime_build_calls") != 0 or before.get("paused") is not True:
                raise ValueError("map did not load as an untouched inspectable source")
            _, facts = export_facts(client, data)
            if facts["facts_hash"] != case["facts_hash"]:
                raise ValueError("loaded map differs from source facts: " + case["id"])
            started = time.perf_counter()
            status = rpc(client, "run")
            run_reply_time = time.perf_counter()
            deadline = time.monotonic() + timeout
            while status.get("state") not in {"complete", "failed"}:
                if time.monotonic() >= deadline:
                    raise ValueError("saved-map execution watchdog: " + case["id"])
                time.sleep(0.02)
                status = rpc(client, "status")
            elapsed = (time.perf_counter() - started) * 1000
            report = read_json(data / "script-output/scv-control/savebench/result.json")
            result = validate_replay(report, case)
            report["source_save_sha256"] = case["save_sha256"]
            report["source_save_file"] = case["save_file"]
            report["performance_script"] = script_performance(data / "script-output/scv-control/savebench/performance.jsonl")
            report["performance_host"] = {"execution_wall_ms": elapsed, "clock_mode": "realtime",
                "source_check_and_run_rpc_ms": (run_reply_time - started) * 1000,
                "terminal_wait_ms": elapsed - (run_reply_time - started) * 1000,
                "game_speed": 1, "includes_rpc_polling": True, "includes_server_startup": False,
                "script_profile_file": str(data / "script-output/scv-control/savebench/performance.jsonl"),
                "not_a_solver_only_or_engine_update_cpu_measurement": True}
            results.append(report)
            (case_artifact / "correlated-result.json").write_text(json.dumps(report, indent=2, allow_nan=False), encoding="utf-8")
            print(f"[save-replay] PASS {index}/{len(cases)} {case['id']}: {result['terminal_state']} ({elapsed:.1f} ms wall)", flush=True)
        if sha256(relative_file(corpus, case["save_file"])) != case["save_sha256"]:
            raise ValueError("replay modified the source save")
    return {"protocol": PROTOCOL, "schema_version": 1, "case_count": len(cases), "passed": len(results), "failed": 0,
            "factual_source": "loaded-factorio-save", "source_corpus": str(corpus), "cases": results}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--factorio-exe")
    parser.add_argument("--corpus", type=Path, help="Existing source corpus; never regenerated during replay")
    parser.add_argument("--output", type=Path, help="New source corpus destination for --build")
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--case", action="append", dest="cases")
    parser.add_argument("--timeout", type=float, default=90)
    args = parser.parse_args(argv)
    if args.timeout <= 0 or args.build and args.corpus or args.output and not args.build:
        parser.error("use --corpus for replay, or --build [--output] for a new corpus; timeout must be positive")
    root = args.project_root.resolve(strict=True)
    artifact = Path(tempfile.mkdtemp(prefix="scv-savebench-"))
    depot = root.parent / "factorio-scv-testbench"
    try:
        binary = executable_path(args.factorio_exe)
        if args.corpus:
            corpus = args.corpus.resolve(strict=True)
        elif not args.build and (depot / "latest.json").is_file():
            corpus = Path(read_json(depot / "latest.json")["corpus"]).resolve(strict=True)
        else:
            corpus = (args.output or depot / "corpora" / ("v1-" + datetime.now().strftime("%Y%m%d-%H%M%S")
                + "-" + secrets.token_hex(3))).resolve()
            manifest = build(root, binary, corpus, artifact, args.timeout, args.cases)
            if manifest["catalog_complete"]:
                depot.mkdir(parents=True, exist_ok=True)
                (depot / "latest.json").write_text(json_text({"corpus": str(corpus)}), encoding="utf-8")
        manifest = read_json(corpus / "manifest.json")
        cases = validate_corpus(corpus, manifest)
        if args.cases:
            wanted = set(args.cases)
            if wanted - {case["id"] for case in cases}:
                raise ValueError("requested case missing from source corpus")
            cases = [case for case in cases if case["id"] in wanted]
        elif not manifest.get("catalog_complete"):
            raise ValueError("default test requires the full native source corpus")
        if args.test or not args.build:
            mods = artifact / "evaluation-mods"
            copy_mods(root, mods)
            report = evaluate(binary, mods, corpus, cases, artifact, args.timeout)
            report["runtime_mods_sha256"] = mod_fingerprint(mods)
            report["performance_summary"] = {"real_loaded_map_cases": len(cases),
                "script_hook_over_60ups_budget_cases": [case["case_id"] for case in report["cases"]
                    if case["performance_script"]["single_hook_exceeds_60ups_budget"]],
                "paused_solver_wait_used": False, "full_engine_cpu_profile": False}
            (artifact / "savebench-results.json").write_text(json.dumps(report, indent=2, allow_nan=False), encoding="utf-8")
            print(f"SCV_SAVEBENCH_COMPLETE passed={report['passed']} failed=0", flush=True)
        print("Source corpus: " + str(corpus), flush=True)
        return 0
    except (OSError, ValueError, KeyError, RconError, subprocess.SubprocessError) as error:
        (artifact / "failure.json").write_text(json.dumps({"passed": False, "reason": str(error)}, indent=2), encoding="utf-8")
        print("SCV_SAVEBENCH_FAILED " + str(error), flush=True)
        return 1
    finally:
        print("Artifacts: " + str(artifact), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
