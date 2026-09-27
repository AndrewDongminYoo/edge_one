import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_report import validate_report

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[1]


class ArchivedReportTests(unittest.TestCase):
    def setUp(self):
        self.report = json.loads(
            (ROOT / "docs/notes/2026-09-27-m0-desktop.json").read_text()
        )
        self.spec = json.loads((HERE / "fixtures.json").read_text())
        self.pins = json.loads((HERE / "pins.json").read_text())

    def test_accepts_current_archive_and_recalculates_summary(self):
        self.assertEqual(
            validate_report(self.report, self.spec, self.pins), self.report["summary"]
        )

    def test_rejects_fixture_drift(self):
        spec = copy.deepcopy(self.spec)
        spec["cases"][0]["id"] = "changed"
        with self.assertRaisesRegex(ValueError, "fixture spec"):
            validate_report(self.report, spec, self.pins)

    def test_rejects_wrong_canonical_hash(self):
        self.report["metadata"]["fixture_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "fixture hash"):
            validate_report(self.report, self.spec, self.pins)

    def test_rejects_pin_drift(self):
        self.pins["model"] = "different.gguf"
        with self.assertRaisesRegex(ValueError, "pins"):
            validate_report(self.report, self.spec, self.pins)

    def test_rejects_missing_measurement(self):
        self.report["records"].pop()
        with self.assertRaisesRegex(ValueError, "record set"):
            validate_report(self.report, self.spec, self.pins)

    def test_rejects_forged_summary(self):
        self.report["summary"]["gates"]["exact"]["max_abs_difference"] = 0.5
        with self.assertRaisesRegex(ValueError, "summary"):
            validate_report(self.report, self.spec, self.pins)


if __name__ == "__main__":
    unittest.main()
