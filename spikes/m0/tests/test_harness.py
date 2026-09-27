import copy
import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import harness


def result(a=0.75, b=0.25):
    return {"answer": "a" if a >= b else "b", "probabilities": {"a": a, "b": b}}


def native_call(mode, prefix=1024):
    shared = 0 if mode == "individual" else prefix
    native_mode = (
        "fused"
        if mode == "individual"
        else "sequential" if mode == "exact" else "batched"
    )
    return {
        "request": {
            "mode": native_mode,
            "share_prefix": mode == "individual" or shared > 0,
            "prefix_tokens": prefix,
            "question_count": 1,
        },
        "response": {
            "mode": native_mode,
            "n_prefix": prefix,
            "prefix_reused": False,
            "results": [{"scores": [[1.0, 0.0], [0.0, 1.0]], "finite": True}],
            "timing": {
                "prefix_ms": 1.0 if shared else 0.0,
                "question_ms": [10.0],
                "total_ms": 10.0,
            },
        },
    }


class ComparisonTests(unittest.TestCase):
    def test_reports_probability_difference_even_when_top_choice_agrees(self):
        comparison = harness.compare(["a", "b"], result(), result(0.7495, 0.2505))
        self.assertAlmostEqual(comparison["max_abs_difference"], 0.0005)
        self.assertTrue(comparison["top_choice_agrees"])
        self.assertTrue(comparison["passes_gate"])

    def test_top_choice_agreement_does_not_hide_failed_probability_gate(self):
        comparison = harness.compare(["a", "b"], result(), result(0.748, 0.252))
        self.assertTrue(comparison["top_choice_agrees"])
        self.assertFalse(comparison["passes_gate"])

    def test_gate_is_strict_at_threshold(self):
        comparison = harness.compare(["a", "b"], result(0.5, 0.5), result(0.501, 0.499))
        self.assertFalse(comparison["passes_gate"])

    def test_rejects_missing_option(self):
        with self.assertRaisesRegex(ValueError, "option order"):
            harness.compare(
                ["a", "b"], result(), {"answer": "a", "probabilities": {"a": 1.0}}
            )

    def test_rejects_changed_option_order(self):
        candidate = {"answer": "a", "probabilities": {"b": 0.25, "a": 0.75}}
        with self.assertRaisesRegex(ValueError, "option order"):
            harness.compare(["a", "b"], result(), candidate)

    def test_rejects_nonfinite_or_invalid_probability(self):
        for value in [float("nan"), float("inf"), -0.1, 1.1, True, "0.75"]:
            with self.subTest(value=value), self.assertRaisesRegex(
                ValueError, "probability"
            ):
                harness.compare(
                    ["a", "b"],
                    result(),
                    {"answer": "a", "probabilities": {"a": value, "b": 0.25}},
                )

    def test_rejects_distribution_that_does_not_sum_to_one(self):
        with self.assertRaisesRegex(ValueError, "sum"):
            harness.compare(["a", "b"], result(), result(0.7, 0.2))

    def test_rejects_answer_inconsistent_with_distribution(self):
        candidate = result()
        candidate["answer"] = "b"
        with self.assertRaisesRegex(ValueError, "answer"):
            harness.compare(["a", "b"], result(), candidate)

    def test_rejects_empty_options(self):
        with self.assertRaisesRegex(ValueError, "empty"):
            harness.compare([], {}, {})

    def test_rejects_missing_question_results(self):
        with self.assertRaisesRegex(ValueError, "question count"):
            harness.compare_many([["a", "b"]], [result()], [])


class IntegrityTests(unittest.TestCase):
    def test_modified_download_fails_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "runtime.py"
            file.write_bytes(b"trusted")
            digest = hashlib.sha256(b"trusted").hexdigest()
            harness.verify_file(file, {"sha256": digest, "bytes": 7})
            file.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                harness.verify_file(file, {"sha256": digest, "bytes": 7})

    def test_missing_download_fails_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(FileNotFoundError):
                harness.verify_file(
                    Path(directory) / "absent", {"sha256": "0" * 64, "bytes": 1}
                )


class FixtureTests(unittest.TestCase):
    def test_empty_fixture_set_is_not_success(self):
        with self.assertRaisesRegex(ValueError, "empty fixture"):
            harness.validate_fixtures([])

    def test_fixture_without_questions_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "questions"):
            harness.validate_fixtures([{"id": "empty", "state": "", "questions": []}])


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.fixtures = [
            {"id": "long", "prefix_tokens": 1024, "option_names": [["a", "b"]]}
        ]
        self.records = [
            {
                "fixture": "long",
                "mode": mode,
                "phase": phase,
                "sample": sample,
                "results": [result()],
                "duration_ms": 10.0,
                "shared_tokens": 0 if mode == "individual" else 1024,
                "native_calls": [native_call(mode)],
            }
            for mode in ["individual", "exact", "batched"]
            for phase, sample in [("first", 0), ("warm", 1)]
        ]

    def test_summary_recomputes_gate_from_every_raw_probability(self):
        records = copy.deepcopy(self.records)
        records[-1]["results"] = [result(0.748, 0.252)]
        summary = harness.summarize(records, self.fixtures, 1, 1024)
        self.assertTrue(summary["gates"]["exact"]["passes_gate"])
        self.assertFalse(summary["gates"]["batched"]["passes_gate"])
        self.assertEqual(summary["gates"]["batched"]["compared_questions"], 2)
        self.assertEqual(summary["timings"][0]["warm_p50_ms"], 10.0)

    def test_missing_warm_record_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "record set"):
            harness.summarize(self.records[:-1], self.fixtures, 1, 1024)

    def test_duplicate_record_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "record set"):
            harness.summarize(self.records + [self.records[0]], self.fixtures, 1, 1024)

    def test_no_long_prefix_sharing_is_not_a_valid_experiment(self):
        records = copy.deepcopy(self.records)
        records[2]["shared_tokens"] = 0
        with self.assertRaisesRegex(ValueError, "shared tokens"):
            harness.summarize(records, self.fixtures, 1, 1024)

    def test_no_warm_samples_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "repetitions"):
            harness.summarize(self.records, self.fixtures, 0, 1024)

    def test_native_mode_fallback_is_rejected(self):
        records = copy.deepcopy(self.records)
        records[-1]["native_calls"][0]["response"]["mode"] = "sequential"
        with self.assertRaisesRegex(ValueError, "native mode"):
            harness.summarize(records, self.fixtures, 1, 1024)

    def test_native_prefix_mismatch_is_rejected(self):
        records = copy.deepcopy(self.records)
        records[-1]["native_calls"][0]["response"]["n_prefix"] = 0
        with self.assertRaisesRegex(ValueError, "native prefix"):
            harness.summarize(records, self.fixtures, 1, 1024)

    def test_native_response_without_prefix_prefill_is_rejected(self):
        records = copy.deepcopy(self.records)
        records[-1]["native_calls"][0]["response"]["timing"]["prefix_ms"] = 0.0
        with self.assertRaisesRegex(ValueError, "prefix prefill"):
            harness.summarize(records, self.fixtures, 1, 1024)

    def test_unexpected_native_prefix_reuse_is_rejected(self):
        records = copy.deepcopy(self.records)
        records[-1]["native_calls"][0]["response"]["prefix_reused"] = True
        with self.assertRaisesRegex(ValueError, "prefix reuse"):
            harness.summarize(records, self.fixtures, 1, 1024)

    def test_missing_native_observation_is_rejected(self):
        records = copy.deepcopy(self.records)
        records[-1]["native_calls"] = []
        with self.assertRaisesRegex(ValueError, "native call count"):
            harness.summarize(records, self.fixtures, 1, 1024)


if __name__ == "__main__":
    unittest.main()
