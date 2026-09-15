#!/usr/bin/env python3
"""Run the external solver against an isolated localhost headless Factorio lab.

--test runs arrival and delivery lifecycle assertions, writes a report, and exits.
Without --test the server stays alive for manual GUI joining until interrupted.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid

from rcon import Rcon, RconError
from solve import reject_constant, reject_pairs
from solver import solve, validate_result

MAX_TRANSFER = 16 * 1024 * 1024
CHUNK_BYTES = 3000


def json_text(value: object) -> str:
    return json.dumps(value, ensure_ascii=True, allow_nan=False, separators=(",", ":"))


def hidden_flags() -> int:
    return subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


def executable_path(explicit: str | None) -> Path:
    if explicit or os.environ.get("FACTORIO_EXE"):
        candidate = Path(explicit or os.environ["FACTORIO_EXE"]).resolve()
        if not candidate.is_file():
            raise ValueError("Factorio executable does not exist")
        return candidate
    libraries = []
    if os.name == "nt":
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
                libraries.append(Path(winreg.QueryValueEx(key, "SteamPath")[0]))
        except OSError:
            pass
        libraries.append(Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Steam")
        for library in list(libraries):
            source = library / "steamapps/libraryfolders.vdf"
            if source.is_file():
                libraries.extend(Path(value.replace("\\\\", "\\"))
                                 for value in re.findall(r'"path"\s+"([^\"]+)"', source.read_text(encoding="utf-8")))
    candidates = [root / "steamapps/common/Factorio/bin/x64/factorio.exe" for root in libraries]
    candidates += [Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Factorio/bin/x64/factorio.exe"]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise ValueError("Factorio not found; pass --factorio-exe or set FACTORIO_EXE")


def free_port(kind: int) -> int:
    with socket.socket(socket.AF_INET, kind) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def checked(answer: dict) -> dict:
    if answer.get("ok") is not True:
        raise RconError("navigation service rejected operation: " + json_text(answer))
    return answer


def result_admitted(answer: dict) -> bool:
    return (answer.get("ok") is True and answer.get("committed") is True
            and answer.get("admission_count") == 1 and answer.get("status") in {"moving", "arrived"})


def client_profile(artifact_root: Path, binary: Path, mods: Path, address: str) -> dict:
    """Prepare an explicit manual client launch; never start graphical Factorio."""
    client_data = artifact_root / "client-write-data"
    client_data.mkdir(exist_ok=True)
    (client_data / "saves").mkdir(exist_ok=True)
    config = artifact_root / "client-config.ini"
    config.write_text("[path]\nread-data=" + (binary.parents[2] / "data").as_posix()
                      + "\nwrite-data=" + client_data.as_posix()
                      + "\n\n[general]\nlocale=en\n\n[other]\nenable-new-mods=true\n", encoding="utf-8")
    # Single-quoted PowerShell literals double apostrophes. No solver values enter
    # this command, and the file is only executed manually by the user.
    quote = lambda value: "'" + str(value).replace("'", "''") + "'"
    command = "& " + " ".join(quote(item) for item in [binary, "--config", config,
                                                       "--mod-directory", mods, "--mp-connect", address])
    launcher = artifact_root / "join-client.ps1"
    launcher.write_text("# Manual graphical client launch with the exact server mod copy.\n"
                        + "$ErrorActionPreference = 'Stop'\n" + command + "\n", encoding="utf-8")
    (artifact_root / "JOIN-CLIENT.txt").write_text(
        "Keep the headless live.py host running. Close any other graphical Factorio instance, then manually run:\n\n"
        + "pwsh -NoProfile -File " + quote(launcher) + "\n\n"
        + "This uses the server's copied mods and a separate client config/write-data directory.\n"
        + "It does not use or change your normal mod junctions or saves. Steam may show its normal manual launch confirmation.\n"
        + "Once connected: /scv-nav-live open-diagonal\nStatus: /scv-nav-live status\nReturn: /scv-nav-live return\n",
        encoding="utf-8")
    return {"config": str(config), "mods": str(mods), "manual_launcher": str(launcher),
            "instructions": str(artifact_root / "JOIN-CLIENT.txt")}


def work_token(answer: dict) -> str | None:
    return answer.get("request_token") or (answer.get("work") or {}).get("request_token")


def download(client: Rcon, token: str, timeout: float = 90) -> dict:
    chunks = bytearray()
    total = None
    deadline = time.monotonic() + timeout
    while total is None or len(chunks) < total:
        if time.monotonic() >= deadline:
            raise RconError("download transfer watchdog exceeded")
        answer = checked(client.service("download", request_token=token,
                                        offset=len(chunks), max_bytes=CHUNK_BYTES))
        if answer.get("request_token") != token:
            raise RconError("download response request token mismatch")
        size = answer.get("total_bytes", answer.get("bytes"))
        if not isinstance(size, int) or not 0 < size <= MAX_TRANSFER or total is not None and size != total:
            raise RconError("invalid/changing download byte count")
        if answer.get("offset") != len(chunks):
            raise RconError("download offset mismatch")
        try:
            data = (base64.b64decode(answer["data"], validate=True) if answer.get("encoding") == "base64"
                    else answer["data"].encode("ascii"))
        except (ValueError, KeyError) as error:
            raise RconError("invalid download base64") from error
        if not data or len(data) > CHUNK_BYTES or len(chunks) + len(data) > size:
            raise RconError("invalid download chunk length")
        chunks.extend(data)
        total = size
    try:
        work = json.loads(chunks.decode("utf-8"), object_pairs_hook=reject_pairs, parse_constant=reject_constant)
    except (UnicodeError, ValueError) as error:
        raise RconError("invalid downloaded problem JSON") from error
    if not isinstance(work, dict) or not isinstance(work.get("snapshot"), dict) or not isinstance(work.get("query"), dict):
        raise RconError("download omitted snapshot/query")
    if work.get("request_token", token) != token:
        raise RconError("download work token mismatch")
    return work


def upload(client: Rcon, token: str, result: dict, timeout: float = 90) -> dict:
    data = json_text(result).encode("utf-8")
    if len(data) > MAX_TRANSFER:
        raise RconError("result transfer exceeds limit")
    total = (len(data) + CHUNK_BYTES - 1) // CHUNK_BYTES
    deadline = time.monotonic() + timeout
    for index in range(total):
        if time.monotonic() >= deadline:
            raise RconError("upload transfer watchdog exceeded")
        answer = client.service("upload", request_token=token, index=index + 1, total=total,
                                data=data[index * CHUNK_BYTES:(index + 1) * CHUNK_BYTES].decode("ascii"))
        if not answer.get("ok"):
            return answer
    return client.service("commit", request_token=token, total_chunks=total)


def wait_work(client: Rcon, process: subprocess.Popen, timeout: float) -> tuple[str, dict]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RconError("Factorio process exited before providing work")
        answer = checked(client.service("poll"))
        token = work_token(answer)
        if token and answer.get("status") in {"pending", "waiting", "waiting-result", "ready", "planning"}:
            return token, answer
        if token and answer.get("work"):
            return token, answer
        if answer.get("status") in {"failed", "error", "rejected"}:
            raise RconError("game could not prepare navigation work: " + json_text(answer))
        time.sleep(0.05)
    raise RconError("timed out waiting for navigation work")


def wait_terminal(client: Rcon, process: subprocess.Popen, token: str, timeout: float) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RconError("Factorio process exited during movement")
        answer = checked(client.service("poll", request_token=token))
        if answer.get("status") in {"arrived", "failed", "no-path", "cancelled", "rejected", "stale-world", "error"}:
            return answer
        time.sleep(0.05)
    raise RconError("native movement did not reach a terminal state before watchdog")


def evaluate(client: Rcon, process: subprocess.Popen, artifact_root: Path, timeout: float) -> dict:
    tests = []
    def expect(name: str, passed: bool, detail: object):
        tests.append({"name": name, "passed": bool(passed), "detail": detail})
    checked(client.service("begin", fixture_id="open-diagonal"))
    token, _ = wait_work(client, process, timeout)
    work = download(client, token, timeout)
    started = time.perf_counter()
    result = solve(work["snapshot"], work["query"])
    solve_ms = (time.perf_counter() - started) * 1000
    validate_result(work["snapshot"], work["query"], result)
    (artifact_root / "live-work.json").write_text(json.dumps(work, indent=2), encoding="utf-8")
    (artifact_root / "live-result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    admitted = upload(client, token, result, timeout)
    expect("external-result-admitted", result_admitted(admitted), admitted)
    if result_admitted(admitted):
        duplicate = client.service("commit", request_token=token)
        after_duplicate = checked(client.service("poll", request_token=token))
        expect("duplicate-result-rejected-without-readmission", duplicate.get("ok") is False
               and duplicate.get("reason") == "duplicate-result" and after_duplicate.get("admission_count") == 1,
               {"duplicate": duplicate, "after_duplicate": after_duplicate})
        terminal = wait_terminal(client, process, token, timeout)
        expect("native-follower-arrived", terminal.get("status") == "arrived"
               and terminal.get("admission_count") == 1
               and (terminal.get("terminal") or {}).get("execution_arrival_tolerance") == work["query"]["execution"]["arrival_tolerance"]
               and (terminal.get("terminal") or {}).get("arrival_error", float("inf")) <= work["query"]["execution"]["arrival_tolerance"], terminal)
    checked(client.service("begin", fixture_id="open-diagonal"))
    cancelled_token, _ = wait_work(client, process, timeout)
    old_work = download(client, cancelled_token, timeout)
    old_result = solve(old_work["snapshot"], old_work["query"])
    cancel = client.service("cancel", request_token=cancelled_token)
    expect("cancel-request", cancel.get("ok") is True and cancel.get("status") == "cancelled"
           and cancel.get("admission_count") == 0, cancel)
    late = upload(client, cancelled_token, old_result)
    after_cancel = checked(client.service("poll", request_token=cancelled_token))
    expect("cancelled-result-rejected", late.get("ok") is False and late.get("reason") == "request-not-pending"
           and after_cancel.get("admission_count") == 0,
           {"late": late, "after_cancel": after_cancel})
    checked(client.service("begin", fixture_id="open-diagonal"))
    stale_token, _ = wait_work(client, process, timeout)
    stale_work = download(client, stale_token, timeout)
    stale_result = solve(stale_work["snapshot"], stale_work["query"])
    checked(client.service("capabilities", nonce="test-reconnect-" + uuid.uuid4().hex))
    stale = upload(client, stale_token, stale_result)
    expect("prior-session-result-rejected", stale.get("ok") is False and stale.get("reason") == "stale-request", stale)
    return {"schema_version": 1, "suite": "live-navigation", "passed": sum(test["passed"] for test in tests),
            "failed": sum(not test["passed"] for test in tests), "tests": tests,
            "snapshot_id": work["snapshot"]["snapshot_id"], "query_hash": work["query"]["query_hash"],
            "solver_ms": solve_ms, "result_outcome": result["outcome"]}


def run_worker(client: Rcon, process: subprocess.Popen, artifact_root: Path) -> None:
    handled = set()
    while process.poll() is None:
        answer = checked(client.service("poll"))
        token = work_token(answer)
        if token and token not in handled and answer.get("status") == "pending":
            work = download(client, token)
            result = solve(work["snapshot"], work["query"])
            answer = upload(client, token, result)
            handled.add(token)
            (artifact_root / "latest-work.json").write_text(json.dumps(work, indent=2), encoding="utf-8")
            (artifact_root / "latest-result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
            print("SCV_LIVE_SOLVED " + json_text({"token": token, "outcome": result["outcome"],
                                                  "admitted": result_admitted(answer), "game_status": answer.get("status"),
                                                  "reason": answer.get("reason")}), flush=True)
        time.sleep(0.1)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--factorio-exe")
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--port", type=int, default=0, help="GUI join port; random unused loopback port by default")
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--artifact-root", type=Path)
    parser.add_argument("--scenario", default="scv-control-testkit/navigation-live")
    args = parser.parse_args(argv)
    if args.timeout <= 0 or args.port < 0 or args.port > 65535:
        parser.error("invalid timeout/port")
    root = Path(__file__).resolve().parents[2]
    artifact_root = args.artifact_root.resolve() if args.artifact_root else Path(tempfile.mkdtemp(prefix="factorio-scv-live-"))
    artifact_root.mkdir(parents=True, exist_ok=True)
    process = None
    client = None
    try:
        binary = executable_path(args.factorio_exe)
        version = subprocess.run([str(binary), "--version"], capture_output=True, text=True,
                                 timeout=10, creationflags=hidden_flags(), check=True).stdout.strip()
        required_version = json.loads((root / "info.json").read_text(encoding="utf-8-sig"))["factorio_version"]
        if not version.startswith("Version: " + required_version + "."):
            raise ValueError("Factorio version does not match mod")
        help_output = subprocess.run([str(binary), "--help"], capture_output=True, text=True,
                                     timeout=10, creationflags=hidden_flags(), check=True).stdout
        if "--rcon-bind" not in help_output or "--start-server-load-scenario" not in help_output:
            raise ValueError("installed Factorio lacks required headless/RCON flags")
        mods, data = artifact_root / "mods", artifact_root / "write-data"
        mods.mkdir(exist_ok=True)
        data.mkdir(exist_ok=True)
        (data / "saves").mkdir(exist_ok=True)
        for name, source in [("factorio-scv-control", root), ("scv-control-testkit", root / "devmods/scv-control-testkit")]:
            target = mods / name
            if target.exists():
                raise ValueError("artifact root already contains a mod copy; select a fresh root")
            shutil.copytree(source, target, ignore=shutil.ignore_patterns(".git", "__pycache__", "tools", "devmods", "docs"))
        (mods / "mod-list.json").write_text(json_text({"mods": [{"name": name, "enabled": True}
                                                               for name in ["base", "factorio-scv-control", "scv-control-testkit"]]}), encoding="utf-8")
        config = artifact_root / "config.ini"
        config.write_text("[path]\nread-data=" + (binary.parents[2] / "data").as_posix()
                          + "\nwrite-data=" + data.as_posix() + "\n\n[general]\nlocale=en\n\n[other]\nenable-new-mods=true\n", encoding="utf-8")
        settings = artifact_root / "server-settings.json"
        settings.write_text(json_text({"name": "SCV External Solver Lab", "description": "Local headless navigation lab",
                                        "visibility": {"public": False, "lan": False}, "auto_pause": False,
                                        "autosave_interval": 0, "require_user_verification": False}), encoding="utf-8")
        game_port = args.port or free_port(socket.SOCK_DGRAM)
        rcon_port = free_port(socket.SOCK_STREAM)
        password = secrets.token_urlsafe(32)
        arguments = [str(binary), "--config", str(config), "--mod-directory", str(mods),
                     "--start-server-load-scenario", args.scenario, "--server-settings", str(settings),
                     "--bind", "127.0.0.1:" + str(game_port), "--rcon-bind", "127.0.0.1:" + str(rcon_port),
                     "--rcon-password", password, "--disable-audio"]
        with (artifact_root / "server-console.log").open("w", encoding="utf-8") as console:
            process = subprocess.Popen(arguments, stdout=console, stderr=subprocess.STDOUT,
                                       creationflags=hidden_flags())
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RconError("Factorio exited during startup; inspect isolated logs")
                try:
                    client = Rcon("127.0.0.1", rcon_port, password, timeout=10)
                    break
                except (ConnectionError, OSError):
                    time.sleep(0.2)
            if client is None:
                raise RconError("headless RCON startup watchdog exceeded")
            def record_rpc(record: dict):
                with (artifact_root / "rpc-trace.jsonl").open("a", encoding="utf-8") as trace:
                    trace.write(json_text(record) + "\n")
            client.trace = record_rpc
            capabilities = checked(client.service("capabilities", nonce="host-" + uuid.uuid4().hex))
            gui_profile = client_profile(artifact_root, binary, mods, f"127.0.0.1:{game_port}")
            metadata = {"version": version.splitlines()[0], "pid": process.pid, "join_address": f"127.0.0.1:{game_port}",
                        "rcon_address": f"127.0.0.1:{rcon_port}", "scenario": args.scenario,
                        "capabilities": capabilities, "artifact_root": str(artifact_root), "gui_client": gui_profile}
            (artifact_root / "live-session.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
            print("SCV_LIVE_READY " + json_text(metadata), flush=True)
            if args.test:
                report = evaluate(client, process, artifact_root, args.timeout)
                report["factorio"] = version.splitlines()[0]
                (artifact_root / "live-report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
                print(f"SCV_LIVE_COMPLETE passed={report['passed']} failed={report['failed']}", flush=True)
                return 0 if report["failed"] == 0 else 1
            print("Manual GUI profile: " + gui_profile["instructions"] + ". Stop this host with Ctrl+C.", flush=True)
            run_worker(client, process, artifact_root)
        return 0
    except KeyboardInterrupt:
        print("SCV_LIVE_STOPPED", flush=True)
        return 0
    except (OSError, ValueError, RconError, subprocess.SubprocessError) as error:
        print("SCV_LIVE_ERROR " + str(error), file=sys.stderr, flush=True)
        return 2
    finally:
        if client is not None:
            client.close()
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        print("Artifacts: " + str(artifact_root), flush=True)


if __name__ == "__main__":
    sys.exit(main())
