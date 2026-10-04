"""Compare production C++ scoring with existing verified M0 inputs; never fetch."""

import argparse
import hashlib
import json
import math
import platform
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "packages/edge_one_flutter/assets/model_manifest.json"


def check_fixture_spec(specification):
    digest = hashlib.sha256(
        json.dumps(specification, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    # The original four-fixture M0 corpus, not any archived probability result.
    if digest != "88117ea049f191749059aa5200413c86d3036eeb5a30bb5d8b89855cc51f271c":
        raise ValueError("pinned M0 fixture corpus changed")


PRODUCTION_PROFILE = {
    "n_ctx": 2048,
    "n_ctx_seq": 2048,
    "n_batch": 2048,
    "n_ubatch": 1024,
    "n_seq_max": 2,
    "n_outputs_max": 26,
    "threads": 2,
    "threads_batch": 2,
    "kv_unified": True,
    "n_gpu_layers": 0,
    "offload_kqv": False,
    "op_offload": False,
    "flash_attn": "auto",
}


def check_profile(profile):
    for key, value in PRODUCTION_PROFILE.items():
        if type(profile.get(key)) is not type(value) or profile.get(key) != value:
            raise ValueError(f"production profile drift: {key}")


def check_observation(actual, rendered, mode):
    if mode not in ("individual", "exact"):
        raise ValueError("unsupported scoring mode")
    if actual.get("rendered") != rendered:
        raise ValueError(
            "production tokens, option order or verdict slots differ from upstream"
        )
    questions = rendered["questions"]
    prefix = len(rendered["prefix"])
    shared = prefix // 1024 * 1024 if mode == "exact" and len(questions) > 1 else 0
    expected = {
        "shared_tokens": shared,
        "prefix_decoded_tokens": shared,
        "sequence_copies": len(questions) if shared else 0,
        "decoded_tokens": shared
        + sum(prefix - shared + len(q["tokens"]) for q in questions),
        "decode_calls": len(questions) + bool(shared),
    }
    if actual.get("diagnostics") != expected:
        raise ValueError(
            "native decode/copy observations do not prove expected sharing"
        )
    values = actual.get("distributions")
    if not isinstance(values, list) or len(values) != len(questions):
        raise ValueError("wrong native distribution count")
    for question, probabilities in zip(questions, values, strict=True):
        if len(probabilities) != len(question["names"]):
            raise ValueError("wrong native option count")


def require_parity(actual, expected):
    if not isinstance(actual, list) or not actual or len(actual) != len(expected):
        raise ValueError("wrong probability question count")
    maximum = 0.0
    for values, reference in zip(actual, expected, strict=True):
        if not isinstance(values, list) or not values or len(values) != len(reference):
            raise ValueError("wrong probability option count")
        for distribution in (values, reference):
            if (
                any(
                    type(value) not in (int, float)
                    or not math.isfinite(value)
                    or not 0 <= value <= 1
                    for value in distribution
                )
                or abs(sum(distribution) - 1) > 1e-8
            ):
                raise ValueError("invalid probability distribution")
        maximum = max(
            maximum, *(abs(a - b) for a, b in zip(values, reference, strict=True))
        )
    if maximum >= 1e-3:
        raise ValueError(f"strict probability parity failed: {maximum} >= 1e-3")
    return maximum


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def run(driver, output, repetitions):
    if repetitions < 1:
        raise ValueError("repetitions must be positive")
    if output.exists() or output.with_suffix(output.suffix + ".partial").exists():
        raise FileExistsError(f"refusing to overwrite report: {output}")
    if not driver.is_file():
        raise FileNotFoundError(f"build the production parity driver first: {driver}")
    sys.path.insert(0, str(ROOT / "spikes/m0"))
    from run import load_runtime, make_fixtures
    from setup import MODEL_DIR, PINS, verify_source

    # These functions verify pinned model/runtime/tokenizer and build artifact
    # hashes. Missing input is an error, not an implicit download or test skip.
    runtime, upstream_manifest, receipt = load_runtime()
    verify_source()
    manifest = json.loads(MANIFEST.read_text())
    readout = json.loads((MODEL_DIR / "readout_config.json").read_text())
    upstream_model = upstream_manifest["files"][PINS["model"]]
    if (
        manifest["revision"] != PINS["revision"]
        or manifest["file"] != PINS["model"]
        or manifest["sha256"] != upstream_model["sha256"]
        or manifest["bytes"] != upstream_model["bytes"]
        or manifest["temperature"]["global"] != readout["temperatures"]["global"]
        or any(
            manifest["slot_tokens"][key] != readout["slot_tokens"][key]["id"]
            for key in ("yes", "no", "verdict_slot")
        )
    ):
        raise ValueError("bundled manifest differs from pinned upstream model/readout")
    fixture_file = ROOT / "spikes/m0/fixtures.json"
    specification = json.loads(fixture_file.read_text())
    check_fixture_spec(specification)
    renderer = runtime.Renderer(
        runtime.TextEncoder(MODEL_DIR / "tokenizer/tokenizer.json"), readout
    )
    fixtures = make_fixtures(renderer, specification)
    report = {
        "metadata": {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "commit": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
            ).strip(),
            "platform": platform.platform(),
            "machine": platform.machine(),
            "pins": PINS,
            "model_sha256": manifest["sha256"],
            "readout_sha256": sha256(MODEL_DIR / "readout_config.json"),
            "manifest_sha256": sha256(MANIFEST),
            "fixture_sha256": sha256(fixture_file),
            "driver_sha256": sha256(driver),
            "reference_build": receipt,
            "repetitions": repetitions,
            "gate": "max_abs_difference < 1e-3",
            "first_definition": "first request after fresh process; OS caches uncontrolled",
            "warm_definition": "same process; native memory cleared between calls",
            "timing_scope": "native rendering/scoring vs upstream Python rendering/scoring; startup excluded",
        },
        "fixture_spec": specification,
        "fixtures": fixtures,
        "records": [],
        "comparisons": [],
        "engines": [],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    partial = output.with_suffix(output.suffix + ".partial")
    with partial.open("x") as stream:
        json.dump(report, stream, indent=2, allow_nan=False)

    def save():
        partial.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")

    try:
        with output.with_suffix(output.suffix + ".stderr").open("x") as log:
            for fixture in fixtures:
                rendered_questions = [
                    renderer.render(fixture["state"], q) for q in fixture["questions"]
                ]
                prefix = rendered_questions[0].prefix_len
                rendered = {
                    "prefix": rendered_questions[0].ids[:prefix],
                    "questions": [
                        {
                            "names": q.names,
                            "tokens": q.ids[prefix:],
                            "slots": [slot - prefix for slot in q.slots],
                        }
                        for q in rendered_questions
                    ],
                }
                request = {
                    "state": fixture["state"],
                    "model": manifest["id"],
                    "questions": {
                        str(index): {
                            "type": q["t"],
                            "instructions": q["ins"],
                            **({"criteria": q["crit"]} if "crit" in q else {}),
                        }
                        for index, q in enumerate(fixture["questions"])
                    },
                }
                reference = runtime.JevStyleDecisionGGUF(
                    model_dir=MODEL_DIR,
                    quant="Q4_K_M",
                    binary=ROOT / ".cache/m0/bin/jev-score",
                    n_gpu_layers=0,
                    threads=2,
                    n_ubatch=1024,
                    many_mode="exact",
                    stderr=log,
                )
                references = []
                try:
                    for key, expected in {
                        "n_ctx": 32768,
                        "n_batch": 32768,
                        "n_ubatch": 1024,
                        "n_seq_max": 17,
                        "n_outputs_max": 256,
                    }.items():
                        if reference.info.get(key) != expected:
                            raise ValueError(f"upstream reference profile drift: {key}")
                    report["engines"].append(
                        {
                            "fixture": fixture["id"],
                            "mode": "upstream_individual",
                            "ready": reference.info,
                            "n_gpu_layers": 0,
                            "threads": 2,
                        }
                    )
                    for sample in range(repetitions + 1):
                        if reference._request({"cmd": "reset"}) != {"ok": True}:
                            raise ValueError("upstream reset failed")
                        start = time.perf_counter()
                        results = [
                            reference.decide(fixture["state"], q)
                            for q in fixture["questions"]
                        ]
                        references.append(
                            [
                                list(result["probabilities"].values())
                                for result in results
                            ]
                        )
                        report["records"].append(
                            {
                                "fixture": fixture["id"],
                                "mode": "upstream_individual",
                                "sample": sample,
                                "phase": "first" if sample == 0 else "warm",
                                "duration_ms": (time.perf_counter() - start) * 1000,
                                "results": results,
                            }
                        )
                finally:
                    reference.close()
                    if reference.proc.poll() is None:
                        reference.proc.kill()
                    reference.proc.wait(timeout=10)
                    reference.proc.stdin.close()
                    reference.proc.stdout.close()
                native = {}
                for mode in ("individual", "exact"):
                    process = subprocess.run(
                        [
                            str(driver),
                            str(MODEL_DIR / PINS["model"]),
                            str(MANIFEST),
                            mode,
                        ],
                        input=(json.dumps(request, ensure_ascii=False) + "\n")
                        * (repetitions + 1),
                        stdout=subprocess.PIPE,
                        stderr=log,
                        text=True,
                        timeout=600,
                        check=False,
                    )
                    messages = [
                        json.loads(line) for line in process.stdout.splitlines()
                    ]
                    if (
                        process.returncode
                        or len(messages) != repetitions + 2
                        or not messages[0].get("ready")
                    ):
                        raise ValueError(f"native driver failed ({mode}): {messages}")
                    ready, samples = messages[0], messages[1:]
                    report["engines"].append(
                        {"fixture": fixture["id"], "mode": mode, "ready": ready}
                    )
                    native[mode] = samples
                    for sample, result in enumerate(samples):
                        report["records"].append(
                            {
                                "fixture": fixture["id"],
                                "mode": mode,
                                "sample": sample,
                                "phase": "first" if sample == 0 else "warm",
                                "result": result,
                            }
                        )
                    save()  # Retain raw results even when the following gate fails.
                    check_profile(ready["profile"])
                    if (
                        ready.get("mode") != mode
                        or ready.get("model_sha256") != manifest["sha256"]
                        or ready.get("revision") != manifest["revision"]
                        or ready.get("temperature") != manifest["temperature"]["global"]
                    ):
                        raise ValueError("native driver model/readout identity drift")
                    for sample, result in enumerate(samples):
                        check_observation(result, rendered, mode)
                        difference = require_parity(
                            result["distributions"], references[sample]
                        )
                        report["comparisons"].append(
                            {
                                "fixture": fixture["id"],
                                "mode": mode,
                                "sample": sample,
                                "reference": "upstream_individual",
                                "max_abs_difference": difference,
                            }
                        )
                for sample in range(repetitions + 1):
                    difference = require_parity(
                        native["exact"][sample]["distributions"],
                        native["individual"][sample]["distributions"],
                    )
                    report["comparisons"].append(
                        {
                            "fixture": fixture["id"],
                            "mode": "exact",
                            "sample": sample,
                            "reference": "production_individual",
                            "max_abs_difference": difference,
                        }
                    )
                save()
        if not any(
            record.get("result", {}).get("diagnostics", {}).get("shared_tokens", 0)
            for record in report["records"]
        ):
            raise ValueError("fixtures never exercised actual prefix sharing")
        report["summary"] = {
            "passes_gate": True,
            "compared_requests": len(report["comparisons"]),
            "max_abs_difference": max(
                item["max_abs_difference"] for item in report["comparisons"]
            ),
        }
        report["metadata"]["finished_utc"] = datetime.now(timezone.utc).isoformat()
        with output.open("x") as stream:
            json.dump(report, stream, indent=2, allow_nan=False)
            stream.write("\n")
        partial.unlink()
        print(json.dumps(report["summary"], indent=2))
    except Exception as error:
        report["error"] = str(error)
        save()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repetitions", type=int, default=1)
    args = parser.parse_args()
    run(args.driver.resolve(), args.output.resolve(), args.repetitions)


if __name__ == "__main__":
    main()
