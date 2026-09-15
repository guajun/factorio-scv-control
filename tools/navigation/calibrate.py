#!/usr/bin/env python3
"""Run real-domain calibration twice in isolated headless Factorio instances.

These are physical measurement probes, not claims about planner capabilities.
The scenario reports semantic completion; elapsed-time limits only fail a run.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time

from live import executable_path, free_port, hidden_flags, json_text
from solve import reject_constant, reject_pairs


def validate_report(report: dict, domain: str, passed: int, failed: int) -> None:
    if not isinstance(report, dict) or report.get("schema_version") != 1 or report.get("domain") != domain:
        raise ValueError("invalid calibration report identity")
    if report.get("fixture_version") != 1 or not isinstance(report.get("factorio_version"), str):
        raise ValueError("missing calibration fixture/engine version")
    cases = report.get("cases")
    if not isinstance(cases, list) or not cases or report.get("case_count") != len(cases):
        raise ValueError("missing calibration cases or denominator mismatch")
    if report.get("passed") != passed or report.get("failed") != failed or passed + failed != len(cases):
        raise ValueError("calibration marker/report counts disagree")
    seen = set()
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str) or case["id"] in seen:
            raise ValueError("invalid/duplicate calibration case")
        seen.add(case["id"])
        assertions = case.get("assertions")
        if not isinstance(assertions, list) or not assertions or any(not isinstance(a, dict)
                or type(a.get("passed")) is not bool for a in assertions):
            raise ValueError("calibration case has missing/invalid assertions")
        if type(case.get("passed")) is not bool or case["passed"] != all(a["passed"] for a in assertions):
            raise ValueError("case outcome does not agree with its assertions")
        if not isinstance(case.get("terminal_state"), str) or not case["terminal_state"] \
                or not isinstance(case.get("metrics"), dict) or not isinstance(case.get("timeline"), list) or not case["timeline"]:
            raise ValueError("calibration case lacks terminal diagnostics")
        if case["passed"] and (case["terminal_state"] == "failed" or "guard" in case.get("reason", "")):
            raise ValueError("failure guard cannot establish calibration success")
    if sum(case["passed"] for case in cases) != passed:
        raise ValueError("calibration case count disagrees with summary")


def measurements(report: dict) -> str:
    """Compare every domain-provided assertion, metric and normalized timeline."""
    return json.dumps(report["cases"], sort_keys=True, allow_nan=False, separators=(",", ":"))


def run(root: Path, binary: Path, domain: str, artifact: Path, timeout: float) -> dict:
    mods, data = artifact / "mods", artifact / "write-data"
    mods.mkdir(parents=True)
    (data / "saves").mkdir(parents=True)
    for name, source in [("factorio-scv-control", root), ("scv-control-testkit", root / "devmods/scv-control-testkit")]:
        shutil.copytree(source, mods / name, ignore=shutil.ignore_patterns(".git", "__pycache__", "tools", "devmods", "docs"))
    (mods / "mod-list.json").write_text(json_text({"mods": [{"name": name, "enabled": name in
        {"base", "factorio-scv-control", "scv-control-testkit"}} for name in
        ["base", "factorio-scv-control", "scv-control-testkit", "space-age", "quality", "elevated-rails"]]}), encoding="utf-8")
    config = artifact / "config.ini"
    config.write_text("[path]\nread-data=" + (binary.parents[2] / "data").as_posix()
                      + "\nwrite-data=" + data.as_posix() + "\n\n[general]\nlocale=en\n\n[other]\nenable-new-mods=false\n", encoding="utf-8")
    settings = artifact / "server-settings.json"
    settings.write_text(json_text({"name": "SCV domain calibration", "description": "Isolated native-domain measurements",
        "visibility": {"public": False, "lan": False},
        "auto_pause": False, "autosave_interval": 0, "require_user_verification": False}), encoding="utf-8")
    scenario = "gate-calibration" if domain == "gates" else "belt-calibration"
    command = [str(binary), "--config", str(config), "--mod-directory", str(mods),
        "--start-server-load-scenario", "scv-control-testkit/" + scenario, "--map-gen-seed", "424242", "--server-settings", str(settings),
        "--bind", "127.0.0.1:" + str(free_port(socket.SOCK_DGRAM)), "--disable-audio"]
    marker = re.compile(r"SCV_CALIBRATION_COMPLETE domain=" + domain + r" passed=(\d+) failed=(\d+)")
    started = time.monotonic()
    log_path = data / "factorio-current.log"
    with (artifact / "server-console.log").open("w", encoding="utf-8") as console:
        process = subprocess.Popen(command, stdout=console, stderr=subprocess.STDOUT, creationflags=hidden_flags())
        try:
            while True:
                log = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
                match = marker.search(log)
                if match:
                    break
                if process.poll() is not None or "Error while running event" in log or "non-recoverable error" in log:
                    raise ValueError("calibration scenario failed; see " + str(log_path))
                if time.monotonic() - started > timeout:
                    raise ValueError("calibration watchdog exceeded; see " + str(log_path))
                time.sleep(0.1)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    path = data / "script-output/scv-control/calibration" / (domain + ".json")
    report = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_pairs, parse_constant=reject_constant)
    validate_report(report, domain, int(match[1]), int(match[2]))
    report["host_wall_ms"] = (time.monotonic() - started) * 1000
    for case in report["cases"]:
        print(f"[{domain}] {'PASS' if case['passed'] else 'FAIL'} {case['id']}: {case['terminal_state']}", flush=True)
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--domain", choices=["gates", "belts", "all"], default="all")
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--factorio-exe")
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--repeat", type=int, default=2)
    args = parser.parse_args(argv)
    if args.timeout <= 0 or not 1 <= args.repeat <= 10:
        parser.error("timeout must be positive and repeat must be between 1 and 10")
    root = args.project_root.resolve(strict=True)
    artifact = Path(tempfile.mkdtemp(prefix="scv-calibration-"))
    reports = {}
    try:
        binary = executable_path(args.factorio_exe)
        version = subprocess.run([str(binary), "--version"], capture_output=True, text=True,
            creationflags=hidden_flags(), timeout=10, check=True).stdout.strip()
        expected = json.loads((root / "info.json").read_text(encoding="utf-8-sig"))["factorio_version"]
        if not version.startswith("Version: " + expected + "."):
            raise ValueError("Factorio version does not match mod")
        for domain in (["gates", "belts"] if args.domain == "all" else [args.domain]):
            reports[domain] = []
            for index in range(args.repeat):
                print(f"[{domain}] Headless calibration {index + 1}/{args.repeat}", flush=True)
                report = run(root, binary, domain, artifact / f"{domain}-{index + 1}", args.timeout)
                reports[domain].append(report)
                if report["failed"]:
                    raise ValueError(f"{domain}: {report['failed']} failed calibration cases")
                if measurements(report) != measurements(reports[domain][0]):
                    raise ValueError(f"{domain}: repeated native measurements differ")
        summary = {"schema_version": 1, "factorio": version, "repeat": args.repeat, "passed": True,
                   "determinism_checked": args.repeat >= 2, "domains": reports}
        (artifact / "calibration-summary.json").write_text(json.dumps(summary, indent=2, allow_nan=False), encoding="utf-8")
        print("SCV_CALIBRATION_HOST_COMPLETE passed=true", flush=True)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        (artifact / "calibration-failure.json").write_text(json.dumps({"passed": False, "reason": str(error), "domains": reports}, indent=2), encoding="utf-8")
        print("SCV_CALIBRATION_HOST_FAILED " + str(error), flush=True)
        return 1
    finally:
        print("Artifacts: " + str(artifact), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
