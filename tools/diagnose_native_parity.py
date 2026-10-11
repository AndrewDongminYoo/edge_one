"""Bounded Linux diagnostic: swap llama libraries without changing the parity gate."""

import argparse
import json
import math
import os
import subprocess
import sys
import threading
from contextlib import contextmanager
from pathlib import Path

from check_native_parity import MANIFEST, ROOT, check_fixture_spec, sha256


def diagnostic_cases(reference, driver, native_libraries, portable_libraries):
    return [
        ("A", reference, native_libraries, "upstream"),
        ("B", reference, portable_libraries, "upstream"),
        ("C", driver, portable_libraries, "production"),
        ("D", driver, native_libraries, "production"),
    ]


def check_libraries(paths, expected_directory):
    if not paths or not any(Path(path).name.startswith("libllama") for path in paths):
        raise ValueError("missing loaded llama library evidence")
    if not any(Path(path).name.startswith("libggml") for path in paths):
        raise ValueError("missing loaded ggml library evidence")
    if any(
        Path(path).resolve().parent != expected_directory.resolve() for path in paths
    ):
        raise ValueError("incomplete library override: mixed native/portable libraries")


def failed_gate_evidence(path):
    error = json.loads(path.read_text()).get("error")
    if not isinstance(error, str) or not error.startswith(
        "strict probability parity failed:"
    ):
        raise ValueError("diagnostic requires a preserved strict probability failure")
    return {"error": error, "sha256": sha256(path), "strict_gate_passed": False}


def write_report(output, report):
    output.seek(0)
    json.dump(report, output, indent=2, allow_nan=False)
    output.write("\n")
    output.truncate()
    output.flush()


def loaded_library_paths(pid):
    return sorted(
        {
            line.split(maxsplit=5)[-1].strip()
            for line in Path(f"/proc/{pid}/maps").read_text().splitlines()
            if "/libllama" in line or "/libggml" in line
        }
    )


@contextmanager
def bounded_process(command, environment, log, timeout):
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=log,
        text=True,
        env=environment,
    )
    expired = threading.Event()

    def expire():
        expired.set()
        process.kill()

    watchdog = threading.Timer(timeout, expire)
    watchdog.daemon = True
    watchdog.start()
    try:
        yield process
    except Exception as error:
        if expired.is_set():
            raise TimeoutError(f"diagnostic case exceeded {timeout} seconds") from error
        raise
    finally:
        watchdog.cancel()
        watchdog.join()
        if process.poll() is None:
            process.kill()
        process.wait(timeout=10)
        for stream in (process.stdin, process.stdout):
            try:
                stream.close()
            except BrokenPipeError:
                pass
    if expired.is_set():
        raise TimeoutError(f"diagnostic case exceeded {timeout} seconds")


def run_case(
    binary,
    libraries,
    kind,
    model,
    request,
    rendered,
    readout,
    log,
    *,
    result,
    save,
    timeout=120,
):
    arguments = (
        [str(model), str(MANIFEST), "individual"]
        if kind == "production"
        else [
            "--model",
            str(model),
            "--ngl",
            "0",
            "--threads",
            "2",
            "--n-ctx",
            "32768",
            "--n-ubatch",
            "1024",
            "--n-seq-max",
            "17",
            "--n-outputs-max",
            "256",
        ]
    )
    environment = dict(os.environ, LD_LIBRARY_PATH=str(libraries))
    result.update(
        binary_sha256=sha256(binary),
        expected_libraries=str(libraries),
        timeout_seconds=timeout,
    )
    save()
    try:
        with bounded_process(
            [str(binary), *arguments], environment, log, timeout
        ) as process:
            result["pid"] = process.pid
            save()
            ready = json.loads(process.stdout.readline())
            result["ready"] = ready
            save()
            if not ready.get("ready"):
                raise ValueError(f"diagnostic process did not become ready: {ready}")
            paths = loaded_library_paths(process.pid)
            result["loaded_libraries"] = {path: sha256(Path(path)) for path in paths}
            save()
            check_libraries(paths, libraries)

            def query(value):
                process.stdin.write(json.dumps(value) + "\n")
                process.stdin.flush()
                response = json.loads(process.stdout.readline())
                if kind == "production":
                    result["raw"] = response
                else:
                    result["raw"].append(response)
                save()
                if "error" in response:
                    raise ValueError(response["error"])
                return response

            if kind == "production":
                result["probabilities"] = query(request)["distributions"]
                save()
            else:
                result["raw"], result["probabilities"] = [], []
                for question in rendered:
                    response = query(
                        {
                            "prefix": question.ids[: question.prefix_len],
                            "share_prefix": True,
                            "keep_prefix": False,
                            "mode": "fused",
                            "questions": [
                                {
                                    "ids": question.ids[question.prefix_len :],
                                    "slots": question.slots,
                                    "rows": [9542, 874],
                                }
                            ],
                        }
                    )
                    scores = [
                        (yes - no) / readout["temperatures"]["global"]
                        for yes, no in response["results"][0]["scores"]
                    ]
                    probabilities = [math.exp(score - max(scores)) for score in scores]
                    result["probabilities"].append(
                        [value / sum(probabilities) for value in probabilities]
                    )
                    save()
        return result
    except Exception as error:
        result["error"] = str(error)
        save()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--failed-gate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    evidence = failed_gate_evidence(args.failed_gate)
    sys.path.insert(0, str(ROOT / "spikes/m0"))
    from run import load_runtime
    from setup import CACHE, MODEL_DIR, PINS, SOURCE, verify_source

    runtime, _, receipt = load_runtime()
    verify_source()
    specification = json.loads((ROOT / "spikes/m0/fixtures.json").read_text())
    check_fixture_spec(specification)
    state = specification["cases"][0]["state"]
    readout = json.loads((MODEL_DIR / "readout_config.json").read_text())
    renderer = runtime.Renderer(
        runtime.TextEncoder(MODEL_DIR / "tokenizer/tokenizer.json"), readout
    )
    rendered = [
        renderer.render(state, question) for question in specification["questions"]
    ]
    request = {
        "state": state,
        "model": "jev-style-0.8b-decision-v3",
        "questions": {
            str(index): {
                "type": question["t"],
                "instructions": question["ins"],
                **({"criteria": question["crit"]} if "crit" in question else {}),
            }
            for index, question in enumerate(specification["questions"])
        },
    }
    driver = args.driver.resolve()
    report = {
        "diagnostic_only": True,
        "original_gate": evidence,
        "pins": PINS,
        "reference_build": receipt,
        "fixture": "structured-short",
        "cases": {},
    }
    # Exclusive creation prevents this tool from replacing an acceptance report.
    with args.output.open("x") as output, args.output.with_suffix(".stderr").open(
        "x"
    ) as log:

        def save():
            write_report(output, report)

        save()
        try:
            for name, binary, libraries, kind in diagnostic_cases(
                CACHE / "bin/jev-score",
                driver,
                SOURCE / "build/bin",
                driver.parent / "bin",
            ):
                report["cases"][name] = {}
                save()
                run_case(
                    binary,
                    libraries,
                    kind,
                    MODEL_DIR / PINS["model"],
                    request,
                    rendered,
                    readout,
                    log,
                    result=report["cases"][name],
                    save=save,
                )
            report["max_probability_differences"] = {
                f"{left}-{right}": max(
                    abs(a - b)
                    for x, y in zip(
                        report["cases"][left]["probabilities"],
                        report["cases"][right]["probabilities"],
                        strict=True,
                    )
                    for a, b in zip(x, y, strict=True)
                )
                for left, right in (
                    ("A", "B"),
                    ("C", "D"),
                    ("B", "C"),
                    ("A", "D"),
                    ("A", "C"),
                )
            }
        except Exception as error:
            report["diagnostic_error"] = str(error)
            raise
        finally:
            save()


if __name__ == "__main__":
    main()
