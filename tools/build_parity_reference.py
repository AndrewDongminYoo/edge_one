"""Build/verify the independent Linux AVX2 parity reference; never fetch inputs."""

import argparse
import hashlib
import importlib.util
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILE = "linux-x86_64-avx2-v1"
SETTINGS = {
    "CMAKE_BUILD_TYPE": "Release",
    "BUILD_SHARED_LIBS": "ON",
    **{
        f"GGML_{key}": "ON"
        for key in (
            "CPU",
            "AVX",
            "AVX2",
            "SSE42",
            "BMI2",
            "F16C",
            "FMA",
            "OPENMP",
            "LLAMAFILE",
            "CPU_REPACK",
        )
    },
    **{
        f"GGML_{key}": "OFF"
        for key in (
            "NATIVE",
            "AVX_VNNI",
            "AVX512",
            "AVX512_VBMI",
            "AVX512_VNNI",
            "AVX512_BF16",
            "AMX_TILE",
            "AMX_INT8",
            "AMX_BF16",
            "CPU_ALL_VARIANTS",
            "BACKEND_DL",
            "BLAS",
            "OPENMP_FETCH",
            "LTO",
            "CUDA",
            "METAL",
            "VULKAN",
            "HIP",
            "SYCL",
            "RPC",
            "OPENCL",
            "MUSA",
            "HEXAGON",
            "WEBGPU",
            "OPENVINO",
            "ZENDNN",
            "ZDNN",
            "VIRTGPU",
            "VIRTGPU_BACKEND",
            "CPU_HBM",
            "CPU_KLEIDIAI",
            "SANITIZE_ADDRESS",
            "SANITIZE_THREAD",
            "SANITIZE_UNDEFINED",
        )
    },
    "GGML_SCHED_MAX_COPIES": "4",
    "GGML_SCHED_NO_REALLOC": "OFF",
}
MACHINE_FLAGS = {"-msse4.2", "-mf16c", "-mfma", "-mbmi2", "-mavx", "-mavx2"}
LIBRARIES = {"libllama.so", "libggml.so", "libggml-base.so", "libggml-cpu.so"}


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def reference_root(cache, profile):
    if profile != PROFILE:
        raise ValueError(f"unsupported reference profile: {profile}")
    root = cache / f"reference-{profile}"
    if root.is_symlink() or root.resolve().parent != cache.resolve():
        raise ValueError("reference cache isolation violated")
    return root


def check_host(system, machine, flags):
    required = {"avx", "avx2", "sse4_2", "bmi2", "f16c", "fma"}
    if system != "Linux" or machine != "x86_64" or not required <= set(flags.split()):
        raise ValueError("unsupported host for Linux x86-64 AVX2 reference")


def verify_host():
    if platform.system() != "Linux":
        raise ValueError("unsupported host: Linux required")
    cpu_flags = [
        line.split(":", 1)[1]
        for line in Path("/proc/cpuinfo").read_text().splitlines()
        if line.startswith("flags")
    ]
    if not cpu_flags:
        raise ValueError("cannot verify host CPU features")
    for flags in cpu_flags:
        check_host(platform.system(), platform.machine(), flags)


def check_settings(cache, flags):
    for key, value in SETTINGS.items():
        if cache.get(key) != value:
            raise ValueError(f"fixed CPU profile drift: {key}")
    for language in ("C", "CXX"):
        tokens = shlex.split(flags.get(f"{language}_FLAGS", ""))
        if {t for t in tokens if t.startswith("-m")} != MACHINE_FLAGS:
            raise ValueError(f"effective CPU flags drift: {language}")
        if any(
            t.startswith(
                (
                    "-ffast-math",
                    "-Ofast",
                    "-funsafe-math",
                    "-ffinite-math",
                    "-fno-signed-zeros",
                    "-freciprocal-math",
                    "-fassociative-math",
                )
            )
            for t in tokens
        ):
            raise ValueError("unsafe floating-point compiler flags")
        if "-O3" not in tokens or "-DNDEBUG" not in tokens or "-fopenmp" not in tokens:
            raise ValueError("effective common compiler flags drift")


def inspect_build(build):
    cache_file = build / "CMakeCache.txt"
    cache = {}
    for line in cache_file.read_text().splitlines():
        if line and not line.startswith(("#", "//")) and "=" in line:
            key, value = line.split("=", 1)
            cache[key.split(":", 1)[0]] = value
    if cache.get("CMAKE_GENERATOR") != "Unix Makefiles":
        raise ValueError("unsupported build generator; Unix Makefiles required")
    effective = {}
    flag_hashes = {}
    for target in ("llama", "ggml", "ggml-base", "ggml-cpu"):
        paths = list(build.rglob(f"CMakeFiles/{target}.dir/flags.make"))
        if len(paths) != 1:
            raise ValueError(f"missing or ambiguous compiler flags: {target}")
        path = paths[0]
        effective[target] = {
            key.strip(): value.strip()
            for line in path.read_text().splitlines()
            if " = " in line
            for key, value in [line.split(" = ", 1)]
            if key.endswith(("_FLAGS", "_DEFINES"))
        }
        flag_hashes[str(path.relative_to(build))] = sha256(path)
    check_settings(cache, effective["ggml-cpu"])
    compilers = {}
    for language in ("C", "CXX"):
        compiler = Path(cache[f"CMAKE_{language}_COMPILER"]).resolve()
        compilers[language] = {
            "path": str(compiler),
            "sha256": sha256(compiler),
            "version": subprocess.check_output(
                [str(compiler), "--version"], text=True, timeout=10
            ),
        }
    return {
        "settings": {key: cache[key] for key in SETTINGS},
        "effective": effective,
        "compilers": compilers,
        "cache_sha256": sha256(cache_file),
        "flag_sha256": flag_hashes,
        "ggml_cache": {
            key: value for key, value in cache.items() if key.startswith("GGML_")
        },
    }


def artifact_paths(root):
    return [root / "bin/jev-score", *sorted((root / "build/bin").glob("*.so*"))]


def verify_artifacts(root, artifacts):
    expected = {str(path.resolve()) for path in artifact_paths(root)}
    if set(artifacts) != expected or not LIBRARIES <= {
        Path(p).name.split(".so", 1)[0] + ".so" for p in artifacts
    }:
        raise ValueError("reference receipt has missing or extra artifacts")
    for name, digest in artifacts.items():
        path = Path(name)
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError("reference artifact isolation violated")
        if not path.is_file() or sha256(path) != digest:
            raise ValueError(f"reference artifact integrity failed: {name}")


def check_receipt(receipt, pins, observed):
    if (
        receipt.get("profile") != PROFILE
        or receipt.get("pins") != pins
        or receipt.get("build") != observed
    ):
        raise ValueError("fixed reference receipt/profile/build drift")


def check_mappings(maps, expected):
    paths = set()
    for line in maps.splitlines():
        columns = line.split(maxsplit=5)
        if len(columns) == 6 and columns[5].startswith("/"):
            path = Path(columns[5])
            # The model mapping is verified separately; record executable/shared objects.
            if ".so" in path.name or "x" in columns[1]:
                if not path.is_file():
                    raise ValueError(f"loaded artifact missing/deleted: {path}")
                stat = path.stat()
                major, minor = (int(value, 16) for value in columns[3].split(":"))
                if stat.st_ino != int(columns[4]) or (
                    os.major(stat.st_dev),
                    os.minor(stat.st_dev),
                ) != (major, minor):
                    raise ValueError(f"loaded mapping identity changed: {path}")
                paths.add(str(path.resolve()))
    if not set(expected) <= paths:
        raise ValueError("loaded artifacts missing expected executable/libraries")
    loaded = {}
    for name in sorted(paths):
        path = Path(name)
        if not path.is_file():
            raise ValueError(f"loaded artifact missing/deleted: {name}")
        if path.name.startswith(("libggml", "libllama")) and name not in expected:
            raise ValueError(f"unexpected loaded backend library: {name}")
        loaded[name] = sha256(path)
        if name in expected and loaded[name] != expected[name]:
            raise ValueError(f"loaded artifact integrity failed: {name}")
    return loaded


def loaded_artifacts(pid, expected):
    maps = Path(f"/proc/{pid}/maps").read_text()
    executable = Path(f"/proc/{pid}/exe").resolve()
    if (
        str(executable) not in expected
        or sha256(Path(f"/proc/{pid}/exe")) != expected[str(executable)]
    ):
        raise ValueError("loaded executable integrity failed")
    return {
        "pid": pid,
        "executable": str(executable),
        "artifacts": check_mappings(maps, expected),
        "maps": maps,
    }


def inputs():
    sys.path.insert(0, str(ROOT / "spikes/m0"))
    import setup

    return setup


def verify_reference(profile):
    setup = inputs()
    root = reference_root(setup.CACHE, profile)
    verify_host()
    manifest = setup.verify_model()
    setup.verify_source()
    receipt = json.loads((root / "build-receipt.json").read_text())
    check_receipt(receipt, setup.PINS, inspect_build(root / "build"))
    verify_artifacts(root, receipt["artifacts"])
    if receipt.get("scorer_source_sha256") != sha256(setup.MODEL_DIR / "jev_score.cpp"):
        raise ValueError("pinned scorer receipt drift")
    spec = importlib.util.spec_from_file_location(
        "m0_reference", setup.MODEL_DIR / "jev_style_decision_gguf.py"
    )
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    return runtime, manifest, receipt, root / "bin/jev-score"


def production_artifacts(driver, build, reference):
    observed = inspect_build(build)
    for key in ("settings", "effective", "compilers"):
        if observed[key] != reference["build"][key]:
            raise ValueError(f"production/reference build mismatch: {key}")
    if driver.resolve() != (build / "edge_one_score_driver").resolve():
        raise ValueError("driver does not belong to inspected production build")
    paths = [
        driver,
        *sorted((build / "bin").glob("*.so*")),
    ]
    artifacts = {str(path.resolve()): sha256(path) for path in paths}
    if not LIBRARIES <= {Path(p).name.split(".so", 1)[0] + ".so" for p in artifacts}:
        raise ValueError("production libraries missing")
    if set(artifacts) & set(reference["artifacts"]):
        raise ValueError("production/reference artifacts must be independent")
    return observed, artifacts


def build(jobs, profile=PROFILE):
    if jobs < 1:
        raise ValueError("jobs must be positive")
    setup = inputs()
    root = reference_root(setup.CACHE, profile)
    verify_host()
    setup.verify_model()
    setup.verify_source()
    # No rebuild can silently replace accepted artifacts or reuse native M0 build state.
    root.mkdir(parents=True, exist_ok=False)
    cmake = shutil.which("cmake")
    if not cmake:
        raise FileNotFoundError("install the pinned M0 CMake environment")
    configure = [
        cmake,
        "-G",
        "Unix Makefiles",
        "-S",
        str(setup.SOURCE),
        "-B",
        str(root / "build"),
    ]
    configure += [f"-D{key}={value}" for key, value in SETTINGS.items()]
    configure += [
        f"-DLLAMA_BUILD_{key}=OFF"
        for key in ("TESTS", "SERVER", "EXAMPLES", "COMMON", "TOOLS", "APP", "MTMD")
    ]
    subprocess.run(configure, check=True)
    subprocess.run(
        [
            cmake,
            "--build",
            str(root / "build"),
            "--parallel",
            str(jobs),
            "--target",
            "llama",
        ],
        check=True,
    )
    observed = inspect_build(root / "build")
    binary = root / "bin/jev-score"
    binary.parent.mkdir()
    libraries = root / "build/bin"
    compile_command = [
        observed["compilers"]["CXX"]["path"],
        "-std=c++17",
        "-O2",
        "-Wall",
        "-Wno-unused-function",
        f'-I{setup.SOURCE / "include"}',
        f'-I{setup.SOURCE / "ggml/include"}',
        f'-I{setup.SOURCE / "vendor"}',
        str(setup.MODEL_DIR / "jev_score.cpp"),
        "-o",
        str(binary),
        f"-L{libraries}",
        "-lllama",
        "-lggml",
        "-lggml-base",
        f"-Wl,-rpath,{libraries}",
    ]
    subprocess.run(compile_command, check=True)
    receipt = {
        "profile": PROFILE,
        "pins": setup.PINS,
        "build": observed,
        "cmake": subprocess.check_output([cmake, "--version"], text=True, timeout=10),
        "configure_command": configure,
        "compile_command": compile_command,
        "scorer_source_sha256": sha256(setup.MODEL_DIR / "jev_score.cpp"),
        "artifacts": {str(p.resolve()): sha256(p) for p in artifact_paths(root)},
    }
    verify_artifacts(root, receipt["artifacts"])
    with (root / "build-receipt.json").open("x") as stream:
        json.dump(receipt, stream, indent=2)
        stream.write("\n")
    print(f"Built independent {PROFILE} reference: {binary}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "verify"))
    parser.add_argument("--profile", choices=(PROFILE,), required=True)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if args.action == "build":
        build(args.jobs, args.profile)
    else:
        verify_reference(args.profile)
        print(f"Verified {args.profile}")


if __name__ == "__main__":
    main()
