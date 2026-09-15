import copy
import unittest
from replay_bundle import validated_bundle
from solver import solve
from test_solver import example


class BundleReplayTests(unittest.TestCase):
    def setUp(self):
        snapshot, query = example()
        self.bundle = {"protocol": "scv-navigation/1", "kind": "solver-bundle", "cases": [
            {"id": "example", "snapshot": snapshot, "query": query, "result": solve(snapshot, query)}]}

    def test_valid_import_uses_shared_host_contract(self):
        self.assertIs(validated_bundle(self.bundle), self.bundle)

    def test_empty_duplicate_and_wrong_kind_rejected(self):
        for edit in ["empty", "duplicate", "kind"]:
            bundle = copy.deepcopy(self.bundle)
            if edit == "empty": bundle["cases"] = []
            elif edit == "duplicate": bundle["cases"].append(copy.deepcopy(bundle["cases"][0]))
            else: bundle["kind"] = "capture-bundle"
            with self.subTest(edit=edit), self.assertRaises(ValueError):
                validated_bundle(bundle)

    def test_result_identity_is_not_trusted(self):
        self.bundle["cases"][0]["result"]["query_hash"] = "obsolete"
        with self.assertRaises(ValueError):
            validated_bundle(self.bundle)


if __name__ == "__main__":
    unittest.main()
