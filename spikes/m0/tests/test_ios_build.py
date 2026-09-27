import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ios import build


class BuildCapacityTests(unittest.TestCase):
    def test_repro_header_drift_is_rejected_before_native_commands(self):
        fixture = {
            "pins": build.PINS,
            "model_sha256": "a" * 64,
            "native_request": {
                "prefix": [1],
                "questions": [{"ids": [2], "slots": [1], "rows": [3, 4]}],
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            (cache / "ios").mkdir()
            (cache / "ios/fixture.json").write_text(json.dumps(fixture))
            (cache / "ios/fixture_tokens.hpp").write_text(
                build.native_fixture_header(fixture) + "// drift\n"
            )
            with (
                mock.patch("ios.build.CACHE", cache),
                mock.patch("ios.build.require_capacity"),
                mock.patch(
                    "ios.build.verify_model",
                    return_value={"files": {build.PINS["model"]: {"sha256": "a" * 64}}},
                ),
                mock.patch("ios.build.verify_source"),
                mock.patch("ios.build.run") as command,
            ):
                with self.assertRaisesRegex(ValueError, "fixture header mismatch"):
                    build.build("iphonesimulator", 2)
                command.assert_not_called()

    def test_fixture_model_drift_is_rejected_before_native_commands(self):
        fixture = {"pins": build.PINS, "model_sha256": "b" * 64}
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            (cache / "ios").mkdir()
            (cache / "ios/fixture.json").write_text(json.dumps(fixture))
            with (
                mock.patch("ios.build.CACHE", cache),
                mock.patch("ios.build.require_capacity"),
                mock.patch(
                    "ios.build.verify_model",
                    return_value={"files": {build.PINS["model"]: {"sha256": "a" * 64}}},
                ),
                mock.patch("ios.build.verify_source"),
                mock.patch("ios.build.run") as command,
            ):
                with self.assertRaisesRegex(ValueError, "fixture model hash mismatch"):
                    build.build("iphoneos", 2)
                command.assert_not_called()

    def test_overloaded_machine_refuses_before_verification_or_build(self):
        with (
            mock.patch("ios.build.sys.platform", "darwin"),
            mock.patch("ios.build.os.cpu_count", return_value=10),
            mock.patch("ios.build.os.getloadavg", return_value=(20.0, 15.0, 12.0)),
            mock.patch(
                "ios.build.verify_model",
                side_effect=AssertionError("overloaded build reached verification"),
            ) as verify,
            mock.patch("ios.build.subprocess.run") as command,
        ):
            with self.assertRaisesRegex(RuntimeError, "native build deferred"):
                build.build("iphoneos", 2)
            verify.assert_not_called()
            command.assert_not_called()

    def test_quiet_machine_passes_capacity_check(self):
        with (
            mock.patch("ios.build.sys.platform", "darwin"),
            mock.patch("ios.build.os.cpu_count", return_value=10),
            mock.patch("ios.build.os.getloadavg", return_value=(3.0, 5.0, 12.0)),
        ):
            build.require_capacity()


if __name__ == "__main__":
    unittest.main()
