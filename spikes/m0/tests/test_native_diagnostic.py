"""Checks for the bounded binary/library diagnostic, without model inference."""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
SPEC = importlib.util.spec_from_file_location(
    "native_diagnostic", ROOT / "tools/diagnose_native_parity.py"
)
diagnostic = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diagnostic)


class NativeDiagnosticTests(unittest.TestCase):
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
