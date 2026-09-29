import copy
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ios import hosted_gate
from ios.hosted_gate import select_device, summarize


class HostedGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[3]
        archive = json.loads(
            (root / "docs/notes/2026-09-28-m0-metal-diagnostic.json").read_text()
        )
        cls.fixture = archive["fixture"]
        cls.raw = archive["direct_native_repro"]["raw_text"]

    def test_selects_available_ios_27_iphone(self):
        devices = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                    {"name": "iPhone 17 Pro", "udid": "old", "state": "Shutdown"}
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                    {"name": "iPad Pro", "udid": "tablet", "state": "Shutdown"},
                    {"name": "iPhone 18 Pro", "udid": "phone", "state": "Shutdown"},
                ],
            }
        }
        self.assertEqual(select_device(devices)["udid"], "phone")
        devices["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-27-0"][1][
            "isAvailable"
        ] = False
        with self.assertRaisesRegex(ValueError, "available iOS 27 iPhone"):
            select_device(devices)

    def test_archived_metal_failure_and_cpu_success(self):
        result = summarize(self.raw, self.fixture)
        self.assertTrue(result["comparisons"]["cpu_reference"]["passes_gate"])
        self.assertFalse(result["comparisons"]["metal_reference"]["passes_gate"])
        self.assertFalse(result["passes_gate"])

    def test_matching_metal_rows_pass(self):
        lines = self.raw.splitlines()
        matching = "\n".join(
            lines[:4] + [line.replace("cpu ", "metal ", 1) for line in lines[1:4]]
        )
        self.assertTrue(summarize(matching, self.fixture)["passes_gate"])

    def test_rejects_wrong_hash_missing_and_nonfinite_rows(self):
        digest = hashlib.sha256(
            json.dumps(self.fixture, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        cases = (
            self.raw.replace(digest, "0" * 64, 1),
            "\n".join(self.raw.splitlines()[:-1]),
            self.raw.replace("metal 0 0 0", "metal 0 nan 0"),
            self.raw.replace("cpu 1 ", "cpu 0 "),
        )
        for raw in cases:
            with self.subTest(raw=raw[-50:]):
                with self.assertRaises(ValueError):
                    summarize(raw, self.fixture)

    def test_rejects_modified_reference(self):
        fixture = copy.deepcopy(self.fixture)
        fixture["reference"]["probabilities"] = {
            name: 0 for name in fixture["option_names"]
        }
        original_digest = self.raw.splitlines()[0].split()[1]
        changed_digest = hashlib.sha256(
            json.dumps(fixture, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        with self.assertRaises(ValueError):
            summarize(self.raw.replace(original_digest, changed_digest, 1), fixture)

    def test_preflight_records_metal_compiler_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            with (
                mock.patch.object(hosted_gate, "EVIDENCE", evidence),
                mock.patch.object(
                    hosted_gate,
                    "command",
                    side_effect=[
                        "Xcode 27.0\nBuild version test",
                        "27.0",
                        "/tmp/metal",
                    ],
                ),
                mock.patch.object(
                    hosted_gate,
                    "check_metal_compiler",
                    side_effect=RuntimeError("Metal Toolchain missing"),
                ),
            ):
                self.assertFalse(hosted_gate.preflight())
            result = json.loads((evidence / "preflight.json").read_text())
            self.assertFalse(result["supported"])
            self.assertIn("Metal Toolchain missing", result["error"])

    def test_run_gate_preserves_failed_metal_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "hosted"
            evidence.mkdir()
            fixture_path = root / "fixture.json"
            fixture_path.write_text(json.dumps(self.fixture))
            (evidence / "preflight.json").write_text(
                json.dumps(
                    {
                        "supported": True,
                        "device": {"udid": "phone", "state": "Shutdown"},
                    }
                )
            )
            app = root / "NativeRepro.app"
            app.mkdir()
            container = root / "container"
            (container / "Documents").mkdir(parents=True)

            def fake_command(*args):
                if args[2:3] == ("get_app_container",):
                    return str(container)
                if args[2:3] == ("launch",):
                    (container / "Documents/native-repro.txt").write_text(self.raw)
                return ""

            with (
                mock.patch.object(hosted_gate, "EVIDENCE", evidence),
                mock.patch.object(hosted_gate, "IOS_CACHE", root),
                mock.patch.object(hosted_gate, "APP", app),
                mock.patch.object(hosted_gate, "command", side_effect=fake_command),
                mock.patch.object(hosted_gate.subprocess, "run"),
            ):
                self.assertFalse(hosted_gate.run_gate(1))
            self.assertEqual((evidence / "native-repro.txt").read_text(), self.raw)
            summary = json.loads((evidence / "summary.json").read_text())
            self.assertFalse(summary["passes_gate"])
            self.assertIn("strict CPU/Metal", summary["error"])


if __name__ == "__main__":
    unittest.main()
