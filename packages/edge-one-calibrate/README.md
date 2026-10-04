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

Both output parents must already exist. `fit` serializes and stages the artifact
and report before replacing either destination. Only regular files, non-directory
links, or absent destinations are accepted. Existing links are replaced as
entries; their targets are not overwritten. On a synchronous publication failure, the command
restores prior entries and removes newly created outputs. If restoration fails,
the file error identifies retained recovery directories containing backups.

Once both outputs are published, a cleanup failure prints a warning with the
remaining directory path and leaves the installed pair in place (exit 0). This
is not a crash-atomic transaction. Use exclusive destination paths: concurrent
writers or directory changes are outside the rollback guarantee.

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

## Comparing changed logical model names (report v2)

Opt in to a versioned **comparison identity sidecar** for model upgrades that
change `request.model`. The producer computes it from validated original requests
before redaction, alongside its existing RecordingBackend capture:

```dart
final sidecar = CalibrationIdentitySidecar.fromRequests(originalRequests);
final sidecarJson = sidecar.toJson(); // Persist only these digest pairs.
final dataset = CalibrationDataset.parse(
  labeledJsonl,
  modelSha256: physicalModelHash,
  identitySidecar: CalibrationIdentitySidecar.parse(sidecarJson),
);
```

The sidecar contains exactly `version: 1`,
`identity_scheme: "system-one-request-excluding-model-v1"`, and `associations`:

```json
{
  "version": 1,
  "identity_scheme": "system-one-request-excluding-model-v1",
  "associations": [
    {
      "request_sha256": "64 lowercase hexadecimal digits",
      "comparison_sha256": "64 lowercase hexadecimal digits"
    }
  ]
}
```

`comparisonRequestSha256(original)` hashes UTF-8 of
`edge-one-calibrate:system-one-request-excluding-model-v1\n` followed by the
ordered typed JSON encoding with **only top-level `model` removed**. Nested
`model` fields, state, questions, instructions, criteria, typed scalars, Unicode,
mapping order, Choice option order and arrays remain significant. No sorting,
normalization, trimming or coercion occurs. Generate one association per original;
duplicate raw or semantic digests, conflicts and missing/extra entries fail.
A dataset must use one logical model name and one physical model hash.

Unredacted input verifies both digests. For redacted input either supply
`originalRequests: {rawDigest: originalRequest}` in memory (exact coverage,
verifying both digests), or explicitly assert trusted producer provenance with
`trustIdentitySidecar: true`. The latter cannot authenticate hidden originals.
Custom redactors additionally require `redactedRequests: true`; default state
redaction is detected automatically. Trust never skips verification of available
originals or unredacted bodies. CLI equivalents are:

```sh
dart run bin/edge_one_calibrate.dart fit \
  --input test/fixtures/comparison-labeled.jsonl \
  --identity-sidecar test/fixtures/comparison-sidecar.json \
  --model-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --output /tmp/comparison-thresholds.json --report /tmp/comparison-report.json

dart run bin/edge_one_calibrate.dart check \
  --baseline test/fixtures/comparison-baseline-report.json \
  --report /tmp/comparison-report.json \
  --max-accuracy-drop 0 --max-coverage-drift 0 --max-error-increase 0
```

For hidden originals add `--trust-identity-sidecar`, or use
`--original-requests /private/originals.json` to read an existing JSON array of
original requests locally. No original content is written by the CLI or helper.
Input, sidecar and originals paths must differ from both output paths, including
resolved symlink aliases. Digests expose equality and can permit dictionary
matching; neither recordings nor digest pairs are anonymization.

V2 reports explicitly declare `identity_scheme` and
`split_scheme: "sha256-seed-comparison-v1"`. They bind ordered comparison digests,
labels and Score legends in dataset identity, rank semantic digests by
SHA-256 of UTF-8 `seed:digest`, and put those digests in the split lists. Raw
associations remain in `provenance` for inspection and are excluded from report
comparison equality; any raw digest shared across compared reports must still
map to the same semantic digest. Label keys alone are sorted when assembling v2
dataset identity, so label insertion order does not change identity. Ordered
request content and Score legends remain significant. Parsing checks exact
provenance coverage and seeded split
membership. The runtime thresholds artifact remains version 1 and strictly bound
to the physical model hash. Thresholds and drift tolerances are unchanged.

Without a sidecar, fitting still emits **legacy v1** reports: dataset identity
includes raw hashes and stored request bodies (including logical model name),
and split membership uses raw hashes. V1 can compare physical revisions only
while those inputs stay identical. Redacted v1 cannot recover model-independent
identity without originals or a trusted producer sidecar. V1/v2 comparisons and
unknown schemes fail closed. The original fixture and baseline are unchanged;
`tool/update_fixture.dart --comparison` regenerates only the separate 24-request
synthetic comparison input and sidecar. Baselines still require manual review.
