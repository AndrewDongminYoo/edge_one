"""Compare the pinned reference runtime's individual, exact, and batched modes."""

import argparse
import hashlib
import importlib.metadata
import importlib.util
import json
import platform
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from harness import observed_sharing, summarize, validate_fixtures, verify_file
from setup import CACHE, HERE, MODEL_DIR, PINS, verify_model


def make_fixtures(renderer, spec):
    cases = []
    for case in spec["cases"]:
        if "prefix_tokens" in case:
            target = case["prefix_tokens"]
            base = "I was charged twice. Please refund the duplicate payment."
            low, high = 0, target
            while low <= high:
                count = (low + high) // 2
                state = base + " note" * count
                actual = len(renderer.prefix_ids(state))
                if actual == target:
                    break
                if actual < target:
                    low = count + 1
                else:
                    high = count - 1
            else:
                raise ValueError(f"cannot produce exact prefix length {target}")
        else:
            state = case["state"]
        questions = spec["questions"]
        rendered = [renderer.render(state, q) for q in questions]
        prefix = rendered[0].prefix_len
        if any(
            r.prefix_len != prefix or r.ids[:prefix] != rendered[0].ids[:prefix]
            for r in rendered
        ):
            raise ValueError("fixture questions do not share one prefix")
        cases.append(
            {
                "id": case["id"],
                "state": state,
                "questions": questions,
                "prefix_tokens": prefix,
                "option_names": [r.names for r in rendered],
                "head_tokens": [r.head_tokens for r in rendered],
            }
        )
    validate_fixtures(cases)
    return cases


def load_runtime():
    manifest = verify_model()
    receipt = json.loads((CACHE / "build-receipt.json").read_text())
    if receipt["pins"] != PINS:
        raise ValueError("build receipt pin mismatch")
    if "bin/jev-score" not in receipt["artifacts"]:
        raise ValueError("build receipt missing scorer")
    for name, digest in receipt["artifacts"].items():
        verify_file(CACHE / name, {"sha256": digest})
    module_spec = importlib.util.spec_from_file_location(
        "m0_reference", MODEL_DIR / "jev_style_decision_gguf.py"
    )
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module, manifest, receipt


def run(output, repetitions, threads, microbatch):
    if repetitions < 1 or threads < 1 or microbatch < 1:
        raise ValueError("repetitions, threads, and microbatch must be positive")
    if output.exists():
        raise FileExistsError(f"refusing to overwrite report: {output}")
    runtime, manifest, receipt = load_runtime()
    fixture_file = HERE / "fixtures.json"
    fixture_spec = json.loads(fixture_file.read_text())
    fixture_hash = hashlib.sha256(
        json.dumps(fixture_spec, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    spec = json.loads(json.dumps(fixture_spec))
    spec["questions"] = [runtime.make_question(q) for q in spec["questions"]]
    readout = json.loads((MODEL_DIR / "readout_config.json").read_text())
    renderer = runtime.Renderer(
        runtime.TextEncoder(MODEL_DIR / "tokenizer" / "tokenizer.json"), readout
    )
    fixtures = make_fixtures(renderer, spec)
    if not any(f["prefix_tokens"] >= microbatch for f in fixtures):
        raise ValueError("fixtures do not activate exact prefix sharing")
    report = {
        "metadata": {
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "pins": PINS,
            "model_sha256": manifest["files"][PINS["model"]]["sha256"],
            "build": receipt,
            "platform": platform.platform(),
            "machine": platform.machine(),
            "hardware": (
                subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()
                if sys.platform == "darwin"
                else platform.machine()
            ),
            "python": platform.python_version(),
            "packages": {
                p: importlib.metadata.version(p)
                for p in ("numpy", "tokenizers", "cmake")
            },
            "fixture_sha256": fixture_hash,
            "fixture_hash_format": "SHA-256 of UTF-8 json.dumps(fixture_spec, sort_keys=True, separators=(',', ':'))",
            "repetitions": repetitions,
            "threads": threads,
            "microbatch": microbatch,
            "n_gpu_layers": 999,
            "flash_attn": "auto",
            "gate": "max_abs_difference < 1e-3",
            "first_definition": "first request after a fresh scorer process; OS caches not controlled",
            "warm_definition": "same process, memory reset before every request; no prefix reuse across requests",
        },
        "fixture_spec": fixture_spec,
        "fixtures": fixtures,
        "records": [],
        "engines": [],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    partial = output.with_name(output.name + ".partial")
    with (CACHE / "inference.log").open("a") as log:
        for fixture in fixtures:
            for mode in ("individual", "exact", "batched"):
                print(
                    f"{fixture['id']} / {mode}: prefix={fixture['prefix_tokens']} tokens",
                    flush=True,
                )
                start = time.perf_counter()
                model = runtime.JevStyleDecisionGGUF(
                    model_dir=MODEL_DIR,
                    quant="Q4_K_M",
                    binary=CACHE / "bin" / "jev-score",
                    threads=threads,
                    n_ubatch=microbatch,
                    many_mode="exact" if mode == "individual" else mode,
                    stderr=log,
                )
                try:
                    calls = []
                    original_request = model._request

                    def traced_request(
                        request, original_request=original_request, calls=calls
                    ):
                        response = original_request(request)
                        if "questions" in request:
                            calls.append(
                                {
                                    "request": {
                                        "mode": request["mode"],
                                        "share_prefix": request["share_prefix"],
                                        "prefix_tokens": len(request["prefix"]),
                                        "question_count": len(request["questions"]),
                                    },
                                    "response": response,
                                }
                            )
                        return response

                    model._request = traced_request
                    info = model.info
                    for key, expected in {
                        "n_ctx": 32768,
                        "n_ubatch": microbatch,
                        "n_seq_max": 17,
                        "n_outputs_max": 256,
                    }.items():
                        if info.get(key) != expected:
                            raise ValueError(
                                f"unexpected scorer ready field {key}: {info.get(key)}"
                            )
                    report["engines"].append(
                        {
                            "fixture": fixture["id"],
                            "mode": mode,
                            "startup_ms": (time.perf_counter() - start) * 1000,
                            "ready": info,
                        }
                    )
                    for sample in range(repetitions + 1):
                        if model._request({"cmd": "reset"}) != {"ok": True}:
                            raise ValueError("scorer reset failed")
                        calls.clear()
                        start = time.perf_counter()
                        if mode == "individual":
                            results = [
                                model.decide(fixture["state"], q)
                                for q in fixture["questions"]
                            ]
                            timing = {"shared_tokens": 0}
                        else:
                            results = model.decide_many(
                                fixture["state"], fixture["questions"]
                            )
                            timing = dict(model.last_timing)
                        duration = (time.perf_counter() - start) * 1000
                        shared = observed_sharing(
                            calls,
                            mode,
                            fixture["prefix_tokens"],
                            len(fixture["questions"]),
                            microbatch,
                        )
                        report["records"].append(
                            {
                                "fixture": fixture["id"],
                                "mode": mode,
                                "phase": "first" if sample == 0 else "warm",
                                "sample": sample,
                                "duration_ms": duration,
                                "shared_tokens": shared,
                                "native_timing": timing,
                                "native_calls": list(calls),
                                "results": results,
                            }
                        )
                        partial.write_text(
                            json.dumps(report, indent=2, allow_nan=False) + "\n"
                        )
                finally:
                    model.close()
                    if model.proc.poll() is None:
                        model.proc.kill()
                    model.proc.wait(timeout=10)
                    model.proc.stdin.close()
                    model.proc.stdout.close()
    report["summary"] = summarize(report["records"], fixtures, repetitions, microbatch)
    report["metadata"]["finished_utc"] = datetime.now(timezone.utc).isoformat()
    # Exclusive creation prevents a parallel writer's finished report being replaced.
    with output.open("x") as stream:
        stream.write(json.dumps(report, indent=2, allow_nan=False) + "\n")
    partial.unlink()
    print(json.dumps(report["summary"], indent=2))
    return all(g["passes_gate"] for g in report["summary"]["gates"].values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--microbatch", type=int, default=1024)
    args = parser.parse_args()
    return (
        0
        if run(args.output.resolve(), args.repetitions, args.threads, args.microbatch)
        else 1
    )


if __name__ == "__main__":
    sys.exit(main())
