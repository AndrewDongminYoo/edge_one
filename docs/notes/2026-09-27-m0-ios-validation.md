# M0 iOS Build and Validation

## Results

The host bridge compiled and ran the pinned fixture with zero probability difference from the desktop reference.
Its two warm samples had a median of 73.729 ms; this is a Mac smoke test, not an iPhone measurement.
Unsigned Release arm64 apps built for both iPhoneOS and iPhoneSimulator.
The generator needed static-library search paths and an explicit arm64 app architecture.

The simulator XCTest passed twice, checking two consecutive runs in each test, disabled controls during inference, and an exportable JSON report.
The completed screenshot was inspected; the simulator warning, duration, run button and export control were visible.
UI success did not imply numerical success: both default Metal reports failed the strict probability gate, with maximum difference 0.9900954802680003.
Several requested native logits were zero; the cause remains unconfirmed.
CPU diagnostic runs (`M0_CPU_ONLY=1`, no GPU layers or operation/KV offload) passed the unchanged `1e-3` gate with maximum difference 0.00025757958476246845.
Their 20-sample warm medians were 521.295 and 633.514 ms.
These simulator timings are not physical-device performance evidence.

## Evidence and Reproduction

[Raw evidence](2026-09-27-m0-ios-validation.json) contains the canonical fixture, host report, two failed simulator Metal reports and two passing simulator CPU reports.
The reader recomputed distributions, warm medians and parity outcomes; exported CPU receipts matched the local simulator build receipt.
XCTest results and screenshots remain under ignored `.cache/m0/ios/iphonesimulator/`.
The simulator was the existing iPhone 17 Pro, iOS 26.5, arm64 runtime.
Run `ios/build.py` as documented in the README; then run the generated `EdgeOneM0` scheme's tests on an already booted simulator, with parallel testing disabled.
The committed UI test sets the CPU diagnostic environment explicitly.

## Remaining Checks

The iPhoneOS build passed before the diagnostic option was added.
Rebuild the device app from the latest source, then obtain approval for personal-account signing and physical installation/launch before measuring its Metal path.
No physical-device writes occurred.
At the end of testing, one-minute load reached 15.25 on 10 cores, so further native work stopped.
An operator retry still measured 10.23, above the builder's 10-core limit.
Source inspection confirmed the Metal build uses a simulator target suffix; disabling upstream fusion is a future diagnostic candidate, not a confirmed fix.
Oracle precedent `wiki/concepts/mac-mini-resource-limits.md` confirmed sequential heavy jobs and reuse of the existing simulator; no project-specific scorer precedent was found.
