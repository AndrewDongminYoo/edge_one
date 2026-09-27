# M0 Simulator Metal Diagnostic

## Controlled Results

Both GPU controls completed their UI/export test on the existing arm64 iPhone 17 Pro simulator, iOS 26.5.
Disabling fusion alone and disabling shared buffers alone each failed the unchanged strict `1e-3` probability gate, with maximum difference 0.9900954802680003 over the first plus 20 warm requests.
Their first native logits remained identical to the original failing Metal run.
Neither control is a fix or a recommended default.
[Raw evidence](2026-09-28-m0-metal-diagnostic.json) preserves both reports and the canonical fixture.

## Direct Native Reproduction

Advisor recommended removing Scorer and Swift before requesting physical-device execution.
The separate UIKit/Objective-C++ `NativeRepro` target calls only upstream llama.cpp APIs for inference.
`prepare.py` generates constant tokens, slots and row IDs from the same verified fixture; the builder rejects a mismatched header before native commands.
The app uses the same model, 116 tokens, all three requested output slots, context settings and two pre-decode memory clears.
It runs CPU then Metal in separate model/context instances and writes plaintext logits without renderer, Scorer, Swift or JSON scoring code.
The installed simulator model's SHA-256 was checked externally against the fixture for this measured run.

The direct CPU logits exactly match the earlier CPU scorer run and produce maximum probability difference 0.00025757958476246845.
The direct Metal logits also exactly match the earlier Metal scorer run's first request: the first two yes/no rows are zero.
Its single-request maximum probability difference is 0.8489789103409335; this differs from the 21-request controls' maximum and remains a failure.
The native UI test confirms completion, while independent plaintext parsing and comparison establish the numerical outcome.
This reproduces the symptom below the app/Scorer layer, within the pinned llama.cpp build and simulator Metal combination.
The specific kernel, runtime or build cause remains unknown.

## Remaining Boundary

Unsigned iPhoneOS arm64 builds passed during this run, including the native diagnostic flags before the separate repro target was added.
Both SDK builds and their source receipts were refreshed after the final generator/repro-source changes.
Physical iPhone Metal behavior remains unmeasured and requires separate installation and launch approval.
No physical-device writes occurred.
Further native builds stopped when one-minute load reached 11.86 on 10 cores.
Oracle resource precedent `wiki/concepts/mac-mini-resource-limits.md` confirmed sequential native jobs and reuse of the already booted simulator.
After source review, the builder also rejects a fixture model SHA that differs from the verified manifest, and the direct repro now hashes the bundled model before loading it.
Python regressions verify that model-SHA and generated token-header drift are rejected before native commands.
The PR-loop retry compiled the runtime guard and passed both `NativeReproUITests` cases: normal CPU/Metal completion and wrong-model rejection.
The negative case selects the bundled JSON fixture as a wrong model input with `--invalid-model` and observes `model hash mismatch` before backend/model initialization; it failed before that input selection existed.
The latest native plaintext exactly matches the archived rows, and the installed model hash was independently rechecked.
The raw artifact retains the historical header hash and records the new header hash and refreshed receipts separately under `integrity_guard_validation`.
Python tests now recalculate all seven archived reports and the direct plaintext logits, preserving the measured CPU passes and Metal failures.

## Hosted Review Repair

Hosted review found that a numerically passing CPU-only iPhone report could pass the CLI's device-metadata gate.
That gate now also requires integer 999 GPU layers, operation/KV offload enabled and both diagnostic switches explicitly unrequested.
Default requested settings are accepted; CPU-only, modified and absent settings are rejected, with 12 regression subcases observed failing before the repair and passing afterwards.
All 54 Python tests pass; both SDK builds and receipts were refreshed again and preserved under `physical_cli_gate_repair`.
The inferred hardware flag and numerical gate remain separate, and declared configuration does not independently establish physical or GPU execution.
Native inference code and the failed Metal outcome are unchanged.
