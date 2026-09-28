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
        "template_sha256": "a" * 64,
        "readout_config_sha256": "b" * 64,
        "requests": [
            {
                "id": "ticket/0",
                "request_sha256": "c" * 64,
                "token_ids_sha256": "d" * 64,
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

    def test_probability_map_serialization_order_does_not_change_option_identity(self):
        server = export("server")
        server["requests"][0]["probabilities"] = {"yes": 0.75, "no": 0.25}

        report = compare_server.compare_exports(export("local"), server)

        self.assertTrue(report["summary"]["passes_gate"])
        self.assertEqual(
            list(report["questions"][0]["server_probabilities"]), ["no", "yes"]
        )

    def test_attributes_changed_model_revision_separately(self):
        report = compare_server.compare_exports(
            export("local"), export("server", model_revision="model-r2")
        )
        self.assertEqual(
            report["attribution"], "server_model_or_configuration_difference"
        )
        self.assertEqual(report["metadata_differences"], ["model.revision"])

    def test_attributes_changed_readout_configuration_separately(self):
        server = export("server")
        server["readout_config_sha256"] = "5" * 64
        report = compare_server.compare_exports(export("local"), server)
        self.assertEqual(
            report["attribution"], "server_model_or_configuration_difference"
        )
        self.assertEqual(report["metadata_differences"], ["readout_config_sha256"])

    def test_canonicalizes_digest_case_before_comparison(self):
        server = export("server")
        server["template_sha256"] = server["template_sha256"].upper()
        server["readout_config_sha256"] = server["readout_config_sha256"].upper()
        server["requests"][0]["request_sha256"] = (
            server["requests"][0]["request_sha256"].upper()
        )
        server["requests"][0]["token_ids_sha256"] = (
            server["requests"][0]["token_ids_sha256"].upper()
        )

        report = compare_server.compare_exports(export("local"), server)

        self.assertEqual(report["attribution"], "runtime_difference")
        self.assertEqual(report["metadata_differences"], [])
        self.assertEqual(report["server_metadata"]["template_sha256"], "a" * 64)
        self.assertEqual(report["questions"][0]["request_sha256"], "c" * 64)

    def test_rejects_request_hash_mismatch(self):
        server = export("server")
        server["requests"][0]["token_ids_sha256"] = "4" * 64
        with self.assertRaisesRegex(ValueError, "token IDs"):
            compare_server.compare_exports(export("local"), server)

    def test_rejects_malformed_sha256_digests_from_either_source(self):
        for source in ("local", "server"):
            for field in (
                "template_sha256",
                "readout_config_sha256",
                "request_sha256",
                "token_ids_sha256",
            ):
                for malformed in ("", "not-a-sha", "g" * 64, "a" * 63, "a" * 65):
                    with self.subTest(
                        source=source, field=field, malformed=malformed
                    ):
                        local = export("local")
                        server = export("server")
                        invalid = local if source == "local" else server
                        if field in ("template_sha256", "readout_config_sha256"):
                            invalid[field] = malformed
                        else:
                            invalid["requests"][0][field] = malformed
                        with self.assertRaisesRegex(ValueError, field):
                            compare_server.compare_exports(local, server)

    def test_rejects_equal_malformed_sha256_digests(self):
        for field in (
            "template_sha256",
            "readout_config_sha256",
            "request_sha256",
            "token_ids_sha256",
        ):
            with self.subTest(field=field):
                local = export("local")
                server = export("server")
                if field in ("template_sha256", "readout_config_sha256"):
                    local[field] = server[field] = "not-a-sha"
                else:
                    local["requests"][0][field] = "not-a-sha"
                    server["requests"][0][field] = "not-a-sha"
                with self.assertRaisesRegex(ValueError, field):
                    compare_server.compare_exports(local, server)

    def test_cli_writes_reproducible_report_without_private_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            local = root / "local.json"
            server = root / "server.json"
            output = root / "report.json"
            local.write_text(json.dumps(export("local")))
            server.write_text(json.dumps(export("server", 0.7495)))
            completed = subprocess.run(
                [
                    sys.executable,
                    compare_server.__file__,
                    str(local),
                    str(server),
                    "--output",
                    str(output),
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            report = json.loads(output.read_text())
            self.assertNotIn("private", json.dumps(report))
            self.assertEqual(report["questions"][0]["id"], "ticket/0")


if __name__ == "__main__":
    unittest.main()
