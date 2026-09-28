"""Compare redacted local-scorer and server response exports."""

import argparse
import json
import math
import re
from pathlib import Path

from harness import compare


HASH_FIELDS = ("request_sha256", "token_ids_sha256")
METADATA_FIELDS = (
    ("model.id", lambda value: value["model"]["id"]),
    ("model.revision", lambda value: value["model"]["revision"]),
    ("scorer_revision", lambda value: value["scorer_revision"]),
    ("template_sha256", lambda value: value["template_sha256"]),
    ("readout_config_sha256", lambda value: value["readout_config_sha256"]),
)
SHA256_PATTERN = re.compile(r"[0-9a-fA-F]{64}")


def _require_sha256(value, source, field, request_id=None):
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        location = f" for {request_id}" if request_id else ""
        raise ValueError(f"invalid {source} {field}{location}")


def _metadata(value):
    return {
        label: field.lower() if label.endswith("_sha256") else field
        for label, getter in METADATA_FIELDS
        for field in (getter(value),)
    }


def _ordered_result(result, names, source, request_id):
    probabilities = result.get("probabilities")
    if not isinstance(probabilities, dict) or set(probabilities) != set(names):
        raise ValueError(f"{source} probability options differ for {request_id}")
    return {
        "answer": result.get("answer"),
        "probabilities": {name: probabilities[name] for name in names},
    }


def _validate_export(value, expected_source):
    if value.get("schema_version") != 1 or value.get("source") != expected_source:
        raise ValueError(f"invalid {expected_source} export header")
    if not value.get("requests"):
        raise ValueError(f"empty {expected_source} request set")
    for label, getter in METADATA_FIELDS:
        try:
            field = getter(value)
        except (KeyError, TypeError) as error:
            raise ValueError(f"missing {expected_source} metadata: {label}") from error
        if not isinstance(field, str) or not field:
            raise ValueError(f"invalid {expected_source} metadata: {label}")
    for field in ("template_sha256", "readout_config_sha256"):
        _require_sha256(value[field], expected_source, field)
    ids = [request.get("id") for request in value["requests"]]
    if any(not identifier for identifier in ids) or len(ids) != len(set(ids)):
        raise ValueError(f"{expected_source} request IDs must be nonempty and unique")
    for request in value["requests"]:
        for field in HASH_FIELDS:
            _require_sha256(
                request.get(field), expected_source, field, request_id=request["id"]
            )


def compare_exports(local, server):
    """Return a redacted probability comparison for two versioned exports."""
    _validate_export(local, "local")
    _validate_export(server, "server")
    local_requests = {request["id"]: request for request in local["requests"]}
    server_requests = {request["id"]: request for request in server["requests"]}
    if local_requests.keys() != server_requests.keys():
        raise ValueError("local and server request IDs differ")

    questions = []
    for identifier, local_request in local_requests.items():
        server_request = server_requests[identifier]
        for field in HASH_FIELDS:
            if local_request[field].lower() != server_request[field].lower():
                label = "token IDs" if field == "token_ids_sha256" else "request"
                raise ValueError(f"{label} hash mismatch for {identifier}")
        names = local_request.get("option_names")
        if names != server_request.get("option_names"):
            raise ValueError(f"option names differ for {identifier}")
        if (
            not isinstance(names, list)
            or not names
            or any(not isinstance(name, str) or not name for name in names)
            or len(names) != len(set(names))
        ):
            raise ValueError(f"invalid option names for {identifier}")
        local_result = _ordered_result(local_request, names, "local", identifier)
        server_result = _ordered_result(server_request, names, "server", identifier)
        comparison = compare(names, local_result, server_result)
        differences = {
            name: server_result["probabilities"][name]
            - local_result["probabilities"][name]
            for name in names
        }
        if any(not math.isfinite(value) for value in differences.values()):
            raise ValueError(f"nonfinite probability difference for {identifier}")
        questions.append(
            {
                "id": identifier,
                "request_sha256": local_request["request_sha256"].lower(),
                "token_ids_sha256": local_request["token_ids_sha256"].lower(),
                "local_answer": local_result["answer"],
                "server_answer": server_result["answer"],
                "local_probabilities": local_result["probabilities"],
                "server_probabilities": server_result["probabilities"],
                "probability_differences": differences,
                **comparison,
            }
        )

    local_metadata = _metadata(local)
    server_metadata = _metadata(server)
    metadata_differences = [
        label
        for label in local_metadata
        if local_metadata[label] != server_metadata[label]
    ]
    attribution = (
        "runtime_difference"
        if not metadata_differences
        else "server_model_or_configuration_difference"
    )
    return {
        "schema_version": 1,
        "attribution": attribution,
        "metadata_differences": metadata_differences,
        "local_metadata": local_metadata,
        "server_metadata": server_metadata,
        "questions": questions,
        "summary": {
            "compared_questions": len(questions),
            "max_abs_difference": max(q["max_abs_difference"] for q in questions),
            "top_choice_agreement_count": sum(q["top_choice_agrees"] for q in questions),
            "passes_gate": all(q["passes_gate"] for q in questions),
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("local", type=Path, help="redacted local scorer export")
    parser.add_argument("server", type=Path, help="redacted server export")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite report: {args.output}")
    report = compare_exports(
        json.loads(args.local.read_text()), json.loads(args.server.read_text())
    )
    with args.output.open("x") as stream:
        stream.write(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps(report["summary"], indent=2))
    return 0 if report["summary"]["passes_gate"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
