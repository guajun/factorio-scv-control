#!/usr/bin/env python3
"""Validate an external solver bundle and replay in an isolated Factorio copy.

Uses the shared interchange scenario and production validators/native follower.
Never changes the current imported catalog or starts a graphical client.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from live import hidden_flags
from solve import lua_module, read_json
from solver import PROTOCOL, sequence, validate_result


def validated_bundle(bundle):
    if not isinstance(bundle, dict) or bundle.get("protocol") != PROTOCOL or bundle.get("kind") != "solver-bundle":
        raise ValueError("expected solver-bundle")
    cases = sequence(bundle.get("cases"), "cases", 1000)
    if not cases:
        raise ValueError("empty replay bundle")
    seen = set()
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str) or case["id"] in seen:
            raise ValueError("invalid/duplicate replay case")
        seen.add(case["id"])
        validate_result(case["snapshot"], case["query"], case["result"])
    return bundle


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--factorio-exe")
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args(argv)
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    artifact = Path(tempfile.mkdtemp(prefix="scv-bundle-replay-"))
    try:
        bundle = validated_bundle(read_json(args.bundle))
        root = args.project_root.resolve(strict=True)
        project = artifact / "project"
        project.mkdir()
        for folder in ["scripts", "scenarios", "devmods", "tools", "locale"]:
            shutil.copytree(root / folder, project / folder, ignore=shutil.ignore_patterns(
                ".venv", ".venv312", "artifacts", "__pycache__"))
        for filename in ["control.lua", "data.lua", "settings.lua", "info.json"]:
            shutil.copy2(root / filename, project / filename)
        (project / "devmods/scv-control-testkit/interchange/imported_plans.lua").write_text(lua_module(bundle), encoding="utf-8")
        command = ["pwsh", "-NoProfile", "-File", str(project / "tools/test.ps1"), "-Suite", "interchange",
                   "-KeepArtifacts", "-TimeoutSeconds", str(args.timeout)]
        if args.factorio_exe:
            command += ["-FactorioExe", args.factorio_exe]
        # The owned PowerShell runner enforces the process watchdog and only
        # terminates Factorio it starts. Do not add a parent timeout that orphans it.
        result = subprocess.run(command, capture_output=True, text=True, creationflags=hidden_flags())
        (artifact / "runner.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        print(result.stdout, end="", flush=True)
        matches = re.findall(r"(?m)^Artifacts:\s*(.+?)\s*$", result.stdout)
        manifest = {"schema": "scv-bundle-replay/1", "bundle": str(args.bundle.resolve()),
                    "case_count": len(bundle["cases"]), "exit_code": result.returncode,
                    "replay_root": matches[-1] if matches else None,
                    "cases": [{"id": case["id"], "query_hash": case["query"]["query_hash"],
                               "solver_outcome": case["result"]["outcome"]} for case in bundle["cases"]]}
        (artifact / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        if result.returncode or not matches:
            raise ValueError("native replay failed; inspect retained runner.log and manifest")
        print("SCV_BUNDLE_REPLAY_COMPLETE", flush=True)
        return 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print("SCV_BUNDLE_REPLAY_FAILED " + str(error), flush=True)
        return 1
    finally:
        print("Bundle replay artifacts: " + str(artifact), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
