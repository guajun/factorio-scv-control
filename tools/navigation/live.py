#!/usr/bin/env python3
"""Run the external solver against an isolated localhost headless Factorio lab.

--test runs arrival and delivery lifecycle assertions, writes a report, and exits.
Without --test the server stays alive for manual GUI joining until interrupted.
"""

from __future__ import annotations

import argparse
import base64
import json
import hashlib
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
import zipfile

from rcon import Rcon, RconError
from bulk_file import read_work
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


def receive_work(client: Rcon, token: str, status: dict, artifact_root: Path,
                 transport: str, timeout: float = 90) -> tuple[dict, dict]:
    if transport == "file":
        return read_work(artifact_root / "write-data/script-output", status.get("transfer"), token, client.session_id)
    if transport != "rcon":
        raise RconError("unsupported snapshot transport")
    started = time.perf_counter()
    work = download(client, token, timeout)
    return work, {"transport": "rcon", "bytes": status["bytes"],
                  "bulk_rcon_commands": (status["bytes"] + CHUNK_BYTES - 1) // CHUNK_BYTES,
                  "read_decode_verify_ms": (time.perf_counter() - started) * 1000}


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


def wait_step(client: Rcon, process: subprocess.Popen, timeout: float) -> dict:
    """Observe native ticks_to_run exhaustion; host wall time is always bounded."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RconError("Factorio exited during debug step")
        value = checked(client.service("clock", action="status"))["clock"]
        if value["paused"] and value["ticks_to_run"] == 0:
            return value
        time.sleep(0.01)
    raise RconError("debug step wall-clock watchdog exceeded")


def evaluate_stepped(client: Rcon, process: subprocess.Popen, artifact_root: Path,
                     timeout: float, transport: str, loaded_save: dict) -> dict:
    """Frozen solver wait is a correctness experiment, never a real-time score."""
    tests = []
    def expect(name: str, passed: bool, detail: object):
        tests.append({"name": name, "passed": bool(passed), "detail": detail})
    before = checked(client.service("clock", action="status"))["clock"]
    expect("loaded-save-retains-paused-source-actor", before["paused"]
           and before["actor_unit_number"] == loaded_save["source"]["actor_unit_number"]
           and before["actor_position"] == loaded_save["clock"]["actor_position"]
           and before["tick"] == loaded_save["clock"]["tick"], before)
    request_started = time.perf_counter()
    checked(client.service("begin", fixture_id=loaded_save["source"]["fixture_id"], source="stored-map"))
    token, status = wait_work(client, process, timeout)
    capture_ready_ms = (time.perf_counter() - request_started) * 1000
    frozen_started = time.perf_counter()
    frozen_before = status["clock"]
    expect("capture-reads-loaded-source-without-rebuild", status.get("world_source", {}).get("build_count") == 1
           and status["world_source"]["actor_unit_number"] == before["actor_unit_number"]
           and status["world_source"]["built_tick"] == loaded_save["source"]["built_tick"], status.get("world_source"))
    work, transfer = receive_work(client, token, status, artifact_root, transport, timeout)
    expect("saved-map-contains-real-obstacles", len(work["snapshot"]["geometry"]["entities"]) > 0,
           len(work["snapshot"]["geometry"]["entities"]))
    solver_started = time.perf_counter()
    result = solve(work["snapshot"], work["query"])
    solver_wall_ms = (time.perf_counter() - solver_started) * 1000
    validate_result(work["snapshot"], work["query"], result)
    # An explicit artificial solver delay proves that paused entity time does
    # not advance with host wall time; report it independently from solve work.
    wait_started = time.perf_counter()
    time.sleep(0.25)
    artificial_wait_ms = (time.perf_counter() - wait_started) * 1000
    before_upload = checked(client.service("poll", request_token=token))
    expect("rcon-responds-while-native-world-is-frozen", before_upload["clock"]["tick"] == frozen_before["tick"]
           and before_upload["clock"]["actor_position"] == frozen_before["actor_position"]
           and before_upload["clock"]["ticks_played"] > frozen_before["ticks_played"], before_upload["clock"])
    admitted = upload(client, token, result, timeout)
    pending_solver_wall_ms = (time.perf_counter() - frozen_started) * 1000
    frozen_world_wall_ms = (time.perf_counter() - request_started) * 1000
    expect("external-result-admitted-without-advancing-world", result_admitted(admitted)
           and admitted["clock"]["tick"] == before["tick"]
           and admitted["clock"]["actor_position"] == before["actor_position"], admitted)
    for invalid in (0, -1, 1.5, 3601, True):
        rejected = client.service("clock", action="step", ticks=invalid)
        expect("invalid-step-rejected-" + str(invalid), rejected.get("ok") is False
               and rejected.get("reason") == "invalid-step-ticks", rejected)
    checked(client.service("clock", action="step", ticks=3))
    three = wait_step(client, process, timeout)
    expect("native-step-advances-exactly-three-ticks-and-character", three["tick"] - before["tick"] == 3
           and three["actor_position"] != before["actor_position"], {"before": before, "after": three})
    time.sleep(0.1)
    still = checked(client.service("clock", action="status"))["clock"]
    expect("completed-step-remains-frozen", still["tick"] == three["tick"]
           and still["actor_position"] == three["actor_position"], still)
    deadline = time.monotonic() + timeout
    steps = 1
    while time.monotonic() < deadline:
        terminal = checked(client.service("poll", request_token=token))
        if terminal.get("terminal"):
            break
        checked(client.service("clock", action="step", ticks=30))
        wait_step(client, process, max(0.1, deadline - time.monotonic()))
        steps += 1
    else:
        raise RconError("stepped follower wall-clock watchdog exceeded")
    expect("stepped-native-follower-arrived", terminal["status"] == "arrived"
           and terminal["terminal"].get("arrival_error", float("inf")) <= work["query"]["execution"]["arrival_tolerance"], terminal)
    resumed = checked(client.service("clock", action="resume"))["clock"]
    realtime_step = client.service("clock", action="step", ticks=1)
    expect("resume-restores-real-time-and-disallows-stepping", resumed["paused"] is False
           and realtime_step.get("reason") == "step-requires-paused-clock", realtime_step)
    time.sleep(0.1)
    after_resume = checked(client.service("clock", action="pause"))["clock"]
    expect("resume-advances-native-game-time", after_resume["tick"] > resumed["tick"], after_resume)
    checked(client.service("clock", action="step", ticks=3600))
    overlap = client.service("clock", action="step", ticks=1)
    interrupted = checked(client.service("clock", action="pause"))["clock"]
    expect("overlapping-step-rejected-and-pause-cancels-budget", overlap.get("reason") == "step-already-running"
           and interrupted["paused"] and interrupted["ticks_to_run"] == 0,
           {"overlap": overlap, "interrupted": interrupted})
    (artifact_root / "live-work.json").write_text(json.dumps(work, indent=2), encoding="utf-8")
    (artifact_root / "live-result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    return {"schema_version": 1, "suite": "live-navigation", "clock_mode": "debug-stepped",
            "real_time_performance_evidence": False, "passed": sum(t["passed"] for t in tests),
            "failed": sum(not t["passed"] for t in tests), "tests": tests, "loaded_save": loaded_save,
            "solver_wall_ms": solver_wall_ms, "artificial_wait_ms": artificial_wait_ms,
            "pending_solver_wall_ms": pending_solver_wall_ms,
            "frozen_world_wall_ms": frozen_world_wall_ms, "frozen_world_simulation_ticks": admitted["clock"]["tick"] - before["tick"],
            "capture_ready_ms": capture_ready_ms, "transfer": transfer,
            "native_travel_ticks": terminal["terminal"].get("actual_travel_ticks"), "step_commands": steps,
            "command_to_terminal_wall_ms": (time.perf_counter() - request_started) * 1000,
            "snapshot_id": work["snapshot"]["snapshot_id"], "query_hash": work["query"]["query_hash"]}


def evaluate(client: Rcon, process: subprocess.Popen, artifact_root: Path, timeout: float,
             transport: str = "file", compare_transports: bool = False) -> dict:
    tests = []
    def expect(name: str, passed: bool, detail: object):
        tests.append({"name": name, "passed": bool(passed), "detail": detail})
    request_started = time.perf_counter()
    checked(client.service("begin", fixture_id="open-diagonal"))
    token, status = wait_work(client, process, timeout)
    capture_ready_ms = (time.perf_counter() - request_started) * 1000
    work, transfer = receive_work(client, token, status, artifact_root, transport, timeout)
    comparison = None
    if compare_transports:
        other_work, comparison = receive_work(client, token, status, artifact_root, "rcon", timeout)
        expect("bulk-transports-preserve-identical-problem", work == other_work,
               {"selected": transfer, "comparison": comparison})
    if transport == "file":
        expect("bulk-file-avoids-per-chunk-rcon", transfer["bulk_rcon_commands"] == 0
               and transfer["bytes"] == status["bytes"], transfer)
    started = time.perf_counter()
    result = solve(work["snapshot"], work["query"])
    solve_ms = (time.perf_counter() - started) * 1000
    validation_started = time.perf_counter()
    validate_result(work["snapshot"], work["query"], result)
    result_validation_ms = (time.perf_counter() - validation_started) * 1000
    (artifact_root / "live-work.json").write_text(json.dumps(work, indent=2), encoding="utf-8")
    (artifact_root / "live-result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    admission_started = time.perf_counter()
    admitted = upload(client, token, result, timeout)
    admission_ms = (time.perf_counter() - admission_started) * 1000
    command_to_admission_ms = (time.perf_counter() - request_started) * 1000
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
    cancelled_token, old_status = wait_work(client, process, timeout)
    old_work, _ = receive_work(client, cancelled_token, old_status, artifact_root, transport, timeout)
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
    stale_token, stale_status = wait_work(client, process, timeout)
    stale_work, _ = receive_work(client, stale_token, stale_status, artifact_root, transport, timeout)
    stale_result = solve(stale_work["snapshot"], stale_work["query"])
    checked(client.service("capabilities", nonce="test-reconnect-" + uuid.uuid4().hex))
    stale = upload(client, stale_token, stale_result)
    expect("prior-session-result-rejected", stale.get("ok") is False and stale.get("reason") == "stale-request", stale)
    return {"schema_version": 1, "suite": "live-navigation", "passed": sum(test["passed"] for test in tests),
            "failed": sum(not test["passed"] for test in tests), "tests": tests,
            "snapshot_id": work["snapshot"]["snapshot_id"], "query_hash": work["query"]["query_hash"],
            "solver_ms": solve_ms, "result_outcome": result["outcome"],
            "capture_ready_ms": capture_ready_ms, "transfer": transfer,
            "transport_comparison": comparison, "upload_admission_ms": admission_ms,
            "result_validation_ms": result_validation_ms,
            "command_to_admission_ms": command_to_admission_ms,
            "command_timing_includes_comparison": compare_transports}


def run_worker(client: Rcon, process: subprocess.Popen, artifact_root: Path, transport: str = "file") -> None:
    handled = set()
    while process.poll() is None:
        answer = checked(client.service("poll"))
        token = work_token(answer)
        if token and token not in handled and answer.get("status") == "pending":
            work, transfer = receive_work(client, token, answer, artifact_root, transport)
            result = solve(work["snapshot"], work["query"])
            answer = upload(client, token, result)
            handled.add(token)
            (artifact_root / "latest-work.json").write_text(json.dumps(work, indent=2), encoding="utf-8")
            (artifact_root / "latest-result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
            (artifact_root / "latest-transfer.json").write_text(json.dumps(transfer, indent=2), encoding="utf-8")
            print("SCV_LIVE_SOLVED " + json_text({"token": token, "outcome": result["outcome"],
                                                  "admitted": result_admitted(answer), "game_status": answer.get("status"),
                                                  "reason": answer.get("reason")}), flush=True)
        time.sleep(0.1)


def connect_server(process: subprocess.Popen, port: int, password: str, timeout: float) -> Rcon:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RconError("Factorio exited during startup; inspect isolated logs")
        try:
            return Rcon("127.0.0.1", port, password, timeout=min(10, timeout))
        except (ConnectionError, OSError):
            time.sleep(0.2)
    raise RconError("headless RCON startup watchdog exceeded")


def wait_saved_map(path: Path, process: subprocess.Popen, timeout: float) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RconError("Factorio exited before saving the source map")
        try:
            with zipfile.ZipFile(path) as archive:
                members = archive.namelist()
                # Factorio 2.0 writes a variable number of contiguous shards.
                # Small maps can contain only level.dat0; assuming dat1 exists
                # rejects a complete ZIP. This only checks publication shape:
                # the subsequent native restart validates the actual save.
                shards = sorted(int(match.group(1)) for name in members
                                if (match := re.search(r"/level\.dat(\d+)$", name)))
                has_level = any(name.endswith("/level.dat") for name in members) or (
                    bool(shards) and shards == list(range(len(shards)))
                    and any(name.endswith("/level.datmetadata") for name in members))
                if has_level and any(name.endswith("/script.dat") for name in members) and archive.testzip() is None:
                    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                            "bytes": path.stat().st_size}
        except (OSError, zipfile.BadZipFile):
            pass
        time.sleep(0.05)
    raise RconError("source map save watchdog exceeded")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--factorio-exe")
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--port", type=int, default=0, help="GUI join port; random unused loopback port by default")
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--artifact-root", type=Path)
    parser.add_argument("--scenario", default="scv-control-testkit/navigation-live")
    parser.add_argument("--snapshot-transport", choices=("file", "rcon"), default="file")
    parser.add_argument("--compare-transports", action="store_true", help="With --test, compare the same snapshot against legacy RCON chunks")
    parser.add_argument("--solver-clock", choices=("realtime", "stepped"), default="realtime",
                        help="Stepped --test saves and reloads a real map, then freezes entity time while solving; never a realtime speed claim")
    args = parser.parse_args(argv)
    if args.timeout <= 0 or args.port < 0 or args.port > 65535:
        parser.error("invalid timeout/port")
    if args.compare_transports and (not args.test or args.snapshot_transport != "file"):
        parser.error("--compare-transports requires --test and --snapshot-transport file")
    if args.solver_clock == "stepped" and (not args.test or args.compare_transports):
        parser.error("--solver-clock stepped requires --test and cannot compare transports")
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
            client = connect_server(process, rcon_port, password, args.timeout)
            def record_rpc(record: dict):
                with (artifact_root / "rpc-trace.jsonl").open("a", encoding="utf-8") as trace:
                    trace.write(json_text(record) + "\n")
            client.trace = record_rpc
            capabilities = checked(client.service("capabilities", nonce="host-" + uuid.uuid4().hex,
                                                  snapshot_transport=args.snapshot_transport, solver_clock=args.solver_clock))
            loaded_save = None
            if args.solver_clock == "stepped":
                prepared = checked(client.service("prepare-save", fixture_id="long-wall-return", name="scv-nav-debug-source"))
                saved_path = data / "saves/scv-nav-debug-source.zip"
                loaded_save = {**wait_saved_map(saved_path, process, args.timeout),
                               "source": prepared["source"], "clock": prepared["clock"]}
                client.close()
                client = None
                process.terminate()
                process.wait(timeout=10)
                source_index = arguments.index("--start-server-load-scenario")
                arguments[source_index:source_index + 2] = ["--start-server", str(saved_path)]
                process = subprocess.Popen(arguments, stdout=console, stderr=subprocess.STDOUT,
                                           creationflags=hidden_flags())
                client = connect_server(process, rcon_port, password, args.timeout)
                client.trace = record_rpc
                capabilities = checked(client.service("capabilities", nonce="reload-" + uuid.uuid4().hex,
                                                      snapshot_transport=args.snapshot_transport, solver_clock=args.solver_clock))
                if hashlib.sha256(saved_path.read_bytes()).hexdigest() != loaded_save["sha256"]:
                    raise RconError("source save changed during reload")
            gui_profile = client_profile(artifact_root, binary, mods, f"127.0.0.1:{game_port}")
            metadata = {"version": version.splitlines()[0], "pid": process.pid, "join_address": f"127.0.0.1:{game_port}",
                        "rcon_address": f"127.0.0.1:{rcon_port}", "scenario": args.scenario,
                        "capabilities": capabilities, "artifact_root": str(artifact_root), "gui_client": gui_profile,
                        "snapshot_transport": args.snapshot_transport, "solver_clock": args.solver_clock,
                        "loaded_save": loaded_save}
            (artifact_root / "live-session.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
            print("SCV_LIVE_READY " + json_text(metadata), flush=True)
            if args.test:
                report = (evaluate_stepped(client, process, artifact_root, args.timeout, args.snapshot_transport, loaded_save)
                          if args.solver_clock == "stepped" else
                          evaluate(client, process, artifact_root, args.timeout, args.snapshot_transport, args.compare_transports))
                if args.solver_clock == "realtime":
                    report["clock_mode"], report["real_time_performance_evidence"] = "realtime", True
                report["factorio"] = version.splitlines()[0]
                (artifact_root / "live-report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
                print(f"SCV_LIVE_COMPLETE passed={report['passed']} failed={report['failed']}", flush=True)
                return 0 if report["failed"] == 0 else 1
            print("Manual GUI profile: " + gui_profile["instructions"] + ". Stop this host with Ctrl+C.", flush=True)
            run_worker(client, process, artifact_root, args.snapshot_transport)
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
