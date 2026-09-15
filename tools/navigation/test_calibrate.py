"""Host report safety checks; these tests never start any Factorio client."""
import copy
import unittest
from calibrate import measurements, validate_report


def example():
    return {"schema_version": 1, "domain": "gates", "fixture_version": 1, "factorio_version": "2.0.77",
        "case_count": 1, "passed": 1, "failed": 0, "cases": [{"id": "real-gate", "passed": True,
        "terminal_state": "closed-after-crossing", "reason": "real-character-crossed",
        "assertions": [{"name": "crossed", "passed": True}], "metrics": {"crossed_tick": 20},
        "timeline": [{"tick": 20, "event": "crossed"}]}]}


class CalibrationTests(unittest.TestCase):
    def test_valid_report(self):
        validate_report(example(), "gates", 1, 0)

    def test_denominator_and_marker_cannot_drop_failures(self):
        for field in ["passed", "failed", "case_count"]:
            value = example()
            value[field] += 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_report(value, "gates", 1, 0)

    def test_missing_versions_and_duplicate_case_rejected(self):
        for field in ["schema_version", "fixture_version", "factorio_version", "domain"]:
            value = example()
            del value[field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_report(value, "gates", 1, 0)
        value = example()
        value["cases"].append(copy.deepcopy(value["cases"][0]))
        value["passed"], value["case_count"] = 2, 2
        with self.assertRaises(ValueError):
            validate_report(value, "gates", 2, 0)

    def test_assertions_cannot_be_missing_or_truthy_strings(self):
        for assertions in [[], {}, [None], [{"passed": "false"}], [{"passed": False}]]:
            value = example()
            value["cases"][0]["assertions"] = assertions
            with self.subTest(assertions=assertions), self.assertRaises(ValueError):
                validate_report(value, "gates", 1, 0)

    def test_guard_is_never_success(self):
        value = example()
        value["cases"][0]["reason"] = "tick-guard-exceeded"
        with self.assertRaises(ValueError):
            validate_report(value, "gates", 1, 0)

    def test_missing_terminal_diagnostics(self):
        for field in ["terminal_state", "metrics", "timeline"]:
            value = example()
            del value["cases"][0][field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_report(value, "gates", 1, 0)

    def test_repeated_measurements_ignore_only_host_time(self):
        first, second = example(), example()
        first["host_wall_ms"], second["host_wall_ms"] = 1, 2
        self.assertEqual(measurements(first), measurements(second))
        second["cases"][0]["timeline"][0]["tick"] += 1
        self.assertNotEqual(measurements(first), measurements(second))


if __name__ == "__main__":
    unittest.main()
