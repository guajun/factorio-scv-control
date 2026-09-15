"""Socket-level failure/fragmentation checks do not launch Factorio."""

import json
import socket
import struct
import threading
import tempfile
from pathlib import Path
import unittest

from live import client_profile, download, result_admitted, upload
from rcon import MAX_PACKET, Rcon, RconError, packet, read_packet


class RconTests(unittest.TestCase):
    def test_rpc_ok_is_not_route_admission(self):
        self.assertFalse(result_admitted({"ok": True, "status": "rejected", "committed": True, "admission_count": 1}))
        self.assertFalse(result_admitted({"ok": True, "status": "moving", "committed": True, "admission_count": 2}))
        self.assertTrue(result_admitted({"ok": True, "status": "moving", "committed": True, "admission_count": 1}))

    def test_manual_client_profile_uses_exact_copied_mods_without_launching(self):
        with tempfile.TemporaryDirectory(prefix="scv-client-profile-") as directory:
            root = Path(directory)
            binary = root / "quote's install/bin/x64/factorio.exe"
            mods = root / "mods"
            metadata = client_profile(root, binary, mods, "127.0.0.1:34198")
            command = Path(metadata["manual_launcher"]).read_text(encoding="utf-8")
            config = Path(metadata["config"]).read_text(encoding="utf-8")
            self.assertIn("quote''s install", command)
            self.assertIn(str(mods), command)
            self.assertIn("--mp-connect", command)
            self.assertIn("client-write-data", config)
            self.assertNotIn("rcon-password", command)

    def test_download_rejects_changed_offset_and_empty_progress(self):
        class Client:
            def __init__(self, answer): self.answer = answer
            def service(self, *_args, **_kwargs): return self.answer
        for answer in [{"ok": True, "request_token": "request", "offset": 1, "bytes": 5, "data": "12345"},
                       {"ok": True, "request_token": "request", "offset": 0, "bytes": 5, "data": ""}]:
            with self.subTest(answer=answer), self.assertRaises(RconError):
                download(Client(answer), "request")

    def test_cancelled_upload_never_reaches_commit(self):
        class Client:
            def __init__(self): self.operations = []
            def service(self, operation, **_fields):
                self.operations.append(operation)
                return {"ok": False, "reason": "request-not-pending"}
        client = Client()
        self.assertFalse(upload(client, "old", {"outcome": "complete"})["ok"])
        self.assertEqual(client.operations, ["upload"])

    def test_authentication_failure_is_bounded(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        address = listener.getsockname()
        def reject():
            with listener:
                connection, _ = listener.accept()
                with connection:
                    read_packet(connection)
                    connection.sendall(packet(-1, 2, ""))
        thread = threading.Thread(target=reject)
        thread.start()
        with self.assertRaisesRegex(RconError, "authentication rejected"):
            Rcon(*address, "wrong", timeout=2)
        thread.join(3)
        self.assertFalse(thread.is_alive())

    def test_fragmented_tcp_reads_and_unicode(self):
        receiver, sender = socket.socketpair()
        receiver.settimeout(2)
        payload = packet(42, 0, "墙 é" * 500)
        def send():
            with sender:
                for offset in range(0, len(payload), 3):
                    sender.sendall(payload[offset:offset + 3])
        thread = threading.Thread(target=send)
        thread.start()
        with receiver:
            self.assertEqual(read_packet(receiver), (42, 0, "墙 é" * 500))
        thread.join(2)

    def test_short_invalid_and_oversized_frames(self):
        for payload in [b"\x01\x00", struct.pack("<i", 9), struct.pack("<i", MAX_PACKET + 1),
                        struct.pack("<iii", 10, 1, 0) + b"XY"]:
            receiver, sender = socket.socketpair()
            with receiver, sender:
                receiver.settimeout(1)
                sender.sendall(payload)
                sender.shutdown(socket.SHUT_WR)
                with self.assertRaises(RconError):
                    read_packet(receiver)

    def test_authentication_service_and_identity(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        failures = []
        def server():
            try:
                with listener:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(2)
                        self.assertEqual(read_packet(connection), (1, 3, "test-secret"))
                        connection.sendall(packet(1, 0, "") + packet(1, 2, ""))
                        request_id, kind, text = read_packet(connection)
                        self.assertEqual(kind, 2)
                        self.assertTrue(text.startswith("/scv-nav-agent "))
                        request = json.loads(text.split(" ", 1)[1])
                        self.assertEqual(request["operation"], "poll-work")
                        connection.sendall(packet(request_id, 0, '{"ok":true,"work":null}\n'))
            except BaseException as error:
                failures.append(error)
        thread = threading.Thread(target=server)
        thread.start()
        with Rcon("127.0.0.1", listener.getsockname()[1], "test-secret", timeout=2) as client:
            self.assertEqual(client.service("poll-work"), {"ok": True, "work": None})
        thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(failures, [])

    def test_nul_command_and_remote_host_rejected(self):
        with self.assertRaises(RconError):
            packet(1, 2, "x\x00y")
        with self.assertRaises(RconError):
            Rcon("8.8.8.8", 27015, "unused")


if __name__ == "__main__":
    unittest.main()
