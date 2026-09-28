# M0 iPhone 16 Pro Validation

## Origin and Integrity

After the operator reported the installed app running, `devicectl` listed its process under the installation path and one report in its app `Documents` directory.
The report was copied from that app data container without launching or relaunching the app from the Mac.
The [compressed raw export](2026-09-28-m0-ios-device-report.json.gz) decompresses to the exact device JSON with SHA-256 `1c4349a63b2c0c4e7cdfd9ca8cd34f2e3a8b9fad07a6b97dd1aa1f3271dc09e1` and declares iPhone17,1, iOS 27.0, Release arm64 and the pinned fixture/model.
The signed app passed `codesign --verify`; its embedded development profile includes this iPhone, and its bundled fixture and model hashes match the pinned inputs.
The exported build receipt exactly matches the signed bundle receipt, whose 12 source hashes match the current iOS sources.
The signed app binary SHA-256 is `f892519ffec8355d064831ef779602f5568400a4bfb45f5424ecfe92d745ff3c`.
The raw report carries the source receipt but does not embed this binary hash, so the export alone cannot cryptographically prove its executing binary.

## Measured Result

The report contains one first request, 20 warm requests and 693 continued requests over 120163.044 ms in the same scorer context.
`report.py --require-device-metadata` recalculated every distribution from native logits and passed the strict `1e-3` gate with maximum probability difference `0.0`.
The first request took 510.102 ms; warm p50 was 128.884 ms.
The final 30 seconds contain 151 requests with p50 197.632 ms.
All baseline thermal readings were `0`; sustained readings first changed to `1` at 23.62 seconds and to `2` at 48.62 seconds.
All 151 final-window readings were `2`, and the end reading was `2` (serious per the Apple thermal-state enum).
No repeat run was performed after this rise.

## Interpretation and Remaining Checks

The report passes the specified physical-device format, profile and numerical gates.
It records the default requested Metal settings (`n_gpu_layers=999`, operation/KV offload enabled, both diagnostic switches off), while its system-info string only establishes Metal availability; actual GPU layer placement was not independently observed.
The higher final-window latency coincides with the elevated thermal state, but one run does not establish thermal equilibrium or causality.
The earlier simulator Metal failure remains reproducible and unexplained.
This physical result does not approve the demo screen, supply a current-head hosted review, or complete the Draft PR.
