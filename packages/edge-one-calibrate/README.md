# edge-one-calibrate

Fit a model-bound temperature and confidence gate from labeled **cached** System
One responses, and report held-out local coverage at 1%, 5%, and 10% target error.
This package performs no inference, downloads, or remote calls.

**Score accuracy is modal-level classification against legend keys**, not error
in the expected numeric score. Noul predicts true at `noul >= 0.5`. Choice retains
the cached choice (which must have maximum probability); Score ties use the first
legend key in lexicographic order. Noul routing confidence is derived from its
binary distribution; its wire answer still has no confidence field.

From the repository root, restore the pinned workspace with
`flutter pub get --enforce-lockfile`, then:

```sh
cd packages/edge-one-calibrate
dart run bin/edge_one_calibrate.dart fit \
  --input test/fixtures/labeled.jsonl \
  --model-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --output /tmp/thresholds.json --report /tmp/calibration-report.json

dart run bin/edge_one_calibrate.dart check \
  --baseline test/fixtures/baseline-report.json \
  --report /tmp/calibration-report.json \
  --max-accuracy-drop 0.01 --max-coverage-drift 0.02 --max-error-increase 0.01
```

`fit --seed 0` reproducibly sorts request digests by a seeded SHA-256, then assigns
the first half to fitting and the remainder to validation. All questions from one
request stay together. `--target-error 0.05` selects the artifact's gate; the report
also includes all three default targets. A nondefault target adds a report row.
Changing validation labels never changes fitted temperatures or thresholds.

## Labeled cache format

Each JSONL object extends a version 1 `RecordingBackend` line with `model_sha256`
and `labels`. The recording's request, original request digest, and response stay
intact. Use the same verified model hash that the recording producer used.

```json
{
  "version": 1,
  "request_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "model_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "request": {
    "state": "Synthetic example",
    "model": "synthetic",
    "questions": { "flag": { "type": "noul" } }
  },
  "response": {
    "model": "synthetic",
    "answers": { "flag": { "type": "noul", "noul": 0.8 } },
    "usage": { "input_tokens": 0, "output_tokens": 0 }
  },
  "labels": { "flag": true }
}
```

Flatten this object to one line for JSONL. The displayed digest is synthetic;
real records must carry the original recording digest. Choice labels are option
names, Score labels are legend keys, and Noul labels are booleans. Every question
needs exactly one label and observations in both partitions. Each question key
must keep the same instructions, criteria, and Score legend meanings.

Duplicate original digests are rejected, as are canonical duplicate unredacted
requests under different digests. Redacted states cannot identify original
requests: the producer must preserve trustworthy original request digests.
Recording a redacted state is not complete anonymization. Commit synthetic data
only; keep sensitive production recordings out of Git.

The built-in `"[redacted]"` state marker is recognized by default. For a custom
`RecordingBackend` redactor, opt in with `fit --redacted-requests` or
`CalibrationDataset.parse(..., redactedRequests: true)`. This is a producer
assertion for the **whole input**, allowing identical stored requests under
distinct trusted pre-redaction `request_sha256` values. It does not add fields to
the six-field JSONL format or change the report/artifact schema.

The option skips canonical deduplication of stored request bodies. Duplicate
original digests and model, schema, label, question, legend, and split checks still
apply. The producer must deduplicate original requests before redaction: hidden
originals cannot be verified or canonically deduplicated by this tool. Use the
default for unredacted inputs; enabling this option for unredacted or mixed inputs
weakens their duplicate checks.

## Temperature and thresholds

Temperature minimizes fitting negative log likelihood over `[0.05, 20]` using
deterministic bisection in inverse temperature. It is a **relative multiplier**:
the transform is `softmax(log(p) / T)` on the cached backend probabilities, not
raw logits. Exact zeros stay zero; a zero-probability true label is rejected
because temperature cannot repair it. Rounded probabilities are normalized
within the System One codec's sum tolerance.

Confidence is `(K * max(p) - 1) / (K - 1)` after temperature scaling; one category
has confidence 1. The threshold accepts complete tie groups with `confidence >=
threshold`, maximizing fitting coverage at each empirical target. Null means
accept nothing, including confidence 1. Validation is evaluated at these fixed
thresholds and may exceed the target error. The report includes denominators and
null error when no observations were accepted. Small samples and distribution
shift limit any empirical result; no future-error guarantee is implied.

`thresholds.json` uses `CalibrationProfile` from `edge_one`:

```dart
final profile = CalibrationProfile.fromJson(jsonDecode(assetText));
final gate = profile.forQuestion('topic', modelSha256: loadedModelHash);
if (gate != null) {
  final p = calibrateProbabilities(cachedProbabilities, gate.temperature);
  final acceptLocally = gate.accepts(distributionConfidence(p));
}
```

An unknown question or different model hash returns no calibration; the router
owns its warning and conservative fallback. The artifact does not fingerprint
question definitions: reuse the exact instructions, criteria, and option meanings
used in calibration, and recalibrate when they change. See the
[versioned artifact specification](../../docs/specs/2026-10-04-m2-calibration.md).

## Regression checks

`check` requires the same dataset identity, split, question types, counts, reported
targets, and selected deployment `target_error`. Dataset identity covers requests,
labels, original digests, and Score
legend meanings; it excludes predicted probabilities and the model hash, enabling
comparison of model revisions on the same input records.

Tolerances are absolute fractions: `0.01` is one percentage point. The command
fails on validation accuracy loss, coverage drift in either direction, or accepted
error increase. Changing between zero and nonzero acceptance fails closed even
within the coverage allowance; two unchanged empty accepted sets remain comparable
with unknown error. Invalid or incompatible reports also fail rather than skipping
questions. Exit codes: 0 pass, 1 regression,
64 usage, 65 invalid data, 74 file error.

## Synthetic CI evidence

The committed 120-request, three-question fixture checks software behavior only.
It says nothing about a real model's quality. CI runs unit/integration tests plus
the actual `fit` and `check` commands against `test/fixtures/baseline-report.json`
with zero drift allowance. The tests prove both passing and failing gate behavior.
Model upgrades require newly cached responses on the same labeled requests; this
workflow does not fetch or evaluate a model automatically.

Regenerate the deterministic synthetic input with
`dart run tool/update_fixture.dart`. Update a baseline only after reviewing why
its metrics changed; normal tests and CI never rewrite it.
