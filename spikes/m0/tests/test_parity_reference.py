"""Model-free integrity tests for the explicitly selected CPU reference."""

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))


class ParityReferenceTests(unittest.TestCase):
    def setUp(self):
        source = ROOT / "tools/build_parity_reference.py"
        self.assertTrue(source.is_file(), "fixed reference profile helper is missing")
        spec = importlib.util.spec_from_file_location("parity_reference", source)
        self.ref = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.ref)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_explicit_profile_and_isolation(self):
        isolated = self.ref.reference_root(self.root, "linux-x86_64-avx2-v1")
        self.assertEqual(isolated, self.root / "reference-linux-x86_64-avx2-v1")
        for profile in ("native", "", "../bin"):
            with self.subTest(profile=profile), self.assertRaises(ValueError):
                self.ref.reference_root(self.root, profile)
        isolated.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "isolat"):
            self.ref.reference_root(self.root, "linux-x86_64-avx2-v1")

    def test_unsupported_host_fails(self):
        flags = "avx avx2 sse4_2 bmi2 f16c fma"
        self.ref.check_host("Linux", "x86_64", flags)
        for system, machine, available in (
            ("Darwin", "x86_64", flags),
            ("Linux", "aarch64", flags),
            ("Linux", "x86_64", flags.replace("avx2", "")),
        ):
            with self.subTest(machine=machine), self.assertRaises(ValueError):
                self.ref.check_host(system, machine, available)

    def test_cache_and_effective_flags_must_agree(self):
        cache = dict(self.ref.SETTINGS)
        flags = "-O3 -DNDEBUG -msse4.2 -mf16c -mfma -mbmi2 -mavx -mavx2 -fopenmp"
        self.ref.check_settings(cache, {"C_FLAGS": flags, "CXX_FLAGS": flags})
        for key in ("GGML_NATIVE", "GGML_AVX512", "GGML_AMX_TILE", "GGML_BACKEND_DL"):
            altered = dict(cache, **{key: "ON"})
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.ref.check_settings(altered, {"C_FLAGS": flags, "CXX_FLAGS": flags})
        for extra in (" -march=native", " -mavx512f", " -ffast-math", " -mno-avx2"):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                self.ref.check_settings(
                    cache, {"C_FLAGS": flags + extra, "CXX_FLAGS": flags}
                )
        with self.assertRaises(ValueError):
            self.ref.check_settings(cache, {"C_FLAGS": flags})

    def artifacts(self):
        paths = [self.root / "bin/jev-score"]
        paths += [
            self.root / f"build/bin/lib{name}.so"
            for name in ("llama", "ggml", "ggml-base", "ggml-cpu")
        ]
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(path.name.encode())
        return {str(path.resolve()): self.ref.sha256(path) for path in paths}

    def test_receipt_artifacts_are_complete_confined_and_hashed(self):
        artifacts = self.artifacts()
        self.ref.verify_artifacts(self.root, artifacts)
        omitted = dict(artifacts)
        omitted.pop(str(self.root / "build/bin/libggml-cpu.so"))
        with self.assertRaises(ValueError):
            self.ref.verify_artifacts(self.root, omitted)
        escaping = dict(artifacts, **{"/tmp/outside-library.so": "0" * 64})
        with self.assertRaises(ValueError):
            self.ref.verify_artifacts(self.root, escaping)
        (self.root / "build/bin/libggml-cpu.so").write_bytes(b"mutated")
        with self.assertRaises(ValueError):
            self.ref.verify_artifacts(self.root, artifacts)

    def test_versioned_library_symlinks_are_verified_without_leaving_cache(self):
        self.artifacts()
        library = self.root / "build/bin/libggml-cpu.so"
        version = library.with_name("libggml-cpu.so.0.24.0")
        library.rename(version)
        library.symlink_to(version.name)
        artifacts = {
            str(path.resolve()): self.ref.sha256(path)
            for path in self.ref.artifact_paths(self.root)
        }
        self.ref.verify_artifacts(self.root, artifacts)

    def test_actual_mappings_reject_replacement_or_omission(self):
        artifacts = self.artifacts()
        mappings = "\n".join(
            f"100-200 r-xp 000 {os.major(Path(path).stat().st_dev):x}:{os.minor(Path(path).stat().st_dev):x} {Path(path).stat().st_ino} {path}"
            for path in artifacts
        )
        observed = self.ref.check_mappings(mappings, artifacts)
        self.assertEqual(observed, artifacts)
        for invalid in (
            mappings.replace("libggml-cpu.so", "other.so"),
            mappings + "\n100-200 r-xp 000 00:00 0 /tmp/libggml-cpu.so",
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                self.ref.check_mappings(invalid, artifacts)
        (self.root / "bin/jev-score").write_bytes(b"mutated")
        with self.assertRaises(ValueError):
            self.ref.check_mappings(mappings, artifacts)

    def test_mapping_inode_must_match_loaded_file(self):
        artifacts = self.artifacts()
        mappings = "\n".join(
            f"100-200 r-xp 000 00:00 999999 {path}" for path in artifacts
        )
        with self.assertRaisesRegex(ValueError, "mapping identity"):
            self.ref.check_mappings(mappings, artifacts)

    def test_production_driver_does_not_require_unlinked_core_library(self):
        driver = self.root / "edge_one_score_driver"
        driver.write_bytes(b"driver")
        (self.root / "libedge_one_core.so").write_bytes(b"unlinked API library")
        (self.root / "bin").mkdir()
        for name in self.ref.LIBRARIES:
            (self.root / "bin" / name).write_bytes(name.encode())
        observed = {"settings": "fixed", "effective": "fixed", "compilers": "fixed"}
        reference = {
            "build": observed,
            "artifacts": {"/independent/reference": "digest"},
        }
        # CMake inspection is independently tested; this pins the real artifact set.
        with patch.object(self.ref, "inspect_build", return_value=observed):
            _, artifacts = self.ref.production_artifacts(driver, self.root, reference)
        self.assertEqual(
            set(artifacts),
            {
                str(driver),
                *(str(self.root / "bin" / name) for name in self.ref.LIBRARIES),
            },
        )
        for key in observed:
            drifted = dict(observed, **{key: "drift"})
            with self.subTest(key=key), patch.object(
                self.ref, "inspect_build", return_value=drifted
            ), self.assertRaises(ValueError):
                self.ref.production_artifacts(driver, self.root, reference)

    def test_build_receipt_drift_fails(self):
        receipt = {
            "profile": self.ref.PROFILE,
            "pins": {"commit": "pinned"},
            "build": {"flags": "fixed"},
        }
        self.ref.check_receipt(receipt, {"commit": "pinned"}, {"flags": "fixed"})
        for changed in (
            dict(receipt, profile="native"),
            dict(receipt, pins={}),
            dict(receipt, build={"flags": "native"}),
        ):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                self.ref.check_receipt(
                    changed, {"commit": "pinned"}, {"flags": "fixed"}
                )


if __name__ == "__main__":
    unittest.main()
