# Native core

This staged issue #8 implementation provides the blueprint's five-function C ABI,
validation, escaped `macjev-render-v1` renderer, and llama.cpp model ownership.
**Production evaluation returns 503 after validation and tokenization until #9
supplies the verdict scorer.** Test-only distributions exercise response mapping
and ownership; they are never available through a runtime fake mode.

## Build and test

Requires CMake 3.24+, a C++17 compiler and a C compiler. From the repository root:

```sh
cmake -S packages/edge_one_core -B .cache/native-core -DCMAKE_BUILD_TYPE=Release
cmake --build .cache/native-core --parallel 2
ctest --test-dir .cache/native-core --output-on-failure
```

CMake downloads only the llama.cpp source archive pinned by `spikes/m0/pins.json`
and verifies its SHA-256. It also uses the JSON header bundled in that archive;
there is no separately floating JSON dependency or model download. For an
already verified local source tree, CMake's standard
`FETCHCONTENT_SOURCE_DIR_LLAMA_CPP` override avoids another source download.

The Linux shared library exports only `eo_open`, `eo_evaluate`, `eo_cancel`,
`eo_close`, and `eo_free`. Link the accompanying llama/ggml shared libraries.
The public header is [include/edge_one.h](include/edge_one.h). The current native
backend loads with mmap, uses CPU, two threads and a 1024-token microbatch. Mobile
acceleration and successful model inference need their later platform/scorer work.

## Calling contract

- Verify model bytes and manifest integrity before calling `eo_open`. The core
  checks runtime manifest types, limits, template/readout and tokenizer slot IDs.
  It retains file/hash/size metadata for #9; it does not authenticate the supplied
  manifest or rehash the GGUF in this stage.
- Pass NUL-terminated UTF-8 JSON. Requests over 4 MiB, nesting over 128, duplicate
  object keys, malformed JSON/UTF-8, schema violations and local limits return 422. Choice requires 1..26 options; Score requires 2..10 levels, bounded further
  by the manifest. Noul follows the shared wire schema.
- The blocking `eo_evaluate` belongs on a worker thread. One evaluation can run
  per engine; another returns 409. `eo_cancel` marks the active request and never
  poisons a later evaluation. Cancellation returns 499; unavailable resources
  return 503; unexpected native failures return 500.
- Externally synchronize destruction: prevent new calls, cancel if needed,
  and join every evaluation/cancel caller **before calling `eo_close`**. Close
  must not run concurrently with any other call. Never reuse a closed handle.
  Separate engines are independent.
- Every non-null evaluation result or open-error string is owned by the caller
  and remains valid after later calls or close. Free it exactly once with
  `eo_free`. Null output pointers are allowed, and cancel/close/free accept null.
  Allocation failure may produce a null string. Error JSON has
  `{"error":{"status":422,"message":"..."}}` shape rather than an answer.

## Rendering and scorer seam

The renderer preserves structured state/instructions/criteria and insertion order.
Ordinary prose follows the pinned template and token-segment boundaries. User
backslashes, line/control characters and angle brackets are escaped; this is an
intentional hardening delta from the upstream renderer. Nested JSON stays valid
JSON, including original nested values through JSON escapes. All tokenizer calls
use `add_special=false` and `parse_special=false`. Verdict slots are inserted
explicitly; no scan of user-controlled token text chooses them.

The context budget is the prefix once plus every question suffix. Inputs are
never truncated. `RenderedRequest` owns that prefix, each suffix and suffix-local
verdict indices, original question keys, ordered option names and Score criteria.
The private `Backend::score` seam returns one probability vector per question.
The C wrapper checks vector shape, finite probabilities and total before mapping
Choice, Score and Noul, using the blueprint's normalized-maximum confidence.

#9 must implement the pinned verdict readout/temperature, trusted-model checks,
request cleanup and exact-prefix parity before successful production evaluation.
Batched sharing remains disabled after M0 Linux drift. The model-free tests do
not establish actual model loading, decode cancellation, probability parity,
performance, Apple or physical-device behavior.
