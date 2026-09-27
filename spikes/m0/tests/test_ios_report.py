import copy
import hashlib
import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ios.report import summarize_report

TIMING_SCOPE = (
    "pretokenized native scoring including internal memory resets and verdict softmax"
)


class IOSReportTests(unittest.TestCase):
    def setUp(self):
        self.pins = {"revision": "pinned"}
        self.fixture = {
            "pins": self.pins,
            "model_sha256": "a" * 64,
            "option_names": ["a", "b"],
            "temperature": 1.0,
            "native_request": {"prefix": [1], "questions": [{}]},
            "reference": {"answer": "a", "probabilities": {"a": 0.75, "b": 0.25}},
        }
        digest = hashlib.sha256(
            json.dumps(self.fixture, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        self.report = {
            "schema_version": 1,
            "metadata": {
                "pins": self.pins,
                "model_sha256": "a" * 64,
                "fixture_sha256": digest,
                "repetitions": 2,
                "timing_scope": TIMING_SCOPE,
                "model_hash_verified": True,
                "threads": 4,
                "flash_attn": "auto",
                "n_gpu_layers": 999,
                "offload_kqv": True,
                "op_offload": True,
                "metal_fusion_disable_requested": False,
                "metal_shared_buffers_disable_requested": False,
                "build": {
                    "sdk": "iphoneos",
                    "configuration": "Release",
                    "architecture": "arm64",
                    "pins": self.pins,
                    "fixture_sha256": digest,
                    "native_archives": {"libllama.a": "c" * 64},
                    "sources": {"Benchmark.cpp": "d" * 64},
                    "xcode": "test",
                    "xcodegen": "test",
                },
                "device": {
                    "platform": "iOS",
                    "simulator": False,
                    "hardware": "iPhone17,1",
                    "os": "test",
                },
            },
            "ready": {
                "n_ctx": 2048,
                "n_batch": 2048,
                "n_ubatch": 1024,
                "n_seq_max": 2,
                "n_outputs_max": 16,
            },
            "records": [
                {
                    "sample": i,
                    "phase": "first" if i == 0 else "warm",
                    "duration_ms": float(30 + i * 10),
                    "memory_reset": True,
                    "native_response": {
                        "mode": "fused",
                        "n_prefix": 1,
                        "prefix_reused": False,
                        "results": [
                            {
                                "scores": [[1.0986122886681098, 0.0], [0.0, 0.0]],
                                "finite": True,
                            }
                        ],
                    },
                    "result": {"answer": "a", "probabilities": {"a": 0.75, "b": 0.25}},
                }
                for i in range(3)
            ],
        }

    def test_recomputes_median_and_parity(self):
        summary = summarize_report(self.report, self.fixture, self.pins)
        self.assertEqual(summary["warm_p50_ms"], 45.0)
        self.assertTrue(summary["passes_gate"])
        self.assertTrue(summary["declared_physical_ios"])
        self.assertNotIn("physical_ios_measurement", summary)

    def test_rejects_changed_or_missing_fixed_execution_profile(self):
        for section, key, altered in (
            ("ready", "n_batch", 1024),
            ("metadata", "threads", 1),
            ("metadata", "flash_attn", "disabled"),
        ):
            for variant in ("changed", "missing", "null"):
                with self.subTest(key=key, variant=variant):
                    report = copy.deepcopy(self.report)
                    if variant == "missing":
                        report[section].pop(key)
                    else:
                        report[section][key] = altered if variant == "changed" else None
                    with self.assertRaisesRegex(ValueError, "settings"):
                        summarize_report(report, self.fixture, self.pins)

    def test_simulator_cannot_satisfy_physical_measurement(self):
        self.report["metadata"]["device"]["simulator"] = True
        self.assertFalse(
            summarize_report(self.report, self.fixture, self.pins)[
                "declared_physical_ios"
            ]
        )

    def test_rejects_missing_warm_record(self):
        self.report["records"].pop()
        with self.assertRaisesRegex(ValueError, "record set"):
            summarize_report(self.report, self.fixture, self.pins)

    def test_rejects_nonfinite_native_score(self):
        self.report["records"][1]["native_response"]["results"][0]["scores"][0][0] = (
            float("nan")
        )
        with self.assertRaisesRegex(ValueError, "native score"):
            summarize_report(self.report, self.fixture, self.pins)

    def test_rejects_probabilities_inconsistent_with_native_logits(self):
        self.report["records"][1]["result"]["probabilities"] = {"a": 0.8, "b": 0.2}
        with self.assertRaisesRegex(ValueError, "native logits"):
            summarize_report(self.report, self.fixture, self.pins)

    def test_rejects_stale_model_identity(self):
        self.report["metadata"]["model_sha256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "model"):
            summarize_report(self.report, self.fixture, self.pins)

    def test_rejects_fixture_drift(self):
        fixture = copy.deepcopy(self.fixture)
        fixture["temperature"] = 2.0
        with self.assertRaisesRegex(ValueError, "fixture"):
            summarize_report(self.report, fixture, self.pins)

    def test_rejects_missing_memory_reset(self):
        self.report["records"][1]["memory_reset"] = False
        with self.assertRaisesRegex(ValueError, "reset"):
            summarize_report(self.report, self.fixture, self.pins)

    def test_invalid_native_mode_is_rejected(self):
        self.report["records"][1]["native_response"]["mode"] = "batched"
        with self.assertRaisesRegex(ValueError, "native mode"):
            summarize_report(self.report, self.fixture, self.pins)

    def test_json_key_order_does_not_change_option_identity(self):
        self.report["records"][1]["result"]["probabilities"] = {"b": 0.25, "a": 0.75}
        self.assertTrue(
            summarize_report(self.report, self.fixture, self.pins)["passes_gate"]
        )

    def test_consistent_report_with_failed_parity_does_not_pass_gate(self):
        p = 0.748
        record = self.report["records"][1]
        record["native_response"]["results"][0]["scores"] = [
            [math.log(p / (1 - p)), 0.0],
            [0.0, 0.0],
        ]
        record["result"]["probabilities"] = {"a": p, "b": 1 - p}
        self.assertFalse(
            summarize_report(self.report, self.fixture, self.pins)["passes_gate"]
        )

    def test_simulator_build_cannot_claim_physical_device_evidence(self):
        self.report["metadata"]["build"]["sdk"] = "iphonesimulator"
        self.assertFalse(
            summarize_report(self.report, self.fixture, self.pins)[
                "declared_physical_ios"
            ]
        )

    def test_incomplete_device_receipt_is_rejected(self):
        self.report["metadata"]["build"] = {"sdk": "iphoneos"}
        with self.assertRaisesRegex(ValueError, "build receipt"):
            summarize_report(self.report, self.fixture, self.pins)

    def test_receipt_pin_drift_is_rejected(self):
        self.report["metadata"]["build"]["pins"] = {"revision": "wrong"}
        with self.assertRaisesRegex(ValueError, "build receipt"):
            summarize_report(self.report, self.fixture, self.pins)

    def test_receipt_tool_versions_must_be_nonempty_strings(self):
        for key in ("xcode", "xcodegen"):
            for value in (["not-a-string"], {"not": "a-string"}, 1, "   "):
                with self.subTest(key=key, value=value):
                    report = copy.deepcopy(self.report)
                    report["metadata"]["build"][key] = value
                    with self.assertRaisesRegex(ValueError, "build receipt"):
                        summarize_report(report, self.fixture, self.pins)

    def test_unknown_timing_boundary_is_rejected(self):
        self.report["metadata"]["timing_scope"] = "unbounded"
        with self.assertRaisesRegex(ValueError, "timing scope"):
            summarize_report(self.report, self.fixture, self.pins)

    def test_cli_runs_directly_and_rejects_simulator_device_metadata(self):
        root = Path(__file__).resolve().parents[1]
        pins = json.loads((root / "pins.json").read_text())
        self.fixture["pins"] = pins
        digest = hashlib.sha256(
            json.dumps(self.fixture, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        metadata = self.report["metadata"]
        metadata["pins"] = pins
        metadata["fixture_sha256"] = digest
        metadata["build"].update(
            pins=pins, fixture_sha256=digest, sdk="iphonesimulator"
        )
        metadata["device"]["simulator"] = True
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture.json"
            report = Path(directory) / "report.json"
            fixture.write_text(json.dumps(self.fixture))
            report.write_text(json.dumps(self.report))
            command = [
                sys.executable,
                str(root / "ios/report.py"),
                str(report),
                "--fixture",
                str(fixture),
            ]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(json.loads(result.stdout)["declared_physical_ios"])
            rejected = subprocess.run(
                command + ["--require-device-metadata"], capture_output=True, text=True
            )
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("physical iOS metadata required", rejected.stderr)

    def test_physical_cli_rejects_cpu_and_nondefault_metal_settings(self):
        root = Path(__file__).resolve().parents[1]
        pins = json.loads((root / "pins.json").read_text())
        self.fixture["pins"] = pins
        digest = hashlib.sha256(
            json.dumps(self.fixture, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        metadata = self.report["metadata"]
        metadata.update(pins=pins, fixture_sha256=digest)
        metadata["build"].update(pins=pins, fixture_sha256=digest)
        metadata["repetitions"] = 20
        first = self.report["records"][0]
        self.report["records"] = [
            {
                **copy.deepcopy(first),
                "sample": i,
                "phase": "first" if i == 0 else "warm",
            }
            for i in range(21)
        ]
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture.json"
            report = Path(directory) / "report.json"
            fixture.write_text(json.dumps(self.fixture))
            command = [
                sys.executable,
                str(root / "ios/report.py"),
                str(report),
                "--fixture",
                str(fixture),
            ]
            report.write_text(json.dumps(self.report))
            accepted = subprocess.run(
                command + ["--require-device-metadata"], capture_output=True, text=True
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            for section, key, altered in (
                ("ready", "n_batch", 1024),
                ("metadata", "threads", 1),
                ("metadata", "flash_attn", "disabled"),
            ):
                for variant in ("changed", "missing", "null"):
                    with self.subTest(key=key, variant=variant):
                        modified = copy.deepcopy(self.report)
                        if variant == "missing":
                            modified[section].pop(key)
                        else:
                            modified[section][key] = (
                                altered if variant == "changed" else None
                            )
                        report.write_text(json.dumps(modified))
                        rejected = subprocess.run(
                            command + ["--require-device-metadata"],
                            capture_output=True,
                            text=True,
                        )
                        self.assertEqual(rejected.returncode, 1)
                        self.assertIn("settings", rejected.stderr)
            for changes in (
                {"n_gpu_layers": 0, "offload_kqv": False, "op_offload": False},
                {"n_gpu_layers": 1},
                {"n_gpu_layers": True},
                {"n_gpu_layers": 999.0},
                {"offload_kqv": False},
                {"offload_kqv": 1},
                {"op_offload": False},
                {"op_offload": 1},
                {"metal_fusion_disable_requested": True},
                {"metal_shared_buffers_disable_requested": True},
                {"metal_fusion_disable_requested": None},
                {"metal_shared_buffers_disable_requested": None},
            ):
                with self.subTest(changes=changes):
                    modified = copy.deepcopy(self.report)
                    modified["metadata"].update(changes)
                    report.write_text(json.dumps(modified))
                    diagnostic = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(diagnostic.returncode, 0, diagnostic.stderr)
                    rejected = subprocess.run(
                        command + ["--require-device-metadata"],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(rejected.returncode, 1)
                    self.assertIn(
                        "default Metal/offload metadata required", rejected.stderr
                    )
            for missing in (
                "n_gpu_layers",
                "offload_kqv",
                "op_offload",
                "metal_fusion_disable_requested",
                "metal_shared_buffers_disable_requested",
            ):
                with self.subTest(missing=missing):
                    modified = copy.deepcopy(self.report)
                    modified["metadata"].pop(missing)
                    report.write_text(json.dumps(modified))
                    rejected = subprocess.run(
                        command + ["--require-device-metadata"],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(rejected.returncode, 1)
                    self.assertIn(
                        "default Metal/offload metadata required", rejected.stderr
                    )

    def test_physical_cli_requires_exactly_20_warm_samples(self):
        root = Path(__file__).resolve().parents[1]
        pins = json.loads((root / "pins.json").read_text())
        self.fixture["pins"] = pins
        digest = hashlib.sha256(
            json.dumps(self.fixture, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        metadata = self.report["metadata"]
        metadata.update(pins=pins, fixture_sha256=digest)
        metadata["build"].update(pins=pins, fixture_sha256=digest)
        first = self.report["records"][0]
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture.json"
            report = Path(directory) / "report.json"
            fixture.write_text(json.dumps(self.fixture))
            for repetitions in (1, 2, 19, 20, 21):
                with self.subTest(repetitions=repetitions):
                    metadata["repetitions"] = repetitions
                    self.report["records"] = [
                        {
                            **copy.deepcopy(first),
                            "sample": i,
                            "phase": "first" if i == 0 else "warm",
                        }
                        for i in range(repetitions + 1)
                    ]
                    report.write_text(json.dumps(self.report))
                    command = [
                        sys.executable,
                        str(root / "ios/report.py"),
                        str(report),
                        "--fixture",
                        str(fixture),
                    ]
                    diagnostic = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(diagnostic.returncode, 0, diagnostic.stderr)
                    checked = subprocess.run(
                        command + ["--require-device-metadata"],
                        capture_output=True,
                        text=True,
                    )
                    if repetitions == 20:
                        self.assertEqual(checked.returncode, 0, checked.stderr)
                    else:
                        self.assertEqual(checked.returncode, 1)
                        self.assertIn("20 warm samples required", checked.stderr)


class ArchivedIOSEvidenceTests(unittest.TestCase):
    def test_archived_reports_preserve_measured_passes_and_failures(self):
        root = Path(__file__).resolve().parents[3]
        pins = json.loads((root / "spikes/m0/pins.json").read_text())
        for filename in (
            "2026-09-27-m0-ios-validation.json",
            "2026-09-28-m0-metal-diagnostic.json",
        ):
            archive = json.loads((root / "docs/notes" / filename).read_text())
            for name, entry in archive["reports"].items():
                with self.subTest(report=name):
                    summary = summarize_report(entry["raw"], archive["fixture"], pins)
                    self.assertEqual(summary, entry["summary"])
                    self.assertEqual(
                        summary["passes_gate"], name == "host" or "cpu" in name
                    )
                    self.assertFalse(summary["declared_physical_ios"])
                    if name != "host":
                        self.assertEqual(summary["warm_samples"], 20)

    def test_direct_plaintext_logits_match_archive_and_probability_errors(self):
        root = Path(__file__).resolve().parents[3]
        archive = json.loads(
            (root / "docs/notes/2026-09-28-m0-metal-diagnostic.json").read_text()
        )
        fixture, direct = archive["fixture"], archive["direct_native_repro"]
        digest = hashlib.sha256(
            json.dumps(fixture, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        lines = direct["raw_text"].splitlines()
        self.assertEqual(lines[0], f"fixture_sha256 {digest}")
        rows = {"cpu": [], "metal": []}
        for line in lines[1:]:
            backend, index, yes, no = line.split()
            self.assertEqual(int(index), len(rows[backend]))
            rows[backend].append([float(yes), float(no)])
        self.assertEqual(rows, direct["rows"])
        names = fixture["option_names"]
        for backend, values in rows.items():
            with self.subTest(backend=backend):
                self.assertEqual(len(values), len(names))
                logits = [(yes - no) / fixture["temperature"] for yes, no in values]
                weights = [math.exp(value - max(logits)) for value in logits]
                error = max(
                    abs(
                        weight / sum(weights)
                        - fixture["reference"]["probabilities"][name]
                    )
                    for name, weight in zip(names, weights, strict=True)
                )
                self.assertAlmostEqual(error, direct[f"{backend}_max_abs_difference"])
                self.assertEqual(error < 1e-3, backend == "cpu")


if __name__ == "__main__":
    unittest.main()
