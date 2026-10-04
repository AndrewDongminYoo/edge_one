# M1 Native Core Implementation Plan

> Execute inline using superpowers:executing-plans and regression-first tests.

**Goal:** Implement issue #8's stable native ABI, validation and renderer.

**Architecture:** Keep JSON validation/rendering independent of llama.cpp. A
private backend owns tokenizer/model/context resources; the C wrapper owns
cancellation, status mapping and returned memory. #9 supplies production scoring.

**Tech Stack:** C++17, CMake, pinned llama.cpp and its nlohmann ordered JSON header.

**Spec:** `docs/specs/2026-10-04-m1-native-core.md`.

## Global constraints

Preserve the blueprint ABI, M0 source pin and bundled manifest. Do not fetch model
weights, implement batched sharing or change calibration. Run `trunk check
--no-fix` clean before any commit; commits and PR publication are parent-owned.

## Review focus

Check duplicate keys, integer overflow, invalid UTF-8, cancel/evaluate races, and
model lifetime on exceptions. Never treat a fake backend as inference evidence.

## Tasks

- [x] Add failing schema/local-limit/manifest and renderer tests under
      `packages/edge_one_core/tests`. Reuse the shared wire fixtures and allow local
      rejection only for empty Choice and single Score levels. Implement private
      request and manifest validation plus escaped segmented rendering, token and
      slot accounting. Verify with the native test executable.
- [x] Add failing C ABI tests for null arguments, open failure, owned memory,
      concurrent evaluation, cancel/reset and cancel-join-close ownership. Implement exported C
      functions, exception barriers and a pinned llama backend. Compile a C client.
- [x] Run the complete native CTest suite and sanitizer coverage, update native
      build docs and CI, run applicable archived Python checks and Trunk, and provide
      the parent with exact evidence and any remaining platform/model blockers.

## Verification record

Linux debug build and all five CTest checks pass: request/manifest/renderer,
typed response mapping, C API lifecycle, exactly five ELF exports, and a C
translation-unit consumer. AddressSanitizer/UndefinedBehaviorSanitizer with leak
detection pass for the request/renderer and API lifecycle executables, with the
existing pinned llama library linked into the latter. The linked llama library
itself is not sanitizer-instrumented. Python unit tests pass (78 tests), the
archived report checker passes, and `trunk check --no-fix` reports no issues.

Ruling: destruction uses explicit caller synchronization. Prevent new calls,
cancel and join every evaluator/canceller before close; a raw opaque pointer
cannot safely admit a racing caller after destruction. The API test exercises
that sequence and retains response memory through close. Internal waiting is
defensive and does not promise concurrent-close support.

Ruling: #8 keeps a private probability-vector seam and a production 503 until
#9 implements verdict inference. The response mapper validates test backend
results, but successful model load, actual decode cancellation, probability
parity, Apple builds and physical-device behavior remain unrun without weights
or those environments. No model download occurred.
