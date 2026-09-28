"""Render one verified desktop Choice request for the iOS spike."""

import hashlib
import importlib.util
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_report import validate_report
from setup import CACHE, HERE, MODEL_DIR, PINS, verify_model

IOS_CACHE = CACHE / "ios"


def native_fixture_header(fixture):
    request = fixture["native_request"]
    question = request["questions"][0]
    data = json.dumps(fixture, sort_keys=True, separators=(",", ":")).encode()
    lines = ["#pragma once", '#include "llama.h"']
    for name, values in (
        ("tokens", request["prefix"] + question["ids"]),
        ("slots", question["slots"]),
        ("rows", question["rows"]),
    ):
        lines.append(
            f"constexpr llama_token m0_{name}[] = {{{', '.join(map(str, values))}}};"
        )
    lines.append(
        f'constexpr char m0_fixture_hash[] = "{hashlib.sha256(data).hexdigest()}";'
    )
    lines.append(f'constexpr char m0_model_hash[] = "{fixture["model_sha256"]}";')
    return "\n".join(lines) + "\n"


def prepare():
    manifest = verify_model()
    fixture_spec = json.loads((HERE / "fixtures.json").read_text())
    report = json.loads(
        (HERE.parents[1] / "docs/notes/2026-09-27-m0-desktop.json").read_text()
    )
    validate_report(report, fixture_spec, PINS)
    module_spec = importlib.util.spec_from_file_location(
        "m0_renderer", MODEL_DIR / "jev_style_decision_gguf.py"
    )
    runtime = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(runtime)
    readout = json.loads((MODEL_DIR / "readout_config.json").read_text())
    renderer = runtime.Renderer(
        runtime.TextEncoder(MODEL_DIR / "tokenizer/tokenizer.json"), readout
    )
    case = fixture_spec["cases"][0]
    question = runtime.make_question(fixture_spec["questions"][0])
    rendered = renderer.render(case["state"], question)
    reference = next(
        r
        for r in report["records"]
        if r["fixture"] == case["id"] and r["mode"] == "individual" and r["sample"] == 0
    )["results"][0]
    fixture = {
        "pins": PINS,
        "model_sha256": manifest["files"][PINS["model"]]["sha256"],
        "state": case["state"],
        "question": fixture_spec["questions"][0],
        "option_names": rendered.names,
        "temperature": runtime.lookup_temperature(
            readout["temperatures"], None, question["t"], len(rendered.names)
        ),
        "native_request": {
            "prefix": rendered.ids[: rendered.prefix_len],
            "share_prefix": True,
            "keep_prefix": False,
            "mode": "fused",
            "questions": [
                {
                    "ids": rendered.ids[rendered.prefix_len :],
                    "slots": rendered.slots,
                    "rows": [renderer.yes, renderer.no],
                }
            ],
        },
        "reference": reference,
    }
    IOS_CACHE.mkdir(parents=True, exist_ok=True)
    data = json.dumps(fixture, sort_keys=True, separators=(",", ":")).encode()
    (IOS_CACHE / "fixture.json").write_bytes(data)
    (IOS_CACHE / "fixture.sha256").write_text(hashlib.sha256(data).hexdigest() + "\n")
    (IOS_CACHE / "fixture_tokens.hpp").write_text(native_fixture_header(fixture))
    print(
        f"Prepared Choice fixture: {len(rendered.ids)} tokens; SHA-256 {hashlib.sha256(data).hexdigest()}"
    )
    return fixture


if __name__ == "__main__":
    prepare()
