"""Fetch verified M0 inputs and build the pinned reference scorer locally."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path

from harness import verify_file

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CACHE = ROOT / ".cache" / "m0"
PINS = json.loads((HERE / "pins.json").read_text())
MODEL_DIR = CACHE / "model"
SOURCE = CACHE / f"llama.cpp-{PINS['llama_cpp_commit']}"
ARCHIVE = CACHE / "llama.cpp.tar.gz"


def fetch_file(url, destination, expected):
    if destination.exists():
        verify_file(destination, expected)
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".part")
    print(f"Downloading {destination.name}", flush=True)
    with urllib.request.urlopen(url, timeout=60) as response, partial.open(
        "wb"
    ) as output:
        shutil.copyfileobj(response, output, length=1024 * 1024)
    verify_file(partial, expected)
    partial.replace(destination)


def verified_manifest():
    manifest_file = MODEL_DIR / "manifest.json"
    verify_file(manifest_file, {"sha256": PINS["manifest_sha256"]})
    manifest = json.loads(manifest_file.read_text())
    if manifest["repo"] != PINS["repo"]:
        raise ValueError("manifest repository mismatch")
    return manifest


def verify_model():
    manifest = verified_manifest()
    for name in PINS["files"]:
        verify_file(MODEL_DIR / name, manifest["files"][name])
    release = json.loads((MODEL_DIR / "release_config.json").read_text())
    if release["source"]["llama_cpp_commit"] != PINS["llama_cpp_commit"]:
        raise ValueError("release llama.cpp commit mismatch")
    return manifest


def verify_source():
    verify_file(ARCHIVE, {"sha256": PINS["llama_archive_sha256"]})
    with tarfile.open(ARCHIVE, "r:gz") as archive:
        for member in archive.getmembers():
            if member.isfile():
                with archive.extractfile(member) as stream:
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                verify_file(
                    CACHE / member.name, {"sha256": digest, "bytes": member.size}
                )


def fetch():
    base = f"https://huggingface.co/{PINS['repo']}/resolve/{PINS['revision']}/"
    fetch_file(
        base + "manifest.json",
        MODEL_DIR / "manifest.json",
        {"sha256": PINS["manifest_sha256"]},
    )
    manifest = verified_manifest()
    for name in PINS["files"]:
        fetch_file(base + name, MODEL_DIR / name, manifest["files"][name])
    fetch_file(
        f"https://codeload.github.com/ggml-org/llama.cpp/tar.gz/{PINS['llama_cpp_commit']}",
        ARCHIVE,
        {"sha256": PINS["llama_archive_sha256"]},
    )
    if not SOURCE.exists():
        with tarfile.open(ARCHIVE, "r:gz") as archive:
            archive.extractall(CACHE, filter="data")
    verify_source()
    verify_model()
    print("Pinned model, runtime, tokenizer, and native source verified.")


def build(jobs):
    if jobs < 1:
        raise ValueError("jobs must be positive")
    verify_model()
    verify_source()
    cmake = str(CACHE / ".venv" / "bin" / "cmake")
    if not Path(cmake).is_file():
        raise FileNotFoundError("install the hashed M0 environment before building")
    subprocess.run(
        [
            cmake,
            "-S",
            str(SOURCE),
            "-B",
            str(SOURCE / "build"),
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=ON",
            "-DLLAMA_BUILD_TESTS=OFF",
            "-DLLAMA_BUILD_SERVER=OFF",
            "-DLLAMA_BUILD_EXAMPLES=OFF",
            "-DLLAMA_CURL=OFF",
        ],
        check=True,
    )
    subprocess.run(
        [
            cmake,
            "--build",
            str(SOURCE / "build"),
            "--parallel",
            str(jobs),
            "--target",
            "llama",
        ],
        check=True,
    )
    libraries = SOURCE / "build" / "bin"
    binary = CACHE / "bin" / "jev-score"
    binary.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            os.environ.get("CXX", "c++"),
            "-std=c++17",
            "-O2",
            "-Wall",
            "-Wno-unused-function",
            f"-I{SOURCE / 'include'}",
            f"-I{SOURCE / 'ggml' / 'include'}",
            f"-I{SOURCE / 'vendor'}",
            str(MODEL_DIR / "jev_score.cpp"),
            "-o",
            str(binary),
            f"-L{libraries}",
            "-lllama",
            "-lggml",
            "-lggml-base",
            f"-Wl,-rpath,{libraries}",
        ],
        check=True,
    )
    artifacts = [
        binary,
        *sorted(libraries.glob("*.dylib")),
        *sorted(libraries.glob("*.so*")),
    ]
    receipt = {
        "pins": PINS,
        "cmake": subprocess.check_output([cmake, "--version"], text=True).splitlines()[
            0
        ],
        "compiler": subprocess.check_output(
            [os.environ.get("CXX", "c++"), "--version"], text=True
        ).splitlines()[0],
        "artifacts": {
            str(p.relative_to(CACHE)): hashlib.file_digest(
                p.open("rb"), "sha256"
            ).hexdigest()
            for p in artifacts
        },
    }
    (CACHE / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Built {binary}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["fetch", "verify", "build"])
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if args.action == "fetch":
        fetch()
    elif args.action == "build":
        build(args.jobs)
    else:
        verify_model()
        verify_source()
        print("Pinned inputs verified.")


if __name__ == "__main__":
    main()
