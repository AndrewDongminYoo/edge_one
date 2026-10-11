"""Model-free regression checks for the production-core parity gate."""

import copy
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "native_parity", ROOT / "tools" / "check_native_parity.py"
)
parity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(parity)


class NativeParityTests(unittest.TestCase):
    def test_fixed_reference_selection_is_explicit(self):
        import inspect

        parameters = inspect.signature(parity.run).parameters
        self.assertIn("reference_profile", parameters)
        self.assertIn("production_build", parameters)
        self.assertEqual(
            parameters["reference_profile"].default, inspect.Parameter.empty
        )

    def test_historical_cross_profile_failure_remains_a_failure(self):
        with self.assertRaisesRegex(ValueError, "strict probability parity failed"):
            parity.require_parity(
                [[0.5168782490965395, 0.4831217509034605]], [[0.5, 0.5]]
            )

    def test_fixture_changes_cannot_silently_narrow_acceptance(self):
        specification = json.loads((ROOT / "spikes/m0/fixtures.json").read_text())
        parity.check_fixture_spec(specification)
        specification["cases"].pop()
        with self.assertRaises(ValueError):
            parity.check_fixture_spec(specification)

    def observation(self):
        render = {
            "prefix": [3] * 1025,
            "questions": [
                {"names": ["a", "b"], "tokens": [7, 1411, 8, 1411], "slots": [1, 3]},
                {
                    "names": ["false", "true"],
                    "tokens": [9, 1411, 6, 1411],
                    "slots": [1, 3],
                },
            ],
        }
        actual = {
            "rendered": copy.deepcopy(render),
            "distributions": [[0.2, 0.8], [0.4, 0.6]],
            "diagnostics": {
                "shared_tokens": 1024,
                "prefix_decoded_tokens": 1024,
                "sequence_copies": 2,
                "decoded_tokens": 1034,
                "decode_calls": 3,
            },
        }
        return actual, render

    def test_valid_sharing_observation(self):
        actual, render = self.observation()
        parity.check_observation(actual, render, "exact")

    def test_token_order_slot_and_sharing_mutations_fail(self):
        actual, render = self.observation()
        mutations = [
            lambda value: value["rendered"]["prefix"].__setitem__(0, 8),
            lambda value: value["rendered"]["questions"][0]["names"].reverse(),
            lambda value: value["rendered"]["questions"][0]["slots"].__setitem__(0, 0),
            lambda value: value["diagnostics"].__setitem__("sequence_copies", 0),
            lambda value: value["diagnostics"].__setitem__("prefix_decoded_tokens", 0),
            lambda value: value["diagnostics"].__setitem__("decoded_tokens", 0),
            lambda value: value["diagnostics"].__setitem__("decode_calls", 0),
        ]
        for mutate in mutations:
            altered = copy.deepcopy(actual)
            mutate(altered)
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                parity.check_observation(altered, render, "exact")

    def test_probability_gate_is_strict_and_rejects_invalid_values(self):
        self.assertLess(parity.require_parity([[0.5009, 0.4991]], [[0.5, 0.5]]), 1e-3)
        for invalid in (
            [[0.501, 0.499]],
            [[float("nan"), 0.5]],
            [[float("inf"), 0.5]],
            [[True, False]],
            [[-0.1, 1.1]],
            [[0.1, 0.1]],
            [[0.5]],
            [],
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                parity.require_parity(invalid, [[0.5, 0.5]])

    def test_profile_drift_fails(self):
        profile = dict(parity.PRODUCTION_PROFILE)
        parity.check_profile(profile)
        for key in (
            "n_ctx",
            "n_batch",
            "n_ubatch",
            "n_seq_max",
            "n_outputs_max",
            "kv_unified",
        ):
            changed = dict(profile)
            changed[key] = 0
            with self.subTest(key=key), self.assertRaises(ValueError):
                parity.check_profile(changed)


if __name__ == "__main__":
    unittest.main()
