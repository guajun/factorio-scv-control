"""Read a published local bulk snapshot; RCON is the control/identity channel.

Only the fixed file below a launcher-owned script-output root is accepted. The
single slot may be reused after termination; request identity prevents an old
consumer from accepting another request's snapshot. Content still goes through
the same solver query/snapshot hash and graph validators before search.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from canonical import content_hash
from rcon import RconError
from solve import reject_constant, reject_pairs
from solver import query_hash

WORK_FILE = "scv-control/navigation/live-work.json"
MAX_BYTES = 16 * 1024 * 1024


def read_work(root: Path, descriptor: object, token: str, session_id: str) -> tuple[dict, dict]:
    started = time.perf_counter()
    if not isinstance(descriptor, dict) or descriptor.get("kind") != "script-output-file-v1":
        raise RconError("missing/unsupported bulk transfer descriptor")
    if descriptor.get("path") != WORK_FILE:
        raise RconError("unexpected bulk file path")
    if descriptor.get("request_token") != token or descriptor.get("session_id") != session_id:
        raise RconError("stale bulk transfer descriptor")
    size = descriptor.get("bytes")
    if type(size) is not int or not 0 < size <= MAX_BYTES:
        raise RconError("invalid bulk file byte count")
    root = root.resolve(strict=True)
    try:
        path = (root / WORK_FILE).resolve(strict=True)
        path.relative_to(root)
        if not path.is_file() or path.stat().st_size != size:
            raise RconError("bulk file missing, incomplete or replaced")
        # Bound the read even if the file changes between stat and open.
        with path.open("rb") as stream:
            raw = stream.read(size + 1)
    except (OSError, ValueError) as error:
        raise RconError("bulk file is unavailable or escapes isolated script-output") from error
    if len(raw) != size:
        raise RconError("bulk file changed while reading")
    read_ms = (time.perf_counter() - started) * 1000
    try:
        work = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_pairs, parse_constant=reject_constant)
        if not isinstance(work, dict) or work.get("protocol") != "scv-navigation/1" or work.get("kind") != "live-work":
            raise ValueError("invalid work envelope")
        query, snapshot = work["query"], work["snapshot"]
        if work.get("request_token") != token or query["session_id"] != session_id:
            raise ValueError("work session/token mismatch")
        if query["query_id"] != descriptor.get("query_id") or query["query_hash"] != descriptor.get("query_hash"):
            raise ValueError("work query identity mismatch")
        if query_hash(query) != descriptor.get("query_hash"):
            raise ValueError("work query content mismatch")
        if query["data_ref"]["snapshot_hash"] != descriptor.get("snapshot_hash"):
            raise ValueError("work snapshot reference mismatch")
        # Validate the source contents before returning them to a solver. This
        # checksum is identity/corruption detection, not authentication.
        if content_hash(snapshot) != descriptor.get("snapshot_hash"):
            raise ValueError("work snapshot content mismatch")
    except (ValueError, TypeError, KeyError, UnicodeError, RecursionError) as error:
        raise RconError("invalid/stale bulk work contents: " + str(error)) from error
    return work, {"transport": "file", "bytes": size, "bulk_rcon_commands": 0,
                  "file_read_ms": read_ms,
                  "read_decode_verify_ms": (time.perf_counter() - started) * 1000}
