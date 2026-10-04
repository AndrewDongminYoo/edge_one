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

- Shared API tests failed on missing symbols before implementation, then passed;
  full `edge_one` suite: 230 passed. Shared contract commit: `88138d7`.
- Offline fitting tests failed on missing implementation; CLI tests observed the
  missing executable before implementation. Calibration package suite: 20 passed.
- Independent review found unbound Score legend semantics. Two regression tests
  reproduced the issue, then passed after canonical legend validation and dataset
  identity binding. No change to the runtime artifact schema was needed.
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
