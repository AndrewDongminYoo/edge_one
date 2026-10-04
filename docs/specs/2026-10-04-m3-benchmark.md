# M3 synthetic replay benchmark specification

Issue [#18](https://github.com/AndrewDongminYoo/edge_one/issues/18) gains a pure Dart
fixture harness for five represented dataset shapes across local, remote and
hybrid backend paths. This Linux evidence proves software behavior and metric
computation; it does not measure a corpus, model or physical device.

The approved design uses a separate version 1 envelope around unchanged System
One requests, strict four-field recordings, and strict six-field #17 calibration
records. The implemented format and metric conventions are documented in
[the package README](../../packages/edge-one-benchmark/README.md).

## Acceptance boundary

- Same immutable request JSONL and insertion order enter all three modes.
- The actual `RemoteBackend` policy and `HybridRouter` handle consent, masking,
  budgets, calibrated gates, forced remote keys and fallback.
- Exact local/remote subset exchanges are required. There is no network fallback,
  FFI/native driver, model download, dataset fetch or credential path.
- Eleven invented cases cover Banking77, KLUE-YNAT, KLUE-NLI, NSMC and mixed
  Choice/Noul/Score tickets; an additional hybrid-denied run exercises refusal.
- All 77 Banking options remain present. Local is unsupported above 26 options;
  hybrid forces remote, and denied forced requests are complete errors.
- Every case/run/trial has exactly one capture, including unsupported and error.
  Repeated trials contribute timing and cost but do not duplicate quality labels.
- Reports accept only the unchanged immutable result from `replayBenchmark` for
  the exact parsed bundle object. Copied or caller-assembled captures are rejected;
  importing external capture artifacts is outside v1. Structural validation alone
  does not establish execution provenance.
- Raw decoded local/remote bodies, source request digests, model strings, fixture
  build metadata, errors and failure origins survive into the report.
- Accuracy, max-probability ECE10, unscaled categorical Brier, fixed local-gate
  coverage at 1/5/10%, nearest-rank latency and reserved microcredits are explicit.
- Calibration-only requests are disjoint by digest and canonical content from
  evaluation. Profiles are verified by deterministic refit and stable question
  definitions. Score legend meanings remain stable across all successful bodies.
- Local-gate potential coverage and actual returned accepted-local counts are
  separate. Direct remote local-gate coverage is unavailable, not fabricated.
- Every report says `synthetic represented dataset shapes; not Banking77/KLUE/NSMC/model measurements`.

## Dependency contract and limits

Implementation started from reviewed router base `f3e01e3` with #17 artifacts.
The final stack will receive the parent's #17 regression fix and rebased #16
without changing the artifact or routing APIs. Fixture producer provenance remains
its original immutable base, distinct from the current executing checkout.

Native [PR #42](https://github.com/AndrewDongminYoo/edge_one/pull/42), contract
reference `58526f3`, retains `eo_open/evaluate/cancel/close/free`. It exposes no
public tokenizer or capacity preflight API. Its optional private score driver has
its own timing scope and error behavior. This package does not invoke or infer
measurements from that driver; production parity remains a separate gate.

External data mode is rejected. Before real dataset measurement, record source
revision and official split, selection/exclusions, actual label mapping, rights,
attribution, transmission/publication permission and privacy policy. No external
dataset license or right is claimed by the authored fixture. Real provider model
revision mapping, actual billed currency, physical device/cold/warm/sustained
measurements, and remote HTTP byte capture also remain outside this version.

## Focused regression evidence

Hand checks distinguish max probability from normalized routing confidence:
Noul `[.9,.7,.6,.8]`, labels `[true,false,true,true]` gives accuracy `.75`, ECE `.35`
and Brier `.35`. Zero probability at truth gives accuracy zero, ECE one and Brier
two. Four answered plus one unsupported plus one error retains six attempts.

Boundary regressions keep raw ECE bin edges stable while normalizing materially
rounded totals. Gate calculations retain original wire values/order and reproduce
an inclusive fitted threshold for a distribution totaling `.99`. Capture identity
uses a structured tuple, so colon-containing run/case IDs cannot hide a missing
row. Valid 201 responses, finite malformed remote bodies, semantic-invalid Choice
answers, and forced mixed-request failures all preserve complete accounting.

## Reproducibility

Six fixed input filenames and exact byte hashes keep the loader small. A separate
explicit generator authors fixtures; tests/CI never overwrite them. CLI reports
include full capture evidence and fixture provenance; Linux CI compares the
complete result to the reviewed expected JSON. Runtime checkout identity belongs
in CI/operator execution logs, not a self-referential committed baseline.
