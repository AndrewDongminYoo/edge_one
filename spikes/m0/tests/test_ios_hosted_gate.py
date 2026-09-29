import copy
import hashlib
import json
import subprocess
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
        cls.archived_raw = archive["direct_native_repro"]["raw_text"]
        lines = cls.archived_raw.splitlines()
        cls.raw = "\n".join(lines[:4] + ["metal_offload MTL 1024"] + lines[4:]) + "\n"

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

    def test_prefers_booted_ios_27_iphone(self):
        listing = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                    {"name": "iPhone 17", "udid": "cold", "state": "Shutdown"},
                    {"name": "iPhone 17 Pro", "udid": "warm", "state": "Booted"},
                ]
            }
        }
        self.assertEqual(select_device(listing)["udid"], "warm")

    def test_archived_metal_failure_and_cpu_success(self):
        result = summarize(self.raw, self.fixture)
        self.assertTrue(result["comparisons"]["cpu_reference"]["passes_gate"])
        self.assertFalse(result["comparisons"]["metal_reference"]["passes_gate"])
        self.assertFalse(result["passes_gate"])

    def test_matching_metal_rows_pass(self):
        lines = self.raw.splitlines()
        matching = "\n".join(
            lines[:5] + [line.replace("cpu ", "metal ", 1) for line in lines[1:4]]
        )
        result = summarize(matching, self.fixture)
        self.assertTrue(result["passes_gate"])
        self.assertEqual(result["metal_weight_bytes"], 1024)

    def test_rejects_missing_or_cpu_only_metal_offload(self):
        for raw in (
            self.archived_raw,
            self.raw.replace("metal_offload MTL 1024", "metal_offload CPU 0"),
        ):
            with self.subTest(raw=raw[-50:]):
                with self.assertRaisesRegex(ValueError, "Metal offload"):
                    summarize(raw, self.fixture)

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

            def fake_command(*args):
                if args == ("xcodebuild", "-version"):
                    return "Xcode 27.0\nBuild version test"
                if args == ("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"):
                    return "27.0"
                if args == ("xcrun", "-f", "metal"):
                    return "/tmp/metal"
                if args == ("xcodebuild", "-downloadComponent", "MetalToolchain"):
                    raise RuntimeError("Metal Toolchain download unavailable")
                self.fail(f"unexpected command: {args}")

            with (
                mock.patch.object(hosted_gate, "EVIDENCE", evidence),
                mock.patch.object(hosted_gate, "command", side_effect=fake_command),
                mock.patch.object(
                    hosted_gate,
                    "check_metal_compiler",
                    side_effect=RuntimeError("Metal Toolchain missing"),
                ),
            ):
                self.assertFalse(hosted_gate.preflight())
            result = json.loads((evidence / "preflight.json").read_text())
            self.assertFalse(result["supported"])
            self.assertTrue(result["metal_toolchain_download_attempted"])
            self.assertIn("download unavailable", result["error"])

    def test_preflight_installs_missing_metal_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            listing = {
                "devices": {
                    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                        {"name": "iPhone 18 Pro", "udid": "phone", "state": "Shutdown"}
                    ]
                }
            }
            outputs = iter(
                [
                    "Xcode 27.0\nBuild version test",
                    "27.0",
                    "/tmp/metal",
                    "downloaded",
                    json.dumps(listing),
                ]
            )
            with (
                mock.patch.object(hosted_gate, "EVIDENCE", evidence),
                mock.patch.object(
                    hosted_gate, "command", side_effect=lambda *args: next(outputs)
                ),
                mock.patch.object(
                    hosted_gate,
                    "check_metal_compiler",
                    side_effect=[RuntimeError("Metal Toolchain missing"), None],
                ),
            ):
                self.assertTrue(hosted_gate.preflight())
            result = json.loads((evidence / "preflight.json").read_text())
            self.assertTrue(result["supported"])
            self.assertTrue(result["metal_toolchain_download_attempted"])
            self.assertTrue(result["metal_compile"])

    def test_preflight_recovers_missing_metal_lookup(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            attempts = []
            listing = {
                "devices": {
                    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                        {"name": "iPhone 18 Pro", "udid": "phone", "state": "Shutdown"}
                    ]
                }
            }

            def fake_command(*args):
                attempts.append(args)
                if args == ("xcodebuild", "-version"):
                    return "Xcode 27.0\nBuild version test"
                if args == ("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"):
                    return "27.0"
                if args == ("xcrun", "-f", "metal"):
                    if attempts.count(args) == 1:
                        raise RuntimeError("metal not found")
                    return "/tmp/metal"
                if args == ("xcodebuild", "-downloadComponent", "MetalToolchain"):
                    return "downloaded"
                if args == ("xcrun", "simctl", "list", "devices", "available", "-j"):
                    return json.dumps(listing)
                self.fail(f"unexpected command: {args}")

            with (
                mock.patch.object(hosted_gate, "EVIDENCE", evidence),
                mock.patch.object(hosted_gate, "command", side_effect=fake_command),
                mock.patch.object(hosted_gate, "check_metal_compiler"),
            ):
                self.assertTrue(hosted_gate.preflight())
            self.assertIn(
                ("xcodebuild", "-downloadComponent", "MetalToolchain"), attempts
            )
            self.assertTrue(
                json.loads((evidence / "preflight.json").read_text())["supported"]
            )

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
            calls = []

            def fake_command(*args, **kwargs):
                calls.append((args, kwargs))
                if args[2:3] == ("list",):
                    return json.dumps(
                        {
                            "devices": {
                                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                                    {
                                        "name": "iPhone 17",
                                        "udid": "phone",
                                        "state": "Shutdown",
                                    }
                                ]
                            }
                        }
                    )
                if args[2:3] == ("get_app_container",):
                    return str(container)
                if args[2:3] == ("launch",):
                    (container / "Documents/native-repro-status.txt").write_text(
                        "metal_complete"
                    )
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
            self.assertEqual(summary["stage"], "compare")
            self.assertEqual(summary["native_status"], "metal_complete")
            self.assertEqual(
                (evidence / "native-repro-status.txt").read_text(), "metal_complete"
            )
            self.assertIn(
                (("xcrun", "simctl", "bootstatus", "phone", "-b"), {"timeout": 600}),
                calls,
            )
            self.assertNotIn(
                ("xcrun", "simctl", "boot", "phone"), [args for args, _ in calls]
            )

    def test_run_gate_records_app_failure_without_plaintext(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "hosted"
            evidence.mkdir()
            (evidence / "preflight.json").write_text(
                json.dumps(
                    {"supported": True, "device": {"udid": "phone", "state": "Booted"}}
                )
            )
            app = root / "NativeRepro.app"
            app.mkdir()
            container = root / "container"
            (container / "Documents").mkdir(parents=True)

            def fake_command(*args, **kwargs):
                if args[2:3] == ("list",):
                    return json.dumps(
                        {
                            "devices": {
                                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                                    {
                                        "name": "iPhone 17",
                                        "udid": "phone",
                                        "state": "Booted",
                                    }
                                ]
                            }
                        }
                    )
                if args[2:3] == ("get_app_container",):
                    return str(container)
                if args[2:3] == ("launch",):
                    (container / "Documents/native-repro-status.txt").write_text(
                        "Repro failed: model hash mismatch"
                    )
                return ""

            with (
                mock.patch.object(hosted_gate, "EVIDENCE", evidence),
                mock.patch.object(hosted_gate, "APP", app),
                mock.patch.object(hosted_gate, "command", side_effect=fake_command),
            ):
                self.assertFalse(hosted_gate.run_gate(0))
            summary = json.loads((evidence / "summary.json").read_text())
            self.assertIn("model hash mismatch", summary["error"])
            self.assertEqual(
                (evidence / "native-repro-status.txt").read_text(),
                "Repro failed: model hash mismatch",
            )

    def test_run_gate_records_launch_diagnostics_without_app_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "hosted"
            evidence.mkdir()
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

            def fake_command(*args, **kwargs):
                if args[2:3] == ("list",):
                    return json.dumps(
                        {
                            "devices": {
                                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                                    {
                                        "name": "iPhone 17",
                                        "udid": "phone",
                                        "state": "Booted",
                                    }
                                ]
                            }
                        }
                    )
                if args[2:3] == ("get_app_container",):
                    return str(container)
                if args[2:3] == ("launch",):
                    return f"{hosted_gate.BUNDLE_ID}: 1234"
                return ""

            def fake_run(args, **kwargs):
                if args[0] == "ps":
                    return subprocess.CompletedProcess(args, 1, "", "")
                if args[:4] == ["xcrun", "simctl", "spawn", "phone"]:
                    return subprocess.CompletedProcess(
                        args, 0, "NativeRepro crashed", ""
                    )
                self.fail(f"unexpected subprocess: {args}")

            with (
                mock.patch.object(hosted_gate, "EVIDENCE", evidence),
                mock.patch.object(hosted_gate, "APP", app),
                mock.patch.object(hosted_gate, "command", side_effect=fake_command),
                mock.patch.object(hosted_gate.subprocess, "run", side_effect=fake_run),
            ):
                self.assertFalse(hosted_gate.run_gate(0))
            summary = json.loads((evidence / "summary.json").read_text())
            self.assertEqual(summary["launch_output"], f"{hosted_gate.BUNDLE_ID}: 1234")
            self.assertEqual(summary["launch_process"], "not running")
            self.assertIn("NativeRepro crashed", summary["launch_log"])

    def test_simctl_command_has_bounded_timeout(self):
        with mock.patch.object(
            hosted_gate.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(
                ["xcrun", "simctl", "bootstatus"], 180
            ),
        ) as run:
            with self.assertRaisesRegex(RuntimeError, "timed out after 180s"):
                hosted_gate.command("xcrun", "simctl", "bootstatus")
        self.assertEqual(run.call_args.kwargs["timeout"], 180)

    def test_bootstatus_timeout_preserves_partial_output(self):
        with mock.patch.object(
            hosted_gate.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(
                ["xcrun", "simctl", "bootstatus"], 600, output=b"boot progress"
            ),
        ) as run:
            with self.assertRaisesRegex(RuntimeError, "boot progress"):
                hosted_gate.command(
                    "xcrun", "simctl", "bootstatus", "phone", "-b", timeout=600
                )
        self.assertEqual(run.call_args.kwargs["timeout"], 600)


if __name__ == "__main__":
    unittest.main()
