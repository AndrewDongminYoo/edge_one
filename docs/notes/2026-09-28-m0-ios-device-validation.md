# M0 iPhone 16 Pro Validation

## Origin and Integrity

After the operator reported the installed app running, `devicectl` listed its process under the installation path and a report in its app `Documents` directory.
The first report was copied directly from that app data container.
The operator later supplied a second export; its SHA-256 exactly matched a separate readback of the same file from the app data container.
The compressed [first](2026-09-28-m0-ios-device-report.json.gz) and [second](2026-09-28-m0-ios-device-report-repeat.json.gz) archives decompress to the exact device JSON bytes, with respective SHA-256 values `1c4349a63b2c0c4e7cdfd9ca8cd34f2e3a8b9fad07a6b97dd1aa1f3271dc09e1` and `d8727cdc85920b5a34b7d1c0583f89ec3cb082a7b1f477998aa4bc6c6146b8c1`.
Both declare iPhone17,1, iOS 27.0, Release arm64 and the pinned fixture/model.
The signed app passed `codesign --verify`; its embedded development profile includes this iPhone, and its bundled fixture and model hashes match the pinned inputs.
Both exported build receipts exactly match the signed bundle receipt, whose 12 source hashes match the current iOS sources.
The signed app binary SHA-256 is `f892519ffec8355d064831ef779602f5568400a4bfb45f5424ecfe92d745ff3c`.
Neither raw report embeds this binary hash, so an export alone cannot cryptographically prove its executing binary.

## Measured Results

`report.py --require-device-metadata` recalculated every distribution from native logits in both reports and passed the strict `1e-3` gate with maximum probability difference `0.0`.
Each run has one first request and 20 warm requests before continued scoring in the same scorer context.

| Run finished (UTC) | First request |   Warm p50 |          Continued requests | Final 30-second p50 | Thermal start to end |
| ------------------ | ------------: | ---------: | --------------------------: | ------------------: | -------------------: |
| 03:10:04           |    510.102 ms | 128.884 ms | 693 in 120.163 s; 151 final |          197.632 ms |               0 to 2 |
| 03:32:28           |    158.041 ms | 129.392 ms | 710 in 120.124 s; 153 final |          195.624 ms |               0 to 2 |

All baseline thermal readings were `0` in both runs.
The first run changed to `1` at 23.62 seconds and `2` at 48.62 seconds; the second changed to `1` at 29.91 seconds and `2` at 49.80 seconds.
Every final-window reading was `2` in both runs (serious per the Apple thermal-state enum).

## Interpretation and Remaining Checks

Both reports pass the specified physical-device format, profile and numerical gates.
They record the default requested Metal settings (`n_gpu_layers=999`, operation/KV offload enabled, both diagnostic switches off), while their system-info strings only establish Metal availability; actual GPU layer placement was not independently observed.
The higher final-window latency coincides with the elevated thermal state, but two runs do not establish thermal equilibrium or causality.
The earlier simulator Metal failure remains reproducible and unexplained.
The operator reported normal operation and requested PR review; these measurements do not by themselves complete M0 or authorize merge.
