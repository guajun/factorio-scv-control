"""Host watchdog and save identity regressions; native clock claims use live.py."""
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

from live import wait_saved_map, wait_step
from rcon import RconError


class DebugClockHostTests(unittest.TestCase):
    def test_factorio_split_level_save_is_recognized_and_hashed(self):
        for count in (1, 2, 3):
            with self.subTest(shards=count), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "source.zip"
                with zipfile.ZipFile(path, "w") as archive:
                    for member in [*("level.dat" + str(index) for index in range(count)),
                                   "level.datmetadata", "script.dat"]:
                        archive.writestr("source/" + member, b"fixture")
                process = Mock()
                process.poll.return_value = None
                result = wait_saved_map(path, process, 0.1)
                self.assertEqual(result["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
                self.assertEqual(result["bytes"], path.stat().st_size)

    def test_gapped_shards_missing_first_shard_or_metadata_are_incomplete(self):
        for members in [("level.dat0", "level.dat2", "level.datmetadata", "script.dat"),
                        ("level.dat1", "level.datmetadata", "script.dat"),
                        ("level.dat0", "script.dat")]:
            with self.subTest(members=members), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "source.zip"
                with zipfile.ZipFile(path, "w") as archive:
                    for member in members:
                        archive.writestr("source/" + member, b"fixture")
                process = Mock()
                process.poll.return_value = None
                with patch("live.time.monotonic", side_effect=[0, 0, 2]), patch("live.time.sleep"):
                    with self.assertRaisesRegex(RconError, "save watchdog"):
                        wait_saved_map(path, process, 1)

    def test_partial_save_cannot_be_used_as_fact_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "source.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("source/info.json", "{}")
            process = Mock()
            process.poll.return_value = None
            with patch("live.time.monotonic", side_effect=[0, 0, 2]), patch("live.time.sleep"):
                with self.assertRaisesRegex(RconError, "save watchdog"):
                    wait_saved_map(path, process, 1)

    def test_step_completes_only_when_paused_and_native_budget_exhausted(self):
        client, process = Mock(), Mock()
        process.poll.return_value = None
        client.service.side_effect = [
            {"ok": True, "clock": {"paused": True, "ticks_to_run": 1, "tick": 12}},
            {"ok": True, "clock": {"paused": True, "ticks_to_run": 0, "tick": 13}}]
        with patch("live.time.sleep"):
            self.assertEqual(wait_step(client, process, 1)["tick"], 13)
        self.assertEqual(client.service.call_count, 2)

    def test_step_timeout_is_host_wall_clock_guard(self):
        client, process = Mock(), Mock()
        process.poll.return_value = None
        client.service.return_value = {"ok": True, "clock": {"paused": True, "ticks_to_run": 1, "tick": 0}}
        with patch("live.time.monotonic", side_effect=[0, 0, 2]), patch("live.time.sleep"):
            with self.assertRaisesRegex(RconError, "wall-clock watchdog"):
                wait_step(client, process, 1)


if __name__ == "__main__":
    unittest.main()
