"""Run and judge the direct CPU/Metal reproduction on a hosted iOS 27 simulator."""

import argparse
import hashlib
import json
import math
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import compare

ROOT = Path(__file__).resolve().parents[3]
IOS_CACHE = ROOT / ".cache/m0/ios"
EVIDENCE = IOS_CACHE / "hosted"
BUNDLE_ID = "com.andrewdongminyoo.edgeone.m0.native-repro"
APP = (
    IOS_CACHE
    / "iphonesimulator/DerivedData/Build/Products/Release-iphonesimulator/NativeRepro.app"
)


def select_device(listing):
    candidates = [
        device
        for runtime, devices in listing["devices"].items()
        if re.fullmatch(
            r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-27(?:-\d+)*", runtime
        )
        for device in devices
        if device.get("name", "").startswith("iPhone ")
        and device.get("isAvailable", True)
        and device.get("state") in ("Shutdown", "Booted")
    ]
    if not candidates:
        raise ValueError("no available iOS 27 iPhone simulator")
    return min(candidates, key=lambda device: (device["name"], device["udid"]))


def summarize(raw, fixture):
    digest = hashlib.sha256(
        json.dumps(fixture, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    lines = raw.splitlines()
    if not lines or lines[0] != f"fixture_sha256 {digest}":
        raise ValueError("direct output fixture SHA-256 mismatch")
    names = fixture["option_names"]
    if not names or len(lines) != 1 + 2 * len(names):
        raise ValueError("direct output row count mismatch")
    reference = fixture["reference"]
    if set(reference["probabilities"]) != set(names):
        raise ValueError("fixture reference options mismatch")
    reference = {
        "answer": reference["answer"],
        "probabilities": {name: reference["probabilities"][name] for name in names},
    }
    temperature = fixture["temperature"]
    if (
        type(temperature) not in (int, float)
        or not math.isfinite(temperature)
        or temperature <= 0
    ):
        raise ValueError("invalid fixture temperature")
    distributions = {}
    for backend in ("cpu", "metal"):
        logits = []
        for index in range(len(names)):
            parts = lines[1 + (backend == "metal") * len(names) + index].split()
            if len(parts) != 4 or parts[:2] != [backend, str(index)]:
                raise ValueError(f"invalid {backend} row {index}")
            try:
                yes, no = map(float, parts[2:])
            except ValueError as error:
                raise ValueError(f"invalid {backend} logits") from error
            if not math.isfinite(yes) or not math.isfinite(no):
                raise ValueError(f"nonfinite {backend} logits")
            logits.append((yes - no) / temperature)
        peak = max(logits)
        weights = [math.exp(value - peak) for value in logits]
        total = sum(weights)
        probabilities = {
            name: weight / total for name, weight in zip(names, weights, strict=True)
        }
        distributions[backend] = {
            "answer": max(names, key=probabilities.get),
            "probabilities": probabilities,
        }
    comparisons = {
        "cpu_reference": compare(names, reference, distributions["cpu"]),
        "metal_reference": compare(names, reference, distributions["metal"]),
        "cpu_metal": compare(names, distributions["cpu"], distributions["metal"]),
    }
    return {
        "fixture_sha256": digest,
        "distributions": distributions,
        "comparisons": comparisons,
        "passes_gate": all(item["passes_gate"] for item in comparisons.values()),
    }


def command(*args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        raise RuntimeError(f"{' '.join(args)} failed: {detail}") from error
    return result.stdout.strip()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def check_metal_compiler():
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "smoke.metal"
        source.write_text(
            "#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "kernel void smoke(device float *values [[buffer(0)]], "
            "uint id [[thread_position_in_grid]]) { values[id] = 0.0f; }\n"
        )
        command(
            "xcrun",
            "--sdk",
            "iphonesimulator",
            "metal",
            "-c",
            str(source),
            "-o",
            str(Path(directory) / "smoke.air"),
        )


def preflight():
    result = {"supported": False}
    try:
        result["xcode"] = command("xcodebuild", "-version")
        result["simulator_sdk"] = command(
            "xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"
        )
        result["metal_tool"] = command("xcrun", "-f", "metal")
        if not re.search(r"^Xcode 27(?:\.|$)", result["xcode"], re.MULTILINE):
            raise ValueError("Xcode 27 is required")
        if not result["simulator_sdk"].startswith("27."):
            raise ValueError("iOS 27 simulator SDK is required")
        check_metal_compiler()
        result["metal_compile"] = True
        listing = json.loads(
            command("xcrun", "simctl", "list", "devices", "available", "-j")
        )
        result["device"] = select_device(listing)
        result["supported"] = True
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        result["error"] = str(error)
    write_json(EVIDENCE / "preflight.json", result)
    print(json.dumps(result, indent=2), flush=True)
    return result["supported"]


def run_gate(timeout):
    summary = {"passes_gate": False}
    booted_here = False
    device_id = None
    try:
        preflight_result = json.loads((EVIDENCE / "preflight.json").read_text())
        if not preflight_result["supported"]:
            raise ValueError("hosted simulator preflight failed")
        device = preflight_result["device"]
        device_id = device["udid"]
        summary["device"] = device
        if not APP.is_dir():
            raise FileNotFoundError(f"NativeRepro app missing: {APP}")
        if device["state"] == "Shutdown":
            command("xcrun", "simctl", "boot", device_id)
            booted_here = True
        command("xcrun", "simctl", "bootstatus", device_id, "-b")
        command("xcrun", "simctl", "install", device_id, str(APP))
        container = Path(
            command(
                "xcrun", "simctl", "get_app_container", device_id, BUNDLE_ID, "data"
            )
        )
        output = container / "Documents/native-repro.txt"
        output.unlink(missing_ok=True)
        command("xcrun", "simctl", "launch", device_id, BUNDLE_ID)
        deadline = time.monotonic() + timeout
        while not output.is_file() and time.monotonic() < deadline:
            time.sleep(2)
        if not output.is_file():
            raise TimeoutError(
                f"NativeRepro produced no plaintext output within {timeout}s"
            )
        raw = output.read_text()
        (EVIDENCE / "native-repro.txt").write_text(raw)
        fixture = json.loads((IOS_CACHE / "fixture.json").read_text())
        summary.update(summarize(raw, fixture))
        if not summary["passes_gate"]:
            summary["error"] = "strict CPU/Metal probability gate failed"
    except (OSError, RuntimeError, ValueError, KeyError, TimeoutError) as error:
        summary["error"] = str(error)
    finally:
        if booted_here and device_id:
            subprocess.run(
                ["xcrun", "simctl", "shutdown", device_id],
                capture_output=True,
                text=True,
            )
        write_json(EVIDENCE / "summary.json", summary)
        print(json.dumps(summary, indent=2), flush=True)
    return summary["passes_gate"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("preflight", "run"))
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    passed = preflight() if args.action == "preflight" else run_gate(args.timeout)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
