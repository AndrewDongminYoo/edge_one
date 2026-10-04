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
