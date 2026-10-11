"""Checks for the bounded binary/library diagnostic, without model inference."""

import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
SPEC = importlib.util.spec_from_file_location(
    "native_diagnostic", ROOT / "tools/diagnose_native_parity.py"
)
diagnostic = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diagnostic)


class NativeDiagnosticTests(unittest.TestCase):
    def run_stalled_case(self, child, kind="production", rendered=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "child"
            binary.write_text(f"#!{sys.executable}\n{child}")
            binary.chmod(0o755)
            libraries = [root / "libllama.so.0", root / "libggml-cpu.so.0"]
            for library in libraries:
                library.write_bytes(b"model-free library evidence fixture")
            result = {}
            report = {"cases": {"test": result}}
            record = root / "report.json"
            snapshots = []
            with (
                record.open("x") as output,
                (root / "stderr").open("w") as log,
                patch.object(
                    diagnostic,
                    "loaded_library_paths",
                    return_value=[str(path) for path in libraries],
                ),
            ):

                def save():
                    diagnostic.write_report(output, report)
                    snapshots.append(json.loads(record.read_text())["cases"]["test"])

                started = time.monotonic()
                with self.assertRaisesRegex(TimeoutError, "exceeded"):
                    diagnostic.run_case(
                        binary,
                        root,
                        kind,
                        root / "unused-model",
                        {},
                        rendered,
                        {"temperatures": {"global": 1.0}},
                        log,
                        result=result,
                        save=save,
                        timeout=0.5,
                    )
                self.assertLess(time.monotonic() - started, 5)
            saved = json.loads(record.read_text())["cases"]["test"]
            with self.assertRaises(ChildProcessError):
                os.waitpid(saved["pid"], os.WNOHANG)
            return saved, snapshots

    def test_readiness_timeout_kills_and_reaps_child(self):
        saved, snapshots = self.run_stalled_case("import time\ntime.sleep(60)\n")
        self.assertNotIn("ready", saved)
        self.assertIn("exceeded", saved["error"])
        self.assertTrue(
            any("pid" in item and "error" not in item for item in snapshots)
        )

    def test_later_query_timeout_preserves_ready_libraries_and_first_reply(self):
        saved, snapshots = self.run_stalled_case(
            "import json, sys, time\n"
            "print(json.dumps({'ready': True}), flush=True)\n"
            "sys.stdin.readline()\n"
            "print(json.dumps({'results': [{'scores': [[2, 1], [1, 2]]}]}), flush=True)\n"
            "sys.stdin.readline()\n"
            "time.sleep(60)\n",
            kind="upstream",
            rendered=[SimpleNamespace(ids=[1, 2], prefix_len=1, slots=[1])] * 2,
        )
        self.assertTrue(saved["ready"]["ready"])
        self.assertEqual(len(saved["loaded_libraries"]), 2)
        self.assertTrue(
            all(len(value) == 64 for value in saved["loaded_libraries"].values())
        )
        self.assertEqual(saved["raw"], [{"results": [{"scores": [[2, 1], [1, 2]]}]}])
        self.assertEqual(len(saved["probabilities"]), 1)
        self.assertIn("exceeded", saved["error"])
        self.assertTrue(
            any(
                item.get("raw") == saved["raw"]
                and item.get("loaded_libraries") == saved["loaded_libraries"]
                and "error" not in item
                for item in snapshots
            )
        )

    def test_matrix_changes_only_executable_or_libraries(self):
        self.assertEqual(
            diagnostic.diagnostic_cases(
                "reference", "production", "native", "portable"
            ),
            [
                ("A", "reference", "native", "upstream"),
                ("B", "reference", "portable", "upstream"),
                ("C", "production", "portable", "production"),
                ("D", "production", "native", "production"),
            ],
        )

    def test_loaded_library_evidence_rejects_partial_override(self):
        diagnostic.check_libraries(
            ["/portable/libllama.so.0", "/portable/libggml-cpu.so.0"], Path("/portable")
        )
        with self.assertRaises(ValueError):
            diagnostic.check_libraries(
                ["/portable/libllama.so.0", "/native/libggml-cpu.so.0"],
                Path("/portable"),
            )

    def test_diagnostic_preserves_the_failed_strict_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            gate = Path(directory) / "strict.json.partial"
            original = (
                b'{"error":"strict probability parity failed: 0.016878 >= 1e-3"}\n'
            )
            gate.write_bytes(original)
            report = diagnostic.failed_gate_evidence(gate)
            self.assertEqual(report["error"], json.loads(original)["error"])
            self.assertEqual(gate.read_bytes(), original)
            self.assertFalse(report["strict_gate_passed"])
            gate.write_text('{"summary":{"passes_gate":true}}')
            with self.assertRaises(ValueError):
                diagnostic.failed_gate_evidence(gate)


if __name__ == "__main__":
    unittest.main()
