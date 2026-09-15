"""Bounded synchronous Factorio RCON client using only the Python stdlib.

TCP reads are framed by the declared packet length, not recv() boundaries. A
single command is in flight; Factorio's response framing is probed by live.py.
"""

from __future__ import annotations

import json
import socket
import struct
import time

from solve import reject_constant, reject_pairs

MAX_PACKET = 16 * 1024 * 1024
MAX_COMMAND = 64 * 1024
SERVICE = "/scv-nav-agent "


class RconError(RuntimeError):
    pass


def packet(request_id: int, kind: int, body: str) -> bytes:
    encoded = body.encode("utf-8")
    if b"\x00" in encoded or len(encoded) > MAX_COMMAND:
        raise RconError("RCON request body has NUL or exceeds command limit")
    payload = struct.pack("<ii", request_id, kind) + encoded + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def read_exact(connection: socket.socket, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        data = connection.recv(count - len(chunks))
        if not data:
            raise RconError("RCON connection closed mid-frame")
        chunks.extend(data)
    return bytes(chunks)


def read_packet(connection: socket.socket) -> tuple[int, int, str]:
    size = struct.unpack("<i", read_exact(connection, 4))[0]
    if not 10 <= size <= MAX_PACKET:
        raise RconError("invalid or oversized RCON frame")
    payload = read_exact(connection, size)
    if payload[-2:] != b"\x00\x00" or b"\x00" in payload[8:-2]:
        raise RconError("invalid RCON string terminators")
    request_id, kind = struct.unpack("<ii", payload[:8])
    try:
        body = payload[8:-2].decode("utf-8", "strict")
    except UnicodeError as error:
        raise RconError("RCON response is not UTF-8") from error
    return request_id, kind, body


class Rcon:
    def __init__(self, host: str, port: int, password: str, timeout: float = 10):
        if host not in {"127.0.0.1", "localhost", "::1"}:
            raise RconError("navigation RCON is restricted to loopback")
        self.connection = socket.create_connection((host, port), timeout)
        self.connection.settimeout(timeout)
        self.request_id = 1
        self.session_id = None
        self.trace = None
        try:
            self.connection.sendall(packet(self.request_id, 3, password))
            # Source authentication may include an empty RESPONSE_VALUE before
            # AUTH_RESPONSE; bound the count rather than waiting indefinitely.
            for _ in range(3):
                response_id, kind, body = read_packet(self.connection)
                if kind == 2:
                    if response_id != self.request_id:
                        raise RconError("RCON authentication rejected")
                    return
                if kind != 0 or response_id not in {self.request_id, 0} or body:
                    raise RconError("unexpected RCON authentication frame")
            raise RconError("RCON authentication response missing")
        except BaseException:
            self.close()
            raise

    def close(self) -> None:
        self.connection.close()

    def __enter__(self) -> "Rcon":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def command(self, text: str) -> str:
        self.request_id += 1
        if self.request_id >= 2**31:
            raise RconError("RCON request ID exhausted; reconnect")
        self.connection.sendall(packet(self.request_id, 2, text))
        request_id, kind, body = read_packet(self.connection)
        if request_id != self.request_id or kind != 0:
            raise RconError("RCON response correlation mismatch")
        return body

    def service(self, operation: str, **fields: object) -> dict:
        if not operation or any(character not in "abcdefghijklmnopqrstuvwxyz-" for character in operation):
            raise RconError("invalid navigation operation")
        request = {"protocol": "scv-navigation/1", "operation": operation, **fields}
        if self.session_id and "session_id" not in request:
            request["session_id"] = self.session_id
        text = SERVICE + json.dumps(request, ensure_ascii=True, allow_nan=False, separators=(",", ":"))
        started = time.monotonic()
        try:
            raw = self.command(text)
        except (OSError, RconError) as error:
            if self.trace:
                self.trace({"operation": operation, "elapsed_ms": (time.monotonic() - started) * 1000,
                            "error": type(error).__name__})
            raise RconError(f"RCON {operation} failed after {time.monotonic() - started:.3f}s: {type(error).__name__}") from error
        try:
            answer = json.loads(raw.strip(), object_pairs_hook=reject_pairs, parse_constant=reject_constant)
        except ValueError as error:
            raise RconError(f"service did not return JSON: {raw[:180]!r}") from error
        if not isinstance(answer, dict) or not isinstance(answer.get("ok"), bool):
            raise RconError("service response missing boolean ok")
        if operation == "capabilities" and answer.get("ok") and answer.get("session_id"):
            self.session_id = answer["session_id"]
        if self.trace:
            self.trace({"operation": operation, "elapsed_ms": (time.monotonic() - started) * 1000,
                        "request_bytes": len(text.encode("utf-8")), "response_bytes": len(raw.encode("utf-8")),
                        "ok": answer.get("ok"), "status": answer.get("status"), "reason": answer.get("reason")})
        return answer
