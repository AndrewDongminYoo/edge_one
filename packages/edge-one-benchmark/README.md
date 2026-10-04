# Offline synthetic benchmark

This pure Dart package replays one request JSONL through `RecordingBackend`,
`RemoteBackend`, and `HybridRouter`. It produces complete outcome counts,
categorical quality metrics, fixed local calibration gates, and preserved decoded
backend evidence. It opens no sockets and runs no model or native process.

Every committed result has this origin:

> synthetic represented dataset shapes; not Banking77/KLUE/NSMC/model measurements

## Run

From the repository root, resolve with `flutter pub get --enforce-lockfile`, then:

```sh
dart --suppress-analytics run packages/edge-one-benchmark/bin/edge_one_benchmark.dart validate \
  --suite packages/edge-one-benchmark/test/fixtures/v1/suite.json
dart --suppress-analytics run packages/edge-one-benchmark/bin/edge_one_benchmark.dart report \
  --suite packages/edge-one-benchmark/test/fixtures/v1/suite.json \
  --output /tmp/edge-one-benchmark-report.json
cmp packages/edge-one-benchmark/test/fixtures/v1/expected-report.json \
  /tmp/edge-one-benchmark-report.json
```

Run `dart --suppress-analytics test` from this package directory. Tests and CI
never regenerate the expected report. A maintainer may deliberately run
`dart --suppress-analytics run tool/update_fixture.dart` here and review the full
diff. The generator rejects conflicting exchanges for an identical backend and
request digest. The CLI refuses to overwrite any fixture input or baseline.

## Fixture contract

Version 1 accepts six fixed filenames. `suite.json` hashes the exact bytes of the
other five files. Unknown fields, versions, external origins, path substitutions,
duplicate identities and nonfinite JSON numbers fail preflight.

| File                     | Contents                                                                                                       |
| ------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `suite.json`             | Origin, rights, nullable model/build provenance, runs and five file hashes                                     |
| `requests.jsonl`         | Immutable System One requests; the same ordered objects enter every mode                                       |
| `cases.jsonl`            | Case ID, dataset ID, evaluation partition, synthetic split, request digest and categorical labels              |
| `backend_fixtures.jsonl` | Exact local or masked remote request, status, decoded body/error, synthetic duration and reserved microcredits |
| `calibration.jsonl`      | Unchanged strict six-field #17 labeled recordings, from separate authored calibration requests                 |
| `gates.json`             | Seed and fixed #17 profiles for target error 1%, 5% and 10%                                                    |

Request digests use `RecordingBackend.requestSha256`: SHA-256 of UTF-8
`jsonEncode(SystemOneJson.encodeRequest(request))`, including insertion order.
They are not canonical JSON hashes. Canonical comparison additionally rejects
reordered duplicate evaluation requests and overlap with calibration requests.
Question definitions and Score legend meanings must remain stable.

The parser deterministically refits the tiny calibration-only records to verify
all three supplied profiles. This verifies provenance and binding; it does not
fit on evaluation rows. #17's internal fitting/validation halves both remain
inside the calibration source. Missing local calibration is explicitly reported
as unavailable. Different remote/hybrid logical model IDs are valid.

The committed suite contains 11 authored requests: Banking77 (1), YNAT (1), NLI
(1), NSMC (6) and tickets (2). It runs local, remote, hybrid, and an additional
hybrid run with consent denied. The full three-mode comparison therefore uses
identical source requests. Synthetic remote masking replaces state with
`[masked]`; exact masked requests that become identical share one deterministic
exchange. This is a policy/replay fixture, not a useful inference prompt.

Backend replay matches exact requests, including the router's local subset and
remote masked subset. It never slices an unrelated full response. Local Choice
or Score questions above 26 options return `unsupported`; hybrid explicitly
forces those keys remote. Banking77 retains all 77 synthetic intent names.
No public native tokenizer/preflight capability is invented.

Each report includes exactly one capture per case, run and trial. A capture has
an answered/unsupported/error outcome, optional complete four-field recording,
error and failure origin, entered exchanges and synthetic elapsed time. Local
completion tracking distinguishes a local failure from a refused remote attempt.
A nonmodal Choice or invalid categorical label is a per-attempt
`invalidBenchmarkResponse`, with raw body retained. Wire-invalid remote bodies
and non-2xx bodies are also retained. There is no partial successful recording.

The Dart report API requires the unchanged immutable list returned by
`replayBenchmark(bundle)`, with that exact parsed bundle object. Passing a copied,
wrapped, reconstructed or imported capture list, or another bundle, fails with
`FormatException`. The public `List<BenchmarkCapture>` signatures remain the
same; arbitrary capture import is outside v1. `validateCaptures` checks structure
and evidence associations only; it does not certify execution provenance.

Remote raw evidence scope is `decoded_transport_body`: the object supplied to
`RemoteTransportResponse` before library parsing. It is not HTTP bytes. Local
bodies use `decoded_backend_response`. Both are immutable snapshots.

## Dataset mappings and rights

| Represented shape | Input fields and mapping                                                                |
| ----------------- | --------------------------------------------------------------------------------------- |
| Banking77         | `id`, `text`, exact intent-name `label`; caller supplies all 77 distinct nonempty names |
| KLUE-YNAT         | `id`, `title`, integer label 0–6 → IT과학, 경제, 사회, 생활문화, 세계, 스포츠, 정치     |
| KLUE-NLI          | `id`, `premise`, `hypothesis`, integer label 0–2 → entailment, neutral, contradiction   |
| NSMC              | `id`, `document`, integer label 0/1 → false/true positive-sentiment Noul                |
| Tickets           | `id`, structured `state`, labels for topic Choice, refund Noul and urgency Score        |

The ticket adapter authors numeric legend keys `0`, `1`, `2` in its fixture.
Generic benchmark Score labels may be any nonempty legend key, validated against
the actual paired response. Modal Score classification sorts legend keys
lexicographically and chooses the first maximum; it is not numeric score error.
Choice uses the returned maximum-probability option, allowing tied maxima. Noul
predicts true at 0.5.

All examples, labels and distributions are invented. No source rows were
imported; no external dataset license, attribution, transmission or publication
rights are claimed. External mode is rejected. Real dataset work requires
separately recorded source revision, official split, selection, license evidence,
attribution obligations and permission to transmit/publish. The future 200-ticket
target remains unmeasured.

## Metrics and accounting

Reports group by dataset, run/condition and question. Quality uses one declared
trial; all trials contribute timing and cost. Every request and question reports
attempted, answered, unsupported and error counts. Conditional accuracy is
correct/answered; completion is answered/attempted; end-to-end success is
correct/attempted. Empty quality samples produce null metrics.

ECE10 uses raw maximum probability with bins `[0,.1)`, …, `[.9,1]`.
Brier is the unscaled categorical sum, range `[0,2]`; Noul includes both classes.
For quality only, totals within `1e-12` of one retain raw probabilities to avoid
moving exact bin edges through summation noise. Materially rounded totals within
the wire tolerance are directly normalized by their sum. Zero true-label support
is a valid bad prediction. Stored evidence is never changed.

Fixed gate calculations retain the original wire probability values **and their
iteration order**, then call the same temperature/confidence helpers as the
router. They never use quality-normalized values or threshold fudge factors.
Coverage divides potential local gate acceptances by all attempted evaluation
questions, including failures. Hybrid uses preserved local subresponses even if
a forced remote failure prevents a final answer. Actual returned accepted-local,
fallback-local and remote counts are separate; an error capture has zero returned
answers. Denied/failed escalation counts refer to question keys, using exact
remote subrequests or forced keys plus completed local gate decisions.

Direct remote local-gate coverage is null with reason
`local_model_artifact_not_applicable`; a local artifact cannot calibrate a remote
model. Missing calibrated question keys also have an explicit reason. Accepted
error is null for zero acceptances and reports observed error above a target
unchanged. Empirical fitting targets do not guarantee evaluation error.

Latency is the sum of entered **synthetic exchange durations**, not replay wall
clock or measured inference. Unknown timing remains null. Success and failure
samples stay separate; nearest-rank p50/p95 uses `ceil(q*N)-1`.

Cost unit is `application_microcredits`, basis
`conservative_fixture_reservation`. Entered remote calls count even on failure;
refused calls cost zero. The actual fixed-clock `RemoteBudget` is reconciled with
entered transport reservations across all trials. Billing is null. V1 disables
shadow execution and reports zero shadow cost. These are not dollars or quotes.

## Provenance and remaining integration gates

`fixture_provenance` describes the frozen fixture producer base and declared
contract references. Its synthetic model digest (`aaaa…`) does not identify
model bytes; nullable native fields and remote revision are unmeasured. The
producer base is `f3e01e3` with `dirty: true`, when these fixtures were authored.
This field never claims to identify the checkout currently replaying them. Record
the actual execution commit/dirty state in the CI run or operator log separately;
the complete deterministic baseline compares all fixture provenance and hashes.

The native contract reference is [#42](https://github.com/AndrewDongminYoo/edge_one/pull/42)
at `58526f3`; the router is [#41](https://github.com/AndrewDongminYoo/edge_one/pull/41).
There is no native adapter here, and production parity, weights, real data,
provider model mapping, device conditions, wire-byte collection and billing are
separate integration gates. No native/model/device benchmark result is claimed.
