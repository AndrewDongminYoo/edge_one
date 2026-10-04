# Offline calibration implementation plan

> For agentic workers: use superpowers:executing-plans for this delegated work.

**Goal:** Fit and validate offline calibration, export model-bound thresholds,
and detect regression with deterministic Linux tests.

**Architecture:** `edge_one` owns the reusable strict artifact codec and
probability transform. The CLI package owns JSONL validation, deterministic split,
fitting, held-out reports, file IO, and regression comparison.

**Tech Stack:** Dart 3.9+, existing crypto and test dependencies, args for CLI parsing.

**Spec:** `docs/specs/2026-10-04-m2-calibration.md`.

## Global constraints

- Cached responses only; no model downloads, credentials, or inference.
- Preserve System One wire format and zero probabilities.
- Require a clean `trunk check --no-fix` before any commit.
- Keep all changes in edge_one; publication belongs to the parent task.

## Review focus

- Duplicate or reordered records must not leak into validation.
- Tied confidence values must move through the gate as a whole group.
- Unseen question definitions and incorrect model identities fail closed.
- Empty accepted sets and malformed numeric values cannot pass drift checks.
- Score modal labels and Noul confidence semantics are explicit and tested.

## Task 1: shared runtime contract

Files: `packages/edge_one/lib/src/calibration.dart`, public export, and
`packages/edge_one/test/calibration_test.dart`.

- [x] Write tests for strict artifact parsing, mismatch lookup, null threshold,
      relative temperature, normalized confidence, and exact zero preservation.
- [x] Run the tests and capture the missing-feature failure.
- [x] Implement `CalibrationProfile`, `QuestionCalibration`,
      `calibrateProbabilities`, and `distributionConfidence`.
- [x] Run the new tests and the edge_one suite; analyze and format.

## Task 2: offline fitting and validation

Files: calibration package `lib/src/dataset.dart`, `lib/src/fitting.dart`,
`lib/src/report.dart`, `bin/edge_one_calibrate.dart`, exports and tests.

- [x] Write CLI regression tests for deterministic split, labels, tie selection,
      held-out independence, temperature NLL, and model binding.
- [x] Run the tests and capture the missing-feature failure.
- [x] Parse labeled recording JSONL; fit T and complete tie groups on fitting
      requests only; report held-out outcomes at 1/5/10% fixed targets.
- [x] Run the package suite and analyze both Dart packages.

## Task 3: drift gate and reproducible use

Files: calibration README, synthetic JSONL/baseline fixtures, regression tests,
and `.github/workflows/calibration.yml`.

- [x] Write tests for compatible baseline success, accuracy loss, automation
      drift, incompatible reports, malformed CLI input, and file safety.
- [x] Observe failures; implement strict `check` command and error exit codes.
- [x] Run CI commands locally; record actual results and any environment blocker.
- [x] Run `trunk check --no-fix`; commit only if clean, then hand off for review.

## Execution evidence

- Paired output review reproduced partial publication on a missing report parent
  and an existing report directory. Four actual CLI regressions failed first for
  absent/existing artifact cases. Deterministic I/O fault tests also reproduced
  replacement, symlink restoration, rollback, cleanup, and FIFO rejection gaps.
  The internal helper now stages both files, backs up prior entries, restores on
  synchronous failure, retains failed-recovery backups, and reports cleanup
  warnings after successful publication. Flags and numerical fixtures stay fixed.
  Follow-up review reproduced a directory-target link replacing another output's
  parent. CLI and helper regressions now reject directory links before mutation.

- Shared API tests failed on missing symbols before implementation, then passed;
  full `edge_one` suite: 230 passed. Shared contract commit: `88138d7`.
- Offline fitting tests failed on missing implementation; CLI tests observed the
  missing executable before implementation. Calibration package suite: 33 passed.
- Independent review found unbound Score legend semantics. Two regression tests
  reproduced the issue, then passed after canonical legend validation and dataset
  identity binding. No change to the runtime artifact schema was needed.
- Final review reproduced impossible aggregate/subset validation counts and a
  zero threshold claiming partial acceptance. Two new failing tests now pass
  after strict report consistency checks, without changing the report schema.
- Review also found that changing the selected deployment target could keep all
  report rows unchanged while switching from reject-all to accept-all. A test
  using actual fitted outputs reproduced it; reports now bind the selected
  `target_error`, and comparison rejects a change. The baseline gained only this
  metadata; recorded metric values remain unchanged.
- PR review reproduced acceptance disappearing within the coverage allowance
  (1/60 to zero with the default 0.02 tolerance). The regression now fails
  explicitly on missing candidate error evidence; unchanged empty sets still pass.
- PR review reproduced legitimate custom redactors collapsing distinct original
  requests to identical stored JSON. The real recorder regression and CLI opt-in
  tests failed first, then passed with `redactedRequests: true` / the
  `--redacted-requests` flag. Default canonical duplicate rejection, original
  digest uniqueness and all other validation remain in place. Tests cover the
  input option, deterministic reordering and unchanged identity of admitted rows;
  the committed fixture report and thresholds remain byte-identical.
- Both Dart analyses, formatting, lockfile enforcement, generated contract checks,
  and actual fixture CLI fit/check with zero drift tolerance pass on Linux using
  Flutter 3.47.5 / Dart 3.13.4.
- Initial Trunk tool-install failures were environment cache permissions, fixed
  by the parent task. Subsequent `trunk check --no-fix` passed before the shared
  contract commit and before the CLI handoff.

Ruling: the runtime artifact identifies a question by name; it does not add a
question-definition fingerprint in this version. Callers must reuse the calibrated
question definition and recalibrate if it changes. The CLI rejects definition
drift and report comparisons bind Score legend meanings.

Ruling: custom-redactor support is an explicit whole-input option, preserving the
six-field JSONL contract. Producers must supply trustworthy pre-redaction digests
and deduplicate originals before redaction. Enabling it for unredacted or mixed
inputs weakens canonical duplicate detection, so the default remains false.

## Task 4: approved versioned comparison identity sidecar

Files: new `lib/src/identity.dart` and `test/identity_test.dart`; dataset, fitting,
report, CLI, exports, README and separate v2 synthetic fixtures in calibration.

Interfaces: `comparisonRequestSha256(SystemOneRequest)`;
`CalibrationIdentitySidecar.fromRequests(Iterable<SystemOneRequest>)`,
`.parse(Object?)`, `.toJson()`; parser options `identitySidecar`,
`originalRequests: Map<String, SystemOneRequest>?`, `trustIdentitySidecar: false`.
CLI: `--identity-sidecar`, `--original-requests`, `--trust-identity-sidecar`.

- [x] Add real RecordingBackend recapture/refit regression across logical and
      physical model changes, and observe existing v1 incompatibility first.
- [x] Add digest golden/order/type/content, exact coverage, conflicts, semantic
      duplicates, mixed models, redacted collision/trust and raw integrity tests.
- [x] Implement producer and strict sidecar parser; verify originals in memory;
      bind v2 dataset identity and split to semantic digests with raw provenance.
- [x] Test v2 schema/split compatibility, v1 separation and CLI sidecar ingestion;
      implement report version validation and CLI options without tolerance edits.
- [x] Add a separate v2 baseline and documentation; retain v1 fixture bytes.
- [x] Run complete calibration/core suites, analyzers, format, lock/contracts,
      baseline CLI checks and Trunk; commit locally and report red/green evidence.

Review focus: hidden-original trust cannot prove content; order changes must
remain visible; duplicate raw/semantic associations fail closed; original hash
verification must precede migration; legacy reports cannot silently gain v2
semantics. The user approved this design and delegated native execution; no
additional design approval or subagent dispatch is required.

Task 4 execution evidence: actual RecordingBackend logical/physical recapture
failed first with `incompatible reports: dataset_sha256 differs`; expanded API
tests then failed on missing sidecar symbols. A separate v2 split-tampering test
failed by accepting swapped members before deterministic validation was added.
All 67 calibration and 230 core tests now pass, including real CLI recapture/refit
for unredacted and redacted recordings. Both analyzers, format, enforced lock,
schema/TypeScript/generated/Dart contract checks pass. Actual v1 CLI output/report
are byte-identical to the committed baseline and thresholds; v2 CLI matches its
separate reviewed baseline. The v2 fixture has 24 requests, 12 per partition,
10/12 accepted per question on validation at each target, zero accepted errors.
These synthetic figures demonstrate software behavior only. Hidden-original
producer trust remains an explicit assertion, never authentication.

Task 4 scoped review correction evidence (one grouped correction wave): two new
regressions failed before the fixes: shared raw digests could map to contradictory
semantic identities across individually valid reports, and reordering only label
keys changed dataset identity. V2 comparison now checks shared raw associations;
v2 dataset assembly sorts only label keys. Ordered request and Score legend
content remains unchanged. Both regressions and the real Recorder changed-model
positive path pass; the complete calibration suite now passes 69 tests.
The v2 baseline changes only `dataset_sha256` from
`eb2d102378f8e3166428d649b25de60fcf96756e16daa9e19fe6f7d50c757824` to
`830738e3161a1f409ed9c54231da129aabb642d4f33841bfe7c16c0aeb197c51`.
Split, metrics, provenance and threshold artifact bytes remain identical. Legacy
v1 CLI outputs still match their committed report and thresholds byte-for-byte.
Both analyzers, format, lock and contract checks pass; no additional review round
or changes to tolerances, runtime, or RecordingBackend are included.

## Task 5: approved additional hosted-findings correction pass

The user approved one additional bounded grouped pass, including migration of
120 invalid legacy synthetic hashes. Earlier review/fix counts remain consumed.
No additional subagents, reviewers or public actions belong to this task.

Files: `lib/src/identity.dart`, `lib/src/dataset.dart`, CLI/API trust documentation,
new `test/producer_validation_test.dart`, `test/support.dart`, affected request
mutators, legacy fixtures, README and this specification/plan.

- [x] Reproduce producer acceptance of hidden original instructions/criteria
      drift and legacy acceptance of incorrect raw hashes in failing regressions.
- [x] Validate ordered original question definitions per shared key in
      `CalibrationIdentitySidecar.fromRequests`; explicitly document producer
      trust obligations without adding fields or altering digest encoding.
- [x] Verify raw digests for every unhidden request; generate genuine hashes in
      test support and recompute them in tests targeting later invariants.
- [x] Migrate legacy input/report/threshold fixtures using identical content and
      seed; record old/new hashes, split and metric changes; verify v2 bytes fixed.
- [x] Run full calibration/core tests, analysis/format/lock/contracts/CLI checks;
      confirm Trunk exits 0 before a local Conventional Commit and evidence report.

Task 5 execution evidence: five feature-specific failures were observed before
production changes, covering hidden original instructions/criterion meanings,
ordered definitions, legacy raw integrity and the real CLI. All six focused tests
then passed, including stable hidden-original trust. The complete calibration
suite passes 76 tests and the core suite passes 230. Both analyses, formatting,
lock enforcement and all contract checks pass. Corrected legacy fixtures exactly
match the approved candidate files; only the 120 raw hash fields changed in the
input. The comparison-v2 input, sidecar, baseline and fitted artifact remain
byte-identical. See the [migration evidence](../notes/2026-10-04-calibration-integrity-migration.md)
for exact old/new hashes and numerical effects. The subset-consistency test now
constructs an impossible error count from its actual partition, and unredacted
request-mutator tests refresh raw digests to reach their intended later checks.
This is the single separately authorized additional pass; earlier review and
correction history remains consumed.
