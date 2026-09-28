import copy
import gzip
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
                "kv_unified": True,
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

    def add_sustained_samples(self):
        metadata = self.report["metadata"]
        metadata["sustained_target_ms"] = 120000
        metadata["sustained_elapsed_ms"] = 120000.0
        metadata["device"].update(thermal_state_at_start=0, thermal_state_at_end=1)
        for record in self.report["records"]:
            record["thermal_state"] = 0
        first = self.report["records"][0]
        self.report["sustained_records"] = [
            {
                **copy.deepcopy(first),
                "sample": i,
                "phase": "sustained",
                "elapsed_ms": float((i + 1) * 3000),
                "thermal_state": 0 if i < 20 else 1,
            }
            for i in range(40)
        ]

    def test_sustained_report_records_thermal_change_and_tail(self):
        self.add_sustained_samples()
        summary = summarize_report(self.report, self.fixture, self.pins)
        self.assertEqual(summary["sustained_samples"], 40)
        self.assertEqual(summary["sustained_tail_samples"], 11)
        self.assertEqual(summary["thermal_state_at_start"], 0)
        self.assertEqual(summary["thermal_state_at_end"], 1)
        self.assertEqual(summary["thermal_state_max"], 1)

    def test_sustained_report_rejects_missing_or_inconsistent_telemetry(self):
        self.add_sustained_samples()
        for section, key in (
            ("device", "thermal_state_at_end"),
            ("metadata", "sustained_elapsed_ms"),
            ("baseline", "thermal_state"),
            ("sustained", "thermal_state"),
            ("sustained", "elapsed_ms"),
        ):
            with self.subTest(section=section, key=key):
                report = copy.deepcopy(self.report)
                target = (
                    report["metadata"]["device"]
                    if section == "device"
                    else (
                        report["metadata"]
                        if section == "metadata"
                        else (
                            report["records"][0]
                            if section == "baseline"
                            else report["sustained_records"][0]
                        )
                    )
                )
                target.pop(key)
                with self.assertRaisesRegex(ValueError, "sustained|thermal"):
                    summarize_report(report, self.fixture, self.pins)
        self.report["sustained_records"][1]["elapsed_ms"] = 1.0
        with self.assertRaisesRegex(ValueError, "sustained"):
            summarize_report(self.report, self.fixture, self.pins)

    def test_sustained_report_rejects_duration_longer_than_elapsed_interval(self):
        self.add_sustained_samples()
        for index in (0, 20):
            with self.subTest(index=index):
                report = copy.deepcopy(self.report)
                report["sustained_records"][index]["duration_ms"] = 3000.001
                with self.assertRaisesRegex(ValueError, "sustained elapsed time"):
                    summarize_report(report, self.fixture, self.pins)
        self.report["sustained_records"][20]["duration_ms"] = 3000.0
        self.assertTrue(
            summarize_report(self.report, self.fixture, self.pins)["passes_gate"]
        )

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

    def test_rejects_changed_unified_kv_setting(self):
        for altered in (False, 0, None):
            with self.subTest(altered=altered):
                report = copy.deepcopy(self.report)
                report["metadata"]["kv_unified"] = altered
                with self.assertRaisesRegex(ValueError, "execution settings"):
                    summarize_report(report, self.fixture, self.pins)

    def test_legacy_report_without_unified_kv_remains_diagnostic(self):
        self.report["metadata"].pop("kv_unified")
        self.assertTrue(
            summarize_report(self.report, self.fixture, self.pins)["passes_gate"]
        )

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
        self.add_sustained_samples()
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
            for altered in (False, 0, None, "missing"):
                with self.subTest(kv_unified=altered):
                    modified = copy.deepcopy(self.report)
                    if altered == "missing":
                        modified["metadata"].pop("kv_unified")
                    else:
                        modified["metadata"]["kv_unified"] = altered
                    report.write_text(json.dumps(modified))
                    rejected = subprocess.run(
                        command + ["--require-device-metadata"],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(rejected.returncode, 1)
                    self.assertIn(
                        (
                            "unified KV metadata required"
                            if altered == "missing"
                            else "unexpected execution settings"
                        ),
                        rejected.stderr,
                    )
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
                    self.add_sustained_samples()
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

    def test_physical_cli_requires_sustained_segment_and_thermal_conditions(self):
        root = Path(__file__).resolve().parents[1]
        pins = json.loads((root / "pins.json").read_text())
        self.fixture["pins"] = pins
        digest = hashlib.sha256(
            json.dumps(self.fixture, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        metadata = self.report["metadata"]
        metadata.update(pins=pins, fixture_sha256=digest, repetitions=20)
        metadata["build"].update(pins=pins, fixture_sha256=digest)
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
                "--require-device-metadata",
            ]
            report.write_text(json.dumps(self.report))
            missing = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(missing.returncode, 1)
            self.assertIn("sustained", missing.stderr)
            self.add_sustained_samples()
            report.write_text(json.dumps(self.report))
            accepted = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            for change in ("short_target", "short_tail", "missing_end"):
                with self.subTest(change=change):
                    altered = copy.deepcopy(self.report)
                    if change == "short_target":
                        altered["metadata"]["sustained_target_ms"] = 1000
                    elif change == "short_tail":
                        altered["sustained_records"] = altered["sustained_records"][:20]
                        altered["sustained_records"][-1]["elapsed_ms"] = 120000.0
                    else:
                        altered["metadata"]["device"].pop("thermal_state_at_end")
                    report.write_text(json.dumps(altered))
                    rejected = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(rejected.returncode, 1)
                    self.assertRegex(rejected.stderr, "sustained|thermal")


class ArchivedIOSEvidenceTests(unittest.TestCase):
    def test_physical_device_exports_preserve_measured_gate_and_thermal_states(self):
        root = Path(__file__).resolve().parents[3]
        archive = json.loads(
            (root / "docs/notes/2026-09-27-m0-ios-validation.json").read_text()
        )
        pins = json.loads((root / "spikes/m0/pins.json").read_text())
        reports = (
            (
                "2026-09-28-m0-ios-device-report.json.gz",
                "1c4349a63b2c0c4e7cdfd9ca8cd34f2e3a8b9fad07a6b97dd1aa1f3271dc09e1",
                693,
                151,
                128.88383349999998,
                197.631875,
            ),
            (
                "2026-09-28-m0-ios-device-report-repeat.json.gz",
                "d8727cdc85920b5a34b7d1c0583f89ec3cb082a7b1f477998aa4bc6c6146b8c1",
                710,
                153,
                129.391792,
                195.624084,
            ),
        )
        with tempfile.TemporaryDirectory() as directory:
            fixture_path = Path(directory) / "fixture.json"
            fixture_path.write_text(json.dumps(archive["fixture"]))
            decompressed_report_path = Path(directory) / "report.json"
            for filename, digest, samples, tail_samples, warm_p50, tail_p50 in reports:
                with self.subTest(report=filename):
                    report_path = root / "docs/notes" / filename
                    raw_bytes = gzip.decompress(report_path.read_bytes())
                    self.assertEqual(hashlib.sha256(raw_bytes).hexdigest(), digest)
                    report = json.loads(raw_bytes)
                    summary = summarize_report(report, archive["fixture"], pins)
                    self.assertTrue(summary["passes_gate"])
                    self.assertTrue(summary["declared_physical_ios"])
                    self.assertEqual(summary["max_abs_difference"], 0.0)
                    self.assertEqual(summary["warm_samples"], 20)
                    self.assertEqual(summary["warm_p50_ms"], warm_p50)
                    self.assertEqual(summary["sustained_samples"], samples)
                    self.assertEqual(summary["sustained_tail_samples"], tail_samples)
                    self.assertEqual(summary["sustained_tail_p50_ms"], tail_p50)
                    self.assertEqual(summary["thermal_state_at_start"], 0)
                    self.assertEqual(summary["thermal_state_at_end"], 2)
                    self.assertEqual(summary["thermal_state_max"], 2)
                    decompressed_report_path.write_bytes(raw_bytes)
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(root / "spikes/m0/ios/report.py"),
                            str(decompressed_report_path),
                            "--fixture",
                            str(fixture_path),
                            "--require-device-metadata",
                        ],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout), summary)

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

    def test_new_unified_kv_simulator_reports_preserve_native_output(self):
        root = Path(__file__).resolve().parents[3]
        pins = json.loads((root / "spikes/m0/pins.json").read_text())
        archive = json.loads(
            (root / "docs/notes/2026-09-28-m0-metal-diagnostic.json").read_text()
        )
        entries = archive["unified_kv_validation"]["simulator_cpu_repeated_runs"]
        self.assertEqual(len(entries), 2)
        for entry in entries:
            with self.subTest(finished=entry["raw"]["metadata"]["finished_utc"]):
                self.assertIs(entry["raw"]["metadata"]["kv_unified"], True)
                self.assertEqual(entry["raw"]["metadata"]["n_gpu_layers"], 0)
                self.assertEqual(
                    summarize_report(entry["raw"], archive["fixture"], pins),
                    entry["summary"],
                )
                self.assertTrue(entry["summary"]["passes_gate"])
                self.assertFalse(entry["summary"]["declared_physical_ios"])

    def test_thermal_sustained_probe_preserves_exported_simulator_data(self):
        root = Path(__file__).resolve().parents[3]
        pins = json.loads((root / "spikes/m0/pins.json").read_text())
        archive = json.loads(
            (root / "docs/notes/2026-09-28-m0-metal-diagnostic.json").read_text()
        )
        entries = archive["thermal_sustained_probe"]["reports"]
        self.assertEqual(len(entries), 2)
        for entry in entries:
            with self.subTest(finished=entry["raw"]["metadata"]["finished_utc"]):
                raw = entry["raw"]
                self.assertEqual(raw["metadata"]["sustained_target_ms"], 2000)
                self.assertEqual(len(raw["records"]), 21)
                self.assertTrue(
                    all("thermal_state" in record for record in raw["records"])
                )
                self.assertTrue(
                    all(
                        "thermal_state" in record for record in raw["sustained_records"]
                    )
                )
                self.assertEqual(
                    summarize_report(raw, archive["fixture"], pins), entry["summary"]
                )
                self.assertTrue(entry["summary"]["passes_gate"])
                self.assertFalse(entry["summary"]["declared_physical_ios"])

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
