# Fixed Linux AVX2 production parity reference

The user-approved `linux-x86_64-avx2-v1` reference passed the unchanged strict
`max_abs_difference < 1e-3` gate on 2026-10-04. This defines the Linux
algorithm/sharing reference environment; it does not repair the historical
cross-profile failure or establish universal cross-ISA parity.

The separately compiled pinned upstream scorer used the existing verified model
and source. Production executable, libraries, scoring code and runtime profile
were unchanged. No additional model downloads occurred. Both builds used GCC
14.2, Release, identical effective compiler flags for llama and the three ggml
targets, and matching common CPU settings. The fixed profile disables native,
AVX512, AVX_VNNI, AMX and multi-variant compilation while enabling
AVX/AVX2/SSE4.2/BMI2/F16C/FMA. Full details are in the independent build receipt.

## Complete-run observations

Each fixture ran in a fresh reference, production individual and production exact
process, with one first and one warm observation: 24 observations, 12 processes,
24 strict comparisons. All token, option-name and verdict-slot checks passed.
The maximum difference between production individual and exact was zero.

| Fixture          | Prefix tokens | Maximum reference difference | Exact shared tokens | Sequence copies |
| ---------------- | ------------- | ---------------------------- | ------------------- | --------------- |
| structured-short | 47            | 0                            | 0                   | 0               |
| below-block      | 1023          | 5.551115123125783e-17        | 0                   | 0               |
| at-block         | 1024          | 0                            | 1024                | 3               |
| above-block      | 1025          | 6.938893903907228e-18        | 1024                | 3               |

At/above the block boundary, exact mode decoded 1,220/1,223 tokens in four calls.
Every process has recorded executable/library mappings and hashes; mapped device
and inode identities were checked against the hashed files. Reference receipt,
source/model integrity and production artifacts were checked again after the run.
Timings are incidental and provide no performance, GPU or physical-device claim.

## Provenance and reproduction

The measurement ran from 16:12:23 to 16:25:36 UTC using the production binary from
`28a1fab338c67d5a4503fdc833729b2cb6326b11` and this change's harness. The implementation
report records the harness/helper file hashes and the final local commit.

- Model: `0a19bc29bacc33e0d871146c8612b24dd14c2ed2e61cedeb7a928b0852628bac`, 529,296,864 bytes.
- Production executable: `0c47a3e11c9d77998dfe6c9c2b3e50a64625e67ae6e5029d8abc888d10045560`.
- Independent reference executable: `2d85d7b2d0871e3ea9a2a96e661722b87e6bbd24448b3fc19514f3a620b303f0`.
- Reference receipt: `1d445c44436889b947b4a9625e321e01868f4cddcfeb04ae01bf533b35bbd807`.
- Complete raw report: `/tmp/edge-one-fixed-reference-parity.json`, SHA-256 `bd9dd091bb232dd08b3cc383ad385131a2273ecb0a1aac0b941aee4ad8f6d115`.
- Implementation/test record: `/tmp/edge-one-fixed-reference-implementation-report.json`.

Use the helper and harness commands in the README. The receipt is separate at
`.cache/m0/reference-linux-x86_64-avx2-v1/build-receipt.json`; native M0 paths and
receipts are unchanged. This local worktree had no default native M0 binary or
receipt: the fixed reference does not silently depend on either.

## Validation history and limits

Regression-first tests covered explicit selection, unsupported hosts, isolated
paths, receipt/artifact integrity, effective-flag drift, versioned libraries,
actual mapped-file identity and production's actual link dependencies. Python
unittest passed 99 tests; Release CTest passed 7/7; the existing focused
ASan/UBSan scorer/integrity build passed 2/2 with leak detection. An attempted
broad sanitizer CTest found request/response/API/C-client targets and the export
library unbuilt in that focused tree; those were not sanitizer passes. The
archived desktop report checker also passed, as historical evidence only.

An initial compiled reference was not receipted because a running pre-fix helper
rejected versioned library names. It was preserved and a clean build succeeded.
An initial inference attempt recorded two short reference observations, then
stopped before production scoring because the verifier incorrectly expected the
unlinked `libedge_one_core.so`. A failing filesystem regression, CMake and `ldd`
evidence established the cause; the corrected suite passed before the complete
run above. That aborted report/log is preserved separately.

The original native/AMX cross-profile failure `0.01687824909653951` remains failed.
Its report SHA-256 is still
`86c56a8bdee1367c2afcb08f41dd478b75c9ca37545e3bfccc4a2c5f73d3733b`.
The prior controlled-evidence ZIP remains byte-identical, SHA-256
`8c2328284a215723c042304852c0a89737f85dfcd11165e15475c95af625dda1`.
This result changes neither that evidence nor the numerical tolerance, fixture
corpus, model/readout pins or production scoring implementation.
