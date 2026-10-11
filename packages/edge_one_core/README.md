# Native core

The native implementation provides the blueprint's five-function C ABI,
validation, escaped `macjev-render-v1` renderer, and pinned llama.cpp verdict
scoring. It reads yes/no logits at each explicit verdict slot, applies the
manifest global temperature and stable softmax, and maps Choice, Score and Noul.

## Build and test

Requires CMake 3.24+, a C++17 compiler and a C compiler. From the repository root:

```sh
cmake -S packages/edge_one_core -B /tmp/edge-one-core -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/edge-one-core --parallel 2
ctest --test-dir /tmp/edge-one-core --output-on-failure
```

CMake downloads only the llama.cpp source archive pinned by `spikes/m0/pins.json`
and verifies its SHA-256. It also uses the JSON header bundled in that archive;
there is no separately floating JSON dependency or model download. For an
already verified local source tree, CMake's standard
`FETCHCONTENT_SOURCE_DIR_LLAMA_CPP` override avoids another source download.

The Linux shared library exports only `eo_open`, `eo_evaluate`, `eo_cancel`,
`eo_close`, and `eo_free`. Link the accompanying llama/ggml shared libraries.
The public header is [include/edge_one.h](include/edge_one.h). The current native
backend loads with mmap and uses CPU, two threads, unified KV, two sequences,
26 logit outputs and a maximum 1024-token microbatch. Context and logical batch
match the manifest token budget (2048 by default). Mobile acceleration remains
separate platform work.

## Calling contract

- The core anchors identity and readout to constants generated from the bundled
  manifest at build time, verifies the GGUF size and SHA-256 before loading, and
  checks tokenizer slot IDs. Runtime limits may be reduced but not raised.
  Model/readout changes are rejected; changing download mirrors is permitted.
  Bindings still verify bundled manifest/legal assets and downloaded files.
- The caller/store must keep the opened backing object's bytes immutable and
  untruncated from the start of `eo_open` until all engines using it are closed.
  Publish replacements from separate staging objects; never overwrite a live
  backing object. The default `ModelStore` staging/rename flow supports this
  usage, but callers, custom commit callbacks and other writers must honor it.
  The core hashes, checks rewind and loads through the same owned `FILE*`, held
  until after model/context destruction. Replacing a pathname does not retarget
  that handle (platform sharing rules may restrict rename/unlink). Read-only
  mmap does not prevent or detect same-inode writes/truncation. No snapshot,
  copying, write-exclusion or store-lease framework is provided.
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

Exact sharing prefills only whole physical microbatch blocks of the prefix, then
copies that sequence for each sequential question. The remaining prefix tokens
are decoded with each suffix. A single question uses independent full prefill;
prefixes below one block share nothing. Memory is cleared before and after every
request, including cancellation/failure. There is no cross-request cache.
Batched sharing remains disabled after M0 Linux drift.

## Real-model parity

The default CTest suite needs no model. Its decoder test dependency establishes
scheduling and cleanup, not numerical model parity or actual decode cancellation.
The optional executable uses the production backend sources and exposes private
individual/exact modes, rendered tokens, actual context values and decode/copy
counts. With the existing verified M0 model/runtime/build inputs already present:

```sh
cmake -S packages/edge_one_core -B /tmp/edge-one-core \
  -DCMAKE_BUILD_TYPE=Release -DEDGE_ONE_BUILD_PARITY_DRIVER=ON
cmake --build /tmp/edge-one-core --parallel 2
.cache/m0/.venv/bin/python tools/build_parity_reference.py build \
  --profile linux-x86_64-avx2-v1 --jobs 2
.cache/m0/.venv/bin/python tools/check_native_parity.py \
  --reference-profile linux-x86_64-avx2-v1 \
  --production-build /tmp/edge-one-core \
  --driver /tmp/edge-one-core/edge_one_score_driver \
  --output .cache/m0/production-parity.json --repetitions 1
```

The independent reference build is a prerequisite; if it already exists, use
`tools/build_parity_reference.py verify --profile linux-x86_64-avx2-v1` instead
of rebuilding it. This fixed reference requires a supported Linux x86-64 AVX2
host and preserves the default native M0 build and receipt separately.

The harness never downloads inputs. Explicit missing inputs fail. It verifies
the isolated reference receipt and actual loaded artifact hashes, compares all four fixtures' token IDs/option order/slots, and
requires probability differences strictly below `1e-3` against the unchanged
upstream individual path and between production modes. It checks nonzero actual
sharing for the 1024/1025-token prefixes, preserves fresh raw reports and records
the production and upstream profiles separately. Linux CI runs this after its
existing verified M0 fetch/build. Archived M0 results do not validate this
production profile. Apple/device behavior and performance remain unmeasured by
these tests.
