"""Validate an archived desktop report without loading the model."""

import argparse
import hashlib
import json
from pathlib import Path

from harness import summarize


def validate_report(report, fixture_spec, pins):
    if report["fixture_spec"] != fixture_spec:
        raise ValueError("archived fixture spec differs from current inputs")
    digest = hashlib.sha256(
        json.dumps(fixture_spec, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    metadata = report["metadata"]
    if metadata["fixture_sha256"] != digest:
        raise ValueError("canonical fixture hash mismatch")
    if metadata["pins"] != pins or metadata["build"]["pins"] != pins:
        raise ValueError("archived pins differ from current inputs")
    summary = summarize(
        report["records"],
        report["fixtures"],
        metadata["repetitions"],
        metadata["microbatch"],
    )
    stored_summary = report["summary"]
    comparable_summary = json.loads(json.dumps(summary))
    # Reports created before drift localization was added have the same gates but
    # no coordinate for their worst comparison. Keep those pinned measurements
    # verifiable while requiring exact agreement for every field they contain.
    for mode, gate in stored_summary.get("gates", {}).items():
        if "worst_comparison" not in gate:
            comparable_summary["gates"][mode].pop("worst_comparison", None)
    if comparable_summary != stored_summary:
        raise ValueError("stored summary differs from raw measurements")
    if not all(gate["passes_gate"] for gate in summary["gates"].values()):
        raise ValueError("archived probability comparison failed")
    return stored_summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    summary = validate_report(
        json.loads(args.report.read_text()),
        json.loads((here / "fixtures.json").read_text()),
        json.loads((here / "pins.json").read_text()),
    )
    print(json.dumps(summary["gates"], indent=2))


if __name__ == "__main__":
    main()
