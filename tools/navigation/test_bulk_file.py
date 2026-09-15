"""Local bulk transport safety/identity tests; never launch a graphical client."""

import copy
import json
from pathlib import Path
import tempfile
import unittest

from bulk_file import MAX_BYTES, WORK_FILE, read_work
from canonical import content_hash
from live import receive_work
from rcon import RconError
from test_solver import example


class BulkFileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="scv-bulk-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.snapshot, self.query = example()
        self.token, self.session = "test-request", self.query["session_id"]
        self.work = {"protocol": "scv-navigation/1", "kind": "live-work", "id": "example",
                     "request_token": self.token, "snapshot": self.snapshot, "query": self.query}
        self.path = self.root / WORK_FILE
        self.path.parent.mkdir(parents=True)
        self.descriptor = {"kind": "script-output-file-v1", "path": WORK_FILE,
                           "session_id": self.session, "request_token": self.token,
                           "query_id": self.query["query_id"], "query_hash": self.query["query_hash"],
                           "snapshot_hash": content_hash(self.snapshot)}
        self.write(self.work)

    def write(self, value):
        raw = json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
        self.path.write_bytes(raw)
        self.descriptor["bytes"] = len(raw)

    def read(self):
        return read_work(self.root, self.descriptor, self.token, self.session)

    def test_exact_problem_and_one_bulk_read(self):
        work, metrics = self.read()
        self.assertEqual(work, self.work)
        self.assertEqual(metrics["bytes"], self.path.stat().st_size)
        self.assertEqual(metrics["bulk_rcon_commands"], 0)

    def test_file_receive_cannot_call_rcon(self):
        class NoBulkRpc:
            session_id = self.session
            def service(self, *_args, **_kwargs):
                raise AssertionError("file receiver must not issue a data RPC")
        # Use the launcher's layout without changing the actual payload.
        script_output = self.root / "write-data/script-output"
        target = script_output / WORK_FILE
        target.parent.mkdir(parents=True)
        target.write_bytes(self.path.read_bytes())
        work, _ = receive_work(NoBulkRpc(), self.token, {"transfer": self.descriptor}, self.root, "file")
        self.assertEqual(work, self.work)

    def test_paths_are_fixed_and_confined(self):
        for path in ["../secret", "C:/secret", "//server/share/data", "scv-control/navigation/other.json"]:
            with self.subTest(path=path), self.assertRaises(RconError):
                self.descriptor["path"] = path
                self.read()

    def test_missing_partial_and_size_limits_rejected(self):
        for size in [0, True, MAX_BYTES + 1, self.descriptor["bytes"] - 1]:
            with self.subTest(size=size), self.assertRaises(RconError):
                changed = {**self.descriptor, "bytes": size}
                read_work(self.root, changed, self.token, self.session)
        self.path.unlink()
        with self.assertRaises(RconError):
            self.read()

    def test_descriptor_or_file_from_another_request_rejected(self):
        for key in ["request_token", "session_id", "query_id", "query_hash", "snapshot_hash"]:
            with self.subTest(key=key), self.assertRaises(RconError):
                read_work(self.root, {**self.descriptor, key: "obsolete"}, self.token, self.session)
        self.write({**self.work, "request_token": "another-request"})
        with self.assertRaises(RconError):
            self.read()

    def test_tampered_query_and_geometry_rejected(self):
        for field in ["snapshot", "query"]:
            changed = copy.deepcopy(self.work)
            if field == "snapshot":
                changed[field]["graph"]["edges"][0]["distance"] += 1
            else:
                changed[field]["goal"]["x"] += 1
            self.write(changed)
            with self.subTest(field=field), self.assertRaises(RconError):
                self.read()

    def test_malformed_duplicate_and_nonfinite_json_rejected(self):
        for raw in [b'{', b'{"protocol":1,"protocol":2}', b'{"x":NaN}']:
            self.path.write_bytes(raw)
            self.descriptor["bytes"] = len(raw)
            with self.subTest(raw=raw), self.assertRaises(RconError):
                self.read()


if __name__ == "__main__":
    unittest.main()
