"""Compare redacted local-scorer and server response exports."""

import argparse
import json
import math
from pathlib import Path

from harness import compare


HASH_FIELDS = ("request_sha256", "token_ids_sha256")
METADATA_FIELDS = (
    ("model.id", lambda value: value["model"]["id"]),
    ("model.revision", lambda value: value["model"]["revision"]),
    ("scorer_revision", lambda value: value["scorer_revision"]),
    ("template_sha256", lambda value: value["template_sha256"]),
)


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
    ids = [request.get("id") for request in value["requests"]]
    if any(not identifier for identifier in ids) or len(ids) != len(set(ids)):
        raise ValueError(f"{expected_source} request IDs must be nonempty and unique")


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
            if local_request.get(field) != server_request.get(field):
                label = "token IDs" if field == "token_ids_sha256" else "request"
                raise ValueError(f"{label} hash mismatch for {identifier}")
        names = local_request.get("option_names")
        if names != server_request.get("option_names"):
            raise ValueError(f"option names differ for {identifier}")
        comparison = compare(names, local_request, server_request)
        differences = {
            name: server_request["probabilities"][name]
            - local_request["probabilities"][name]
            for name in names
        }
        if any(not math.isfinite(value) for value in differences.values()):
            raise ValueError(f"nonfinite probability difference for {identifier}")
        questions.append(
            {
                "id": identifier,
                "request_sha256": local_request["request_sha256"],
                "token_ids_sha256": local_request["token_ids_sha256"],
                "local_answer": local_request["answer"],
                "server_answer": server_request["answer"],
                "local_probabilities": local_request["probabilities"],
                "server_probabilities": server_request["probabilities"],
                "probability_differences": differences,
                **comparison,
            }
        )

    metadata_differences = [
        label for label, getter in METADATA_FIELDS if getter(local) != getter(server)
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
        "local_metadata": {label: getter(local) for label, getter in METADATA_FIELDS},
        "server_metadata": {label: getter(server) for label, getter in METADATA_FIELDS},
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
