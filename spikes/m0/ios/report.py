"""Validate pretokenized M0 reports without loading the model."""

import argparse
import hashlib
import json
import math
import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import compare

TIMING_SCOPE = (
    "pretokenized native scoring including internal memory resets and verdict softmax"
)


def validate_build(build, pins, digest):
    if (
        build.get("sdk") not in ("iphoneos", "iphonesimulator")
        or build.get("configuration") != "Release"
        or build.get("architecture") != "arm64"
        or build.get("pins") != pins
        or build.get("fixture_sha256") != digest
        or any(
            not isinstance(build.get(key), str) or not build[key].strip()
            for key in ("xcode", "xcodegen")
        )
    ):
        raise ValueError("invalid build receipt")
    for key in ("native_archives", "sources"):
        hashes = build.get(key)
        if (
            not isinstance(hashes, dict)
            or not hashes
            or any(
                not isinstance(name, str)
                or not name
                or not isinstance(value, str)
                or re.fullmatch(r"[0-9a-f]{64}", value) is None
                for name, value in hashes.items()
            )
        ):
            raise ValueError("invalid build receipt hashes")


def ordered_result(result, names):
    probabilities = result["probabilities"]
    if set(probabilities) != set(names):
        raise ValueError("result options do not match the fixture")
    return {
        "answer": result["answer"],
        "probabilities": {n: probabilities[n] for n in names},
    }


def summarize_report(report, fixture, pins):
    metadata = report["metadata"]
    if (
        report["schema_version"] != 1
        or metadata["pins"] != pins
        or fixture["pins"] != pins
    ):
        raise ValueError("report schema or pins mismatch")
    digest = hashlib.sha256(
        json.dumps(fixture, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    if metadata["fixture_sha256"] != digest:
        raise ValueError("fixture hash mismatch")
    if metadata["timing_scope"] != TIMING_SCOPE:
        raise ValueError("unexpected timing scope")
    if "build" in metadata:
        validate_build(metadata["build"], pins, digest)
    if (
        metadata["model_sha256"] != fixture["model_sha256"]
        or metadata["model_hash_verified"] is not True
    ):
        raise ValueError("model identity or integrity verification mismatch")
    repetitions = metadata["repetitions"]
    records = report["records"]
    if (
        type(repetitions) is not int
        or repetitions < 1
        or len(records) != repetitions + 1
    ):
        raise ValueError("incomplete record set")
    names, temperature = fixture["option_names"], fixture["temperature"]
    if (
        not names
        or len(set(names)) != len(names)
        or type(temperature) not in (int, float)
        or not math.isfinite(temperature)
        or temperature <= 0
    ):
        raise ValueError("invalid options or temperature")
    for key, value in {
        "n_ctx": 2048,
        "n_ubatch": 1024,
        "n_seq_max": 2,
        "n_outputs_max": 16,
    }.items():
        if report["ready"][key] != value:
            raise ValueError("unexpected ready settings")
    differences = []
    for i, record in enumerate(records):
        if record["sample"] != i or record["phase"] != ("first" if i == 0 else "warm"):
            raise ValueError("unexpected record set")
        if record["memory_reset"] is not True:
            raise ValueError("memory reset missing")
        duration = record["duration_ms"]
        if (
            type(duration) not in (int, float)
            or not math.isfinite(duration)
            or duration <= 0
        ):
            raise ValueError("invalid duration")
        native = record["native_response"]
        if (
            native["mode"] != "fused"
            or native["prefix_reused"] is not False
            or native["n_prefix"] != len(fixture["native_request"]["prefix"])
        ):
            raise ValueError("unexpected native mode, prefix or reuse")
        if len(native["results"]) != 1:
            raise ValueError("unexpected native result count")
        result = native["results"][0]
        rows = result["scores"]
        if (
            result["finite"] is not True
            or len(rows) != len(names)
            or any(
                len(row) != 2
                or any(type(v) not in (int, float) or not math.isfinite(v) for v in row)
                for row in rows
            )
        ):
            raise ValueError("invalid native score")
        logits = [(yes - no) / temperature for yes, no in rows]
        weights = [math.exp(z - max(logits)) for z in logits]
        probabilities = dict(
            zip(names, [w / sum(weights) for w in weights], strict=True)
        )
        calculated = {
            "answer": max(names, key=probabilities.get),
            "probabilities": probabilities,
        }
        consistency = compare(
            names, calculated, ordered_result(record["result"], names)
        )
        if consistency["max_abs_difference"] > 1e-12:
            raise ValueError("probabilities do not match native logits")
        differences.append(
            compare(names, ordered_result(fixture["reference"], names), calculated)
        )
    device = metadata["device"]
    physical = (
        device["platform"] == "iOS"
        and device["simulator"] is False
        and device["hardware"].startswith("iPhone")
        and bool(device["os"])
        and metadata.get("build", {}).get("sdk") == "iphoneos"
    )
    return {
        "warm_p50_ms": statistics.median(r["duration_ms"] for r in records[1:]),
        "warm_samples": repetitions,
        "first_request_ms": records[0]["duration_ms"],
        "max_abs_difference": max(d["max_abs_difference"] for d in differences),
        "passes_gate": all(d["passes_gate"] for d in differences),
        # Reported metadata is not independent proof of physical execution.
        "declared_physical_ios": physical,
        "timing_scope": metadata["timing_scope"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument(
        "--require-device-metadata",
        action="store_true",
        help="require declared iPhone/Release/arm64 metadata; does not prove execution origin",
    )
    args = parser.parse_args()
    pins = json.loads((Path(__file__).resolve().parents[1] / "pins.json").read_text())
    summary = summarize_report(
        json.loads(args.report.read_text()), json.loads(args.fixture.read_text()), pins
    )
    print(json.dumps(summary, indent=2))
    if args.require_device_metadata and not summary["declared_physical_ios"]:
        raise SystemExit(
            "physical iOS metadata required; host/simulator report rejected"
        )
    raise SystemExit(0 if summary["passes_gate"] else 1)


if __name__ == "__main__":
    main()
