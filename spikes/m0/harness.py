import hashlib
import math
import statistics


def compare(names, reference, candidate):
    if not names:
        raise ValueError("empty options")
    for result in (reference, candidate):
        probabilities = result.get("probabilities", {})
        if list(probabilities) != names:
            raise ValueError("result option order does not match the request")
        values = list(probabilities.values())
        if any(
            type(p) not in (int, float) or not math.isfinite(p) or not 0 <= p <= 1
            for p in values
        ):
            raise ValueError("invalid probability")
        if not math.isclose(sum(values), 1.0, rel_tol=0, abs_tol=1e-8):
            raise ValueError("probability sum is not one")
        if result.get("answer") != max(names, key=probabilities.get):
            raise ValueError("answer does not match distribution")
    difference = max(
        abs(reference["probabilities"][n] - candidate["probabilities"][n])
        for n in names
    )
    return {
        "max_abs_difference": difference,
        "top_choice_agrees": reference["answer"] == candidate["answer"],
        "passes_gate": difference < 1e-3,
    }


def compare_many(names, reference, candidate):
    if not names or len(names) != len(reference) or len(names) != len(candidate):
        raise ValueError("question count mismatch or empty question set")
    return [
        compare(n, r, c) for n, r, c in zip(names, reference, candidate, strict=False)
    ]


def verify_file(file, expected):
    digest = hashlib.sha256()
    with file.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected["sha256"]:
        raise ValueError(f"SHA-256 mismatch: {file}")
    if "bytes" in expected and file.stat().st_size != expected["bytes"]:
        raise ValueError(f"size mismatch: {file}")


def validate_fixtures(fixtures):
    if not fixtures:
        raise ValueError("empty fixture set")
    ids = set()
    for fixture in fixtures:
        if not fixture.get("id") or fixture["id"] in ids:
            raise ValueError("fixture ids must be nonempty and unique")
        ids.add(fixture["id"])
        if not fixture.get("questions"):
            raise ValueError("fixture must contain questions")


def observed_sharing(calls, mode, prefix_tokens, question_count, microbatch):
    expected_calls = question_count if mode == "individual" else 1
    if len(calls) != expected_calls:
        raise ValueError("native call count mismatch")
    native_mode = (
        "fused"
        if mode == "individual"
        else "sequential" if mode == "exact" else "batched"
    )
    shared = (
        0
        if mode == "individual"
        else (
            prefix_tokens
            if mode == "batched"
            else prefix_tokens // microbatch * microbatch
        )
    )
    expected_prefix = prefix_tokens if mode == "individual" else shared
    observed = []
    for call in calls:
        request, response = call["request"], call["response"]
        if response.get("mode") != native_mode or request["mode"] != native_mode:
            raise ValueError("unexpected native mode or fallback")
        if (
            response.get("n_prefix") != expected_prefix
            or request["prefix_tokens"] != expected_prefix
        ):
            raise ValueError("unexpected native prefix length")
        if response.get("prefix_reused") is not False:
            raise ValueError("unexpected native prefix reuse")
        if request["share_prefix"] != (mode == "individual" or shared > 0):
            raise ValueError("unexpected native sharing request")
        count = 1 if mode == "individual" else question_count
        if request["question_count"] != count or len(response["results"]) != count:
            raise ValueError("native question count mismatch")
        prefix_ms = response["timing"]["prefix_ms"]
        if (
            type(prefix_ms) not in (float, int)
            or not math.isfinite(prefix_ms)
            or prefix_ms < 0
            or (shared > 0 and prefix_ms == 0)
        ):
            raise ValueError("native prefix prefill was not observed")
        # The pinned scorer reports n_prefix and mode after its seq_cp branch succeeds.
        # It exposes no copy counter; this is an inference from its completed response.
        observed.append(
            response["n_prefix"]
            if mode != "individual" and request["share_prefix"]
            else 0
        )
    return observed[0]


def summarize(records, fixtures, repetitions, microbatch):
    if repetitions < 1 or microbatch < 1:
        raise ValueError("repetitions and microbatch must be positive")
    if not fixtures:
        raise ValueError("empty fixture set")
    modes = ("individual", "exact", "batched")
    expected = {
        (f["id"], mode, "first" if sample == 0 else "warm", sample)
        for f in fixtures
        for mode in modes
        for sample in range(repetitions + 1)
    }
    indexed = {(r["fixture"], r["mode"], r["phase"], r["sample"]): r for r in records}
    if len(indexed) != len(records) or set(indexed) != expected:
        raise ValueError("incomplete, duplicate, or unexpected record set")
    comparisons = {mode: [] for mode in modes[1:]}
    timings = []
    for fixture in fixtures:
        for mode in modes:
            samples = [
                indexed[(fixture["id"], mode, "first" if i == 0 else "warm", i)]
                for i in range(repetitions + 1)
            ]
            shared = (
                0
                if mode == "individual"
                else (
                    fixture["prefix_tokens"]
                    if mode == "batched"
                    else fixture["prefix_tokens"] // microbatch * microbatch
                )
            )
            for sample in samples:
                observed = observed_sharing(
                    sample["native_calls"],
                    mode,
                    fixture["prefix_tokens"],
                    len(fixture["option_names"]),
                    microbatch,
                )
                if observed != shared:
                    raise ValueError("unexpected native shared tokens")
                if sample["shared_tokens"] != shared:
                    raise ValueError(
                        f"unexpected shared tokens: {fixture['id']} / {mode}"
                    )
                duration = sample["duration_ms"]
                if (
                    type(duration) not in (int, float)
                    or not math.isfinite(duration)
                    or duration <= 0
                ):
                    raise ValueError("invalid duration")
                reference = indexed[
                    (fixture["id"], "individual", sample["phase"], sample["sample"])
                ]
                compared = compare_many(
                    fixture["option_names"], reference["results"], sample["results"]
                )
                if mode != "individual":
                    comparisons[mode].extend(
                        {
                            "fixture": fixture["id"],
                            "phase": sample["phase"],
                            "sample": sample["sample"],
                            "question": question,
                            **comparison,
                        }
                        for question, comparison in enumerate(compared)
                    )
            timings.append(
                {
                    "fixture": fixture["id"],
                    "mode": mode,
                    "shared_tokens": shared,
                    "first_request_ms": samples[0]["duration_ms"],
                    "warm_p50_ms": statistics.median(
                        s["duration_ms"] for s in samples[1:]
                    ),
                    "warm_samples": repetitions,
                }
            )
    return {
        "gates": {
            mode: {
                "max_abs_difference": max(c["max_abs_difference"] for c in compared),
                "top_choice_agreement_count": sum(
                    c["top_choice_agrees"] for c in compared
                ),
                "compared_questions": len(compared),
                "passes_gate": all(c["passes_gate"] for c in compared),
                "worst_comparison": max(
                    compared, key=lambda c: c["max_abs_difference"]
                ),
            }
            for mode, compared in comparisons.items()
        },
        "timings": timings,
    }
