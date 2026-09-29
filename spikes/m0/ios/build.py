"""Build one unsigned Apple M0 target at a time from verified cached inputs."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import verify_file
from ios.prepare import native_fixture_header
from setup import CACHE, MODEL_DIR, PINS, SOURCE, verify_model, verify_source

IOS = Path(__file__).resolve().parent


def require_capacity():
    if sys.platform != "darwin":
        raise RuntimeError("Apple SDK builds require macOS")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        return
    load, cores = os.getloadavg()[0], os.cpu_count() or 1
    if load > cores:
        raise RuntimeError(
            f"native build deferred: 1-minute load {load:.2f} exceeds {cores} cores"
        )


def run(command):
    print(" ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True)


def file_hash(file):
    with file.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def build(sdk, jobs):
    if jobs < 1 or jobs > 2:
        raise ValueError("use one or two build jobs")
    require_capacity()
    manifest = verify_model()
    verify_source()
    fixture = CACHE / "ios/fixture.json"
    if not fixture.exists():
        raise FileNotFoundError("run ios/prepare.py before building")
    fixture_data = json.loads(fixture.read_text())
    if fixture_data["pins"] != PINS:
        raise ValueError("prepared fixture pin mismatch")
    if fixture_data["model_sha256"] != manifest["files"][PINS["model"]]["sha256"]:
        raise ValueError("prepared fixture model hash mismatch")
    if sdk == "iphonesimulator":
        native_header = CACHE / "ios/fixture_tokens.hpp"
        if native_header.read_text() != native_fixture_header(fixture_data):
            raise ValueError("native repro fixture header mismatch; run ios/prepare.py")
    directory = CACHE / "ios" / sdk
    directory.mkdir(parents=True, exist_ok=True)
    headers = [
        SOURCE / "include",
        SOURCE / "ggml/include",
        SOURCE / "vendor",
        MODEL_DIR,
    ]
    if sdk == "host":
        receipt = json.loads((CACHE / "build-receipt.json").read_text())
        if receipt["pins"] != PINS:
            raise ValueError("desktop build receipt pin mismatch")
        for name, digest in receipt["artifacts"].items():
            verify_file(CACHE / name, {"sha256": digest})
        binary = directory / "m0-host"
        libraries = SOURCE / "build/bin"
        require_capacity()
        run(
            [
                "c++",
                "-std=c++17",
                "-O2",
                "-Wno-deprecated-declarations",
                *[f"-I{p}" for p in headers],
                IOS / "Benchmark.cpp",
                IOS / "host_main.cpp",
                "-o",
                binary,
                f"-L{libraries}",
                "-lllama",
                "-lggml",
                "-lggml-base",
                f"-Wl,-rpath,{libraries}",
            ]
        )
        print(f"Host binary: {binary}")
        return
    cmake = CACHE / ".venv/bin/cmake"
    if not cmake.exists() or not shutil.which("xcodegen"):
        raise FileNotFoundError("the hashed M0 environment and XcodeGen are required")
    native = directory / "native"
    run(
        [
            cmake,
            "-S",
            SOURCE,
            "-B",
            native,
            "-G",
            "Xcode",
            "-DCMAKE_SYSTEM_NAME=iOS",
            f"-DCMAKE_OSX_SYSROOT={sdk}",
            "-DCMAKE_OSX_ARCHITECTURES=arm64",
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0",
            "-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DLLAMA_BUILD_COMMON=OFF",
            "-DLLAMA_BUILD_TOOLS=OFF",
            "-DLLAMA_BUILD_TESTS=OFF",
            "-DLLAMA_BUILD_SERVER=OFF",
            "-DLLAMA_BUILD_EXAMPLES=OFF",
            "-DLLAMA_CURL=OFF",
            "-DLLAMA_OPENSSL=OFF",
            "-DGGML_OPENMP=OFF",
            "-DGGML_BLAS=OFF",
            "-DGGML_NATIVE=OFF",
            "-DGGML_METAL=ON",
            "-DGGML_METAL_EMBED_LIBRARY=ON",
            "-DGGML_METAL_TARGET_OS=ios",
        ]
    )
    require_capacity()
    run(
        [
            cmake,
            "--build",
            native,
            "--config",
            "Release",
            "--target",
            "llama",
            "--parallel",
            jobs,
            "--",
            "-quiet",
        ]
    )
    archives = sorted(
        p for p in native.rglob("*.a") if p.parent.name == f"Release-{sdk}"
    )
    if not any(p.name == "libllama.a" for p in archives):
        raise FileNotFoundError("native build did not produce libllama.a")
    resources = directory / "Resources"
    resources.mkdir(exist_ok=True)
    destination = resources / "model.gguf"
    expected_model_hash = json.loads(fixture.read_text())["model_sha256"]
    if destination.exists():
        if file_hash(destination) != expected_model_hash:
            raise ValueError("cached model resource hash mismatch")
    else:
        os.link(MODEL_DIR / PINS["model"], destination)
    for name, source in [
        ("fixture.json", fixture),
        ("LICENSE", MODEL_DIR / "LICENSE"),
        ("NOTICE", MODEL_DIR / "NOTICE"),
    ]:
        shutil.copyfile(source, resources / name)
    receipt = {
        "sdk": sdk,
        "configuration": "Release",
        "architecture": "arm64",
        "pins": PINS,
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
        "xcodegen": subprocess.check_output(
            ["xcodegen", "--version"], text=True
        ).strip(),
        "native_archives": {
            str(p.relative_to(directory)): file_hash(p) for p in archives
        },
        "sources": {
            str(p.relative_to(IOS)): file_hash(p)
            for p in sorted(IOS.rglob("*"))
            if p.is_file()
            and p.suffix in (".cpp", ".hpp", ".h", ".mm", ".swift", ".py")
        },
        "fixture_sha256": file_hash(fixture),
    }
    (resources / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    spec = {
        "name": "EdgeOneM0",
        "settings": {"base": {"ARCHS": "arm64"}},
        "options": {"deploymentTarget": {"iOS": "17.0"}},
        "targets": {
            "EdgeOneM0": {
                "type": "application",
                "platform": "iOS",
                "sources": [
                    {"path": str(IOS / "app")},
                    {"path": str(IOS / "Benchmark.cpp")},
                    {"path": str(IOS / "Benchmark.hpp")},
                    {"path": str(resources), "buildPhase": "resources"},
                ],
                "settings": {
                    "base": {
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.andrewdongminyoo.edgeone.m0",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
                        "INFOPLIST_KEY_UIFileSharingEnabled": "YES",
                        "INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace": "YES",
                        "SWIFT_VERSION": "5.0",
                        "SWIFT_STRICT_CONCURRENCY": "complete",
                        "SWIFT_OBJC_BRIDGING_HEADER": str(
                            IOS / "app/NativeBenchmark.h"
                        ),
                        "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
                        "CLANG_ENABLE_OBJC_ARC": "YES",
                        "HEADER_SEARCH_PATHS": ["$(inherited)", *map(str, headers)],
                        "LIBRARY_SEARCH_PATHS": [
                            "$(inherited)",
                            *sorted({str(p.parent) for p in archives}),
                        ],
                        "OTHER_CPLUSPLUSFLAGS": [
                            "$(inherited)",
                            "-Wno-deprecated-declarations",
                        ],
                        "TARGETED_DEVICE_FAMILY": "1,2",
                        "CODE_SIGNING_ALLOWED": "NO",
                    }
                },
                "dependencies": [
                    *[{"framework": str(p), "embed": False} for p in archives],
                    *[
                        {"sdk": name}
                        for name in (
                            "Metal.framework",
                            "Foundation.framework",
                            "Accelerate.framework",
                        )
                    ],
                ],
            }
        },
        "schemes": {
            "EdgeOneM0": {
                "build": {"targets": {"EdgeOneM0": "all"}},
                "run": {"config": "Release"},
            }
        },
    }
    if sdk == "iphonesimulator":
        repro_settings = dict(spec["targets"]["EdgeOneM0"]["settings"]["base"])
        repro_settings.pop("SWIFT_OBJC_BRIDGING_HEADER")
        repro_settings.update(
            {
                "PRODUCT_BUNDLE_IDENTIFIER": "com.andrewdongminyoo.edgeone.m0.native-repro",
                "HEADER_SEARCH_PATHS": [
                    "$(inherited)",
                    *map(str, headers),
                    str(SOURCE / "src"),
                    str(CACHE / "ios"),
                ],
            }
        )
        spec["targets"]["NativeRepro"] = {
            "type": "application",
            "platform": "iOS",
            "sources": [
                str(IOS / "repro"),
                {"path": str(resources), "buildPhase": "resources"},
            ],
            "settings": {"base": repro_settings},
            "dependencies": [
                *spec["targets"]["EdgeOneM0"]["dependencies"],
                {"sdk": "UIKit.framework"},
            ],
        }
        spec["schemes"]["NativeRepro"] = {
            "build": {"targets": {"NativeRepro": "all"}},
            "run": {"config": "Release"},
        }
        spec["targets"]["EdgeOneM0UITests"] = {
            "type": "bundle.ui-testing",
            "platform": "iOS",
            "sources": [str(IOS / "tests")],
            "dependencies": [{"target": "EdgeOneM0"}, {"target": "NativeRepro"}],
            "settings": {
                "base": {
                    "PRODUCT_BUNDLE_IDENTIFIER": "com.andrewdongminyoo.edgeone.m0.uitests",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "SWIFT_VERSION": "5.0",
                    "CODE_SIGNING_ALLOWED": "NO",
                }
            },
        }
        spec["schemes"]["EdgeOneM0"]["test"] = {
            "config": "Release",
            "targets": ["EdgeOneM0UITests"],
        }
    spec_file = directory / "project.json"
    spec_file.write_text(json.dumps(spec, indent=2) + "\n")
    run(["xcodegen", "generate", "--spec", spec_file, "--project", directory])
    require_capacity()
    run(
        [
            "xcodebuild",
            "-project",
            directory / "EdgeOneM0.xcodeproj",
            "-scheme",
            "EdgeOneM0",
            "-configuration",
            "Release",
            "-sdk",
            sdk,
            "-destination",
            "generic/platform=iOS" + (" Simulator" if sdk == "iphonesimulator" else ""),
            "-derivedDataPath",
            directory / "DerivedData",
            "-jobs",
            jobs,
            "CODE_SIGNING_ALLOWED=NO",
            "build",
            "-quiet",
        ]
    )
    app = directory / f"DerivedData/Build/Products/Release-{sdk}/EdgeOneM0.app"
    receipt["app_binary_sha256"] = file_hash(app / "EdgeOneM0")
    (directory / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Unsigned app: {app}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sdk", choices=["host", "iphoneos", "iphonesimulator"], required=True
    )
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    build(args.sdk, args.jobs)


if __name__ == "__main__":
    main()
