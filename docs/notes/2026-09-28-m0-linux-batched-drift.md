# M0 Linux Batched-Prefix Drift

## Outcome

The two Ubuntu 24.04 runs do not justify enabling batched prefix sharing. Exact
sharing produced `0.0` maximum probability difference in both runs and matched
all 24 top choices. Batched sharing produced maximum differences of
`0.012289964118848418` and `0.48225164111208135`; the first run matched 22 of
24 top choices. Both results exceed the unchanged strict `<1e-3` gate.

This bounds the first divergent boundary to the batched multi-sequence question
decode: individual and exact modes use the same pinned model, fixtures, prefix
prefill/copy contract, and two-thread configuration without drifting. The
available scorer response does not expose operation-level tensors or a sequence
copy counter, so the evidence does **not** establish which kernel or tensor first
diverges inside that decode. In particular, the large between-run change must
not be described as latency noise or as a proven thread race.

The earlier macOS run reached `0.000816753403`, close to the same threshold, but
that single passing result does not override the repeated Linux failures. The
platform difference and between-run magnitude therefore remain an upstream
batched-path limitation rather than a fixed defect.

## Diagnostic support

New reports now retain `worst_comparison` under each parity gate. It identifies
the fixture, first/warm phase, sample number, and zero-based question index in
addition to the probability difference and top-choice result. This makes the
first failing request recoverable from a raw or partial report rather than
leaving only a report-wide maximum. The archived report checker accepts legacy
reports without this additive diagnostic while still recomputing and comparing
every field those reports contain.

For a Linux reproduction, use the pinned setup and build commands in the README,
then run:

```bash
.cache/m0/.venv/bin/python spikes/m0/run.py \
  --output .cache/m0/linux-batched-diagnostic.json \
  --repetitions 5 --threads 2 --required-parity exact
```

The command deliberately requires only exact parity so that a failing batched
experiment still completes and preserves its raw report. Do not change the
model revision, fixtures, microbatch, or probability threshold when comparing
results. Use distinct output filenames for repeated processes; a report is
never overwritten.

## Decision

Keep batched sharing experimental and disabled as a production gate. Linux CI
continues to execute and record it but requires only exact sharing. Promotion
requires repeated full-fixture raw reports on supported platforms to pass
`<1e-3`; a single passing maximum is insufficient. Operation-level attribution
would additionally require a separately reviewed diagnostic scorer because the
pinned scorer is an integrity-checked model artifact and must not be patched in
place.
