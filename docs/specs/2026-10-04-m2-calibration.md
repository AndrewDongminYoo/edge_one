# Offline calibration

Issue #17 adds a Linux Dart CLI that fits per-question temperatures and
confidence thresholds using labeled cached System One responses. It performs no
inference, model downloads, or remote requests. Synthetic fixtures prove software
behavior; their metrics are not evidence of model quality.

## Data and split

Each JSONL line extends a version 1 RecordingBackend record with `model_sha256`
and `labels`, keyed by every question. Choice labels are option names, Noul labels
are booleans, and Score labels are legend keys. Score accuracy means modal-level
classification, not error in the response's expected numeric score.

Validate requests, responses, labels, model hashes, and stable question definitions
before fitting. Reject duplicate request digests and canonical duplicate
unredacted requests, including inconsistent labels. Redacted recordings require
trustworthy original request digests; identical redacted states do not identify
identical original requests.

The default recognizes the built-in `"[redacted]"` state marker. Custom redactors
use the explicit whole-input `redactedRequests: true` parser option or
`fit --redacted-requests` CLI flag. This skips stored-body canonical deduplication
while retaining original-digest uniqueness and every other validation. Producers
must preserve trustworthy pre-redaction digests and deduplicate originals before
redaction; the consumer cannot verify or deduplicate hidden originals. The strict
six-field JSONL format and report/artifact schemas remain unchanged. The option
changes which inputs are admitted, not the meaning or identity of admitted rows.

Sort request groups by SHA-256 of the seed and original request digest, then use
the first floor(N/2) requests for fitting and the remainder for validation. Never
split questions from one request across partitions. Require observations of every
question in both partitions. Input order must not affect results.

Fit a relative temperature on the fitting partition by minimizing mean
multiclass negative log likelihood. Transform cached probabilities as
`softmax(log(p)/T)`, preserving exact zeros. A zero probability assigned to a true
label cannot be repaired by temperature and is rejected with an explicit error.
Search bounded temperatures [0.05, 20]; include T=1 as a candidate so fitting does
not increase negative log likelihood. A relative temperature cannot reconstruct
raw model logits or undo prior probability rounding.

Choose each threshold from complete confidence tie groups on fitting data,
maximizing accepted count at empirical errors of 1%, 5%, and 10%. Report the
untouched validation partition at these fixed thresholds. The selected artifact
uses a requested target (default 5%). Empirical error is not a statistical bound
or a guarantee on future requests.

## Shared runtime artifact

`edge_one` owns the strict codec and probability helpers. The version 1 JSON is:

```json
{
  "version": 1,
  "model_sha256": "64 lowercase hexadecimal digits",
  "target_error": 0.05,
  "confidence": "normalized_max_probability",
  "questions": {
    "topic": { "type": "choice", "temperature": 1.0, "threshold": null }
  }
}
```

Only the specified fields are accepted. Temperatures must be positive and finite;
thresholds are null or finite [0,1]. Null always rejects, including confidence 1.
Confidence is `(K * max(p) - 1) / (K - 1)` (1 for a single category).
For Noul use `[1-p_yes,p_yes]`; this is routing confidence and adds no confidence
field to the Noul wire answer. Consumers apply temperature before comparing the
inclusive threshold. Lookup under a different model hash returns no calibration;
the router owns warnings and its conservative fallback policy.
The artifact is keyed by question name, not a question-definition fingerprint.
Callers must reuse the same instructions, criteria, and option meanings used in
calibration; changing a question requires recalibration even with the same model.

## Regression gate

The report records the selected artifact target error, data/split identity,
per-question counts and unfiltered
validation accuracy, and fit/validation accepted count, coverage, and error for
every target. Zero accepted items have null error. The check command compares
compatible reports and fails on accuracy loss, absolute coverage drift, or accepted
error increase beyond explicit absolute tolerances. Different model hashes are
allowed for intentional model upgrade comparisons; data, split, question, and
target changes fail closed. Score legend meanings are part of dataset identity.
No acceptance cannot masquerade as improved accuracy.

CI runs deterministic synthetic tests and the CLI against a committed baseline.
Tests explicitly prove failure on degraded accuracy and automation drift.
