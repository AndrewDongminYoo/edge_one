# M1 Native Verdict Scoring Implementation Plan

> Execute inline using superpowers:executing-plans and regression-first tests.

**Goal:** Implement #9's pinned individual and exact verdict scorer.

**Architecture:** Keep the existing private Backend and C ABI. Build-time manifest
constants anchor runtime identity. A model-independent decoder interface supports
one tested scheduling/readout implementation and a llama.cpp adapter. A private
JSONL executable uses that same production code for fresh-reference parity.

**Tech Stack:** C++17, CMake, pinned llama.cpp/SHA-256, Python unittest.

**Spec:** `docs/specs/2026-10-04-m1-verdict-scoring.md`.

## Global constraints

Use context=manifest budget, batch=budget, microbatch=min(1024,batch), two sequences,
unified KV, 26 output rows, two CPU threads. No persistent cache or batched mode.
No local model download. Parent owns publication; Trunk must pass before local commits.

## Review focus

- Changed runtime model/readout must fail even when the file matches that change.
- Relative verdict indices must map to the correct sparse batch logits.
- Recurrent prefix state must never contain the unshared tail before copying.
- Partial abort/decode state must not survive into the next request.
- Parity must reject token/profile/fixture drift and report missing inputs honestly.

## Tasks

- [x] Add failing `integrity_test.cpp`: known SHA-256 vector, same-size byte
      mutation, size mismatch, each changed identity/readout field, raised/reduced
      limits and mirror-only changes. Implement `validate_pinned_manifest` and
      `verify_model_file` in `integrity.{hpp,cpp}`, generated `pinned_manifest.hpp`,
      and call them before native model load. Run native CTest.
- [x] Add failing `scorer_test.cpp`: stable readout, nonfinite values, exact
      boundary cases, sparse slot mapping, full branch isolation, single/individual
      prefill, cancellation/error cleanup and reuse. Implement `scorer.{hpp,cpp}`
      with a `Decoder` interface, `ScoreMode`, `ScoreDiagnostics`, `score_request`,
      and the llama adapter in `llama_backend.cpp`. Run native CTest and sanitizers.
- [x] Add failing Python parity-check tests. Implement opt-in `score_driver.cpp`
      against the production backend, `tools/check_native_parity.py` using the
      existing M0 fixtures/verified runtime, fresh reports, strict token/probability
      checks and observed sharing. Add the CI step after the existing pinned fetch,
      document usage, and run model-free Python/native suites and Trunk.

## Execution evidence

Record red/green results and rulings in `/tmp/edge-one-scorer9-progress.md`. Actual
model measurements are a separate CI acceptance result, never a unit-test claim.

## Approved continuation: fixed reference profile

Existing review/fix counts carry forward. Execute inline; parent owns any review
and publication. This continuation is already user-approved.

Files: new `tools/build_parity_reference.py`,
`spikes/m0/tests/test_parity_reference.py`; modify `tools/check_native_parity.py`,
its tests, CI, README and this spec/plan. No production inference changes.

Interface: helper `build(jobs)`, `verify_reference(profile)`,
`inspect_build(build)` and `loaded_artifacts(pid, expected)`; CLI build/verify
with explicit profile. Harness requires profile and production build paths.
Helper returns verified runtime, manifest, receipt and isolated scorer path.

- [x] Write and observe RED tests for profile selection, isolated paths, cache/
      flag/receipt drift, missing or mutated artifacts, unsupported host and
      actual process mappings; preserve strict gate and historical failure test.
- [x] Implement independent build from verified pinned source/scorer, explicit
      CPU/common settings, effective flag checks, compiler identity, complete
      receipt verification and loaded-artifact checks. Run Python suite GREEN.
- [x] Integrate explicit selection and evidence into parity harness and CI;
      preserve native M0 defaults. Verify Python suite, Release/sanitizer CTest,
      archived evidence, then one full real-model run using only existing model.
- [x] Record hashes, commands/results and limitations; Trunk --no-fix must pass
      before one conventional local commit. Parent handles publication.

Review focus: omitted receipt artifacts; symlink escape/collision with M0 paths;
injected native/AVX512 flags despite safe cache; alternate loaded libraries;
unsupported host or profile. Each is covered by the new regression suite.

Continuation evidence: `docs/notes/2026-10-04-fixed-reference-parity.md` and
`/tmp/edge-one-fixed-reference-implementation-report.json`. Full fixed-profile
run passed 24 comparisons with maximum 5.551115123125783e-17; the historical
cross-profile failure remains preserved.
