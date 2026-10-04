# M3 benchmark implementation plan

Approved scope: issue #18, fixture-only pure Dart replay on the reviewed #16 stack.
Source design: [specification](../specs/2026-10-04-m3-benchmark.md).

## Task 0: inspect contracts and isolate work

- [x] Inspect actual #9 scorer/ABI and #16 router/transport/budget seams.
- [x] Obtain parent approval for fixture-only design; exclude live collection.
- [x] Use isolated `codex/m3-benchmark` worktree at `f3e01e3`.
- [x] Read AGENTS and executing-plans/TDD skills; record dependency boundaries.

## Task 1: bundle and adapters

- [x] Write failing tests before strict parser/adapters.
- [x] Implement fixed file roles/hashes, immutable input snapshots, exact request
      digest and duplicate/overlap/definition checks.
- [x] Preserve all 77 Banking choices, fixed Korean class mappings, boolean NSMC
      labels, and stable mixed-ticket labels.
- [x] Verify calibration-only profiles through deterministic #17 refit.
- [x] Reject unknown versions/fields, nonfinite evidence and malformed provenance.

## Task 2: metrics and accounting

- [x] Red/green hand-checked accuracy, ECE10, categorical Brier and latency tests.
- [x] Complete request/question denominators and single selected quality trial.
- [x] Fixed held-out local gates, null direct-remote local-gate coverage, observed
      target errors, separate actual accepted/fallback/remote counts.
- [x] Preserve raw ordered probabilities for routing while quality normalization
      handles rounded totals without moving exact ECE boundaries.
- [x] Include failed dispatch reservations and reconcile shared run budgets.

## Task 3: real backend replay with synthetic exchanges

- [x] Red/green exact masked subset, source digest and different model-ID tests.
- [x] Inject recorded local responses and a fixture transport into actual #16.
- [x] Cover 77-choice forced bypass, policy denial, uncertain fallback, transport
      failure, invalid body, successful 2xx Score, and no partial answered captures.
- [x] Track local completion/failure origin so remote-like local error strings
      cannot fabricate escalations.
- [x] Validate categorical semantics per attempt and retain invalid raw bodies.

## Task 4: CLI, fixtures, docs and checks

- [x] Add validate/report CLI; prohibit fixture/baseline overwrite and live options.
- [x] Generate 11 invented requests across five shapes and four runs (three modes
      plus explicit denied hybrid); preserve producer provenance and raw evidence.
- [x] Red/green CLI baseline determinism and failure-path tests.
- [x] Document format, definitions, rights boundary and native dependency limits.
- [x] Add Linux formatting/analysis/tests and exact baseline comparison.
- [x] Run full relevant Dart/CLI, contract, frozen-resolution and Trunk checks.
- [x] Complete root independent review; receive authorization for commit and stack rebase.

## Review corrections already incorporated

Each correction received a failing regression before its implementation: structured
capture identity; invalid remote answer pairing; exact ECE boundaries; raw fitted
gate parity; nonfinite JSON; valid 201 Score legends; forced mixed-failure local
coverage/escalation keys; local failure origin; semantic-invalid answers. These
changes stay inside the benchmark package and preserve #9/#16/#17 public APIs.

The report API now requires the unchanged immutable list minted by fixture replay
for the exact parsed bundle. Regressions cover stripped failed-dispatch evidence,
altered fallback refusal metadata, copied/spoofed lists, cross-bundle reuse and
nested mutation. Structural validation remains separate from this provenance
precondition; v1 does not import arbitrary capture artifacts.

No commit or publication is authorized before root review. Root owns integration
onto the latest calibration/router stack and the focused stacked PR. Native
parity, actual data rights, model measurements and billing remain unclaimed.
