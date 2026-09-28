import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compare_server


def export(source, probability=0.75, model_revision="model-r1"):
    return {
        "schema_version": 1,
        "source": source,
        "model": {"id": "decision-model", "revision": model_revision},
        "scorer_revision": "scorer-r1",
        "template_sha256": "1" * 64,
        "requests": [
            {
                "id": "ticket/0",
                "request_sha256": "2" * 64,
                "token_ids_sha256": "3" * 64,
                "option_names": ["no", "yes"],
                "answer": "yes",
                "probabilities": {"no": 1 - probability, "yes": probability},
            }
        ],
    }


class ServerComparisonTests(unittest.TestCase):
    def test_reports_each_probability_and_attributes_matching_versions_to_runtime(self):
        report = compare_server.compare_exports(export("local"), export("server", 0.7))
        self.assertEqual(report["attribution"], "runtime_difference")
        differences = report["questions"][0]["probability_differences"]
        self.assertAlmostEqual(differences["no"], 0.05)
        self.assertAlmostEqual(differences["yes"], -0.05)
        self.assertAlmostEqual(report["questions"][0]["max_abs_difference"], 0.05)

    def test_attributes_changed_model_revision_separately(self):
        report = compare_server.compare_exports(
            export("local"), export("server", model_revision="model-r2")
        )
        self.assertEqual(
            report["attribution"], "server_model_or_configuration_difference"
        )
        self.assertEqual(report["metadata_differences"], ["model.revision"])

    def test_rejects_request_hash_mismatch(self):
        server = export("server")
        server["requests"][0]["token_ids_sha256"] = "4" * 64
        with self.assertRaisesRegex(ValueError, "token IDs"):
            compare_server.compare_exports(export("local"), server)

    def test_cli_writes_reproducible_report_without_private_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            local, server, output = root / "local.json", root / "server.json", root / "report.json"
            local.write_text(json.dumps(export("local")))
            server.write_text(json.dumps(export("server", 0.7495)))
            completed = subprocess.run(
                [sys.executable, compare_server.__file__, str(local), str(server), "--output", str(output)],
                text=True,
                capture_output=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            report = json.loads(output.read_text())
            self.assertNotIn("private", json.dumps(report))
            self.assertEqual(report["questions"][0]["id"], "ticket/0")


if __name__ == "__main__":
    unittest.main()
