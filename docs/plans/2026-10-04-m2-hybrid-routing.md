# Hybrid router implementation plan

> For agentic workers: use superpowers:executing-plans for this delegated work.

**Goal:** Add safe question-level escalation and opt-in shadow comparison behind
existing pure Dart contracts.

**Architecture:** A guarded injected `RemoteBackend` owns policy and transport;
`RemoteBudget` reserves daily costs synchronously; `HybridRouter` gates local
answers using issue #17 calibration, escalates a subset, and merges by key.

**Tech Stack:** Dart 3.9+, existing contract/calibration modules and test package.

**Spec:** `docs/specs/2026-10-04-m2-hybrid-routing.md`.

## Global constraints

- Only edge_one changes in the isolated worktree stacked on #17.
- No HTTP implementation, credentials, real request egress, weights, or paid calls.
- Preserve System One wire contract and raw returned answers.
- Default local-only; remote requires masking, consent, network, and budget.
- Run clean `trunk check --no-fix` before every commit.

## Review focus

- Policy revocation during masking must stop transport.
- Masking nested instructions and criteria must not alter local data.
- Incomplete or incompatible remote answers must never produce a partial result.
- Async concurrency and failed calls must not exceed the shared budget.
- Shadow callbacks must not affect primary answers or response metadata.

## Task 1: guarded transport and cost budget

Files: `lib/src/remote_budget.dart`, `lib/src/remote_backend.dart`, public exports,
`test/remote_backend_test.dart` (paths relative to packages/edge_one).

- [x] Write failing fake-transport tests for default denial, each gate, full masking,
      immutable snapshots, invalid shape, consent revocation, budget exhaustion,
      concurrency, clock rollover/backward jumps, status mapping, and response
      validation.
- [x] Run the focused tests and capture missing-feature failures.
- [x] Implement `RemoteBudget`, `RemotePolicy`, `RemoteBackend`,
      `RemoteTransportResponse`, and typed remote failures.
- [x] Run focused and full edge_one tests; format and analyze.

## Task 2: routing and calibration

Files: `lib/src/hybrid_router.dart`, public exports,
`test/hybrid_router_test.dart`.

- [x] Write failing tests for mixed/forced routes, exact key merge, per-type
      calibration, inclusive/null thresholds, hash/type/key warnings, ordinary
      local fallback and forced exceptions, and invalid local/remote answer sets.
- [x] Capture failures, then implement `HybridRouter` with `x_routing` metadata.
- [x] Run focused and full edge_one tests; format and analyze.

## Task 3: shadow lifecycle and documentation

Files: `lib/src/hybrid_router.dart`, `test/hybrid_router_test.dart`,
`docs/specs/2026-10-04-m2-hybrid-routing.md`,
`docs/plans/2026-10-04-m2-hybrid-routing.md`, README.

- [x] Write failing tests for deterministic sampling, local-only subset selection,
      guards/masking/shared budget, and unchanged primary output on all failures.
- [x] Implement explicit shadow sampler and observer with awaited best-effort work.
- [x] Document raw return versus calibrated gate semantics and native preflight
      dependency; add a synthetic injected-transport example.
- [x] Run full tests, analyzer, schema checks, and clean Trunk.
- [x] Complete independent review; hand off the focused commit and Draft-to-Ready
      publication to the parent.
