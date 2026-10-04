# M1 Native Verdict Scoring

Issue #9 replaces the native scorer's unavailable result with pinned Jev verdict
inference. The exported C API and System One response mapping remain unchanged.

- Validate runtime model identity, revision, file hash/size and readout against
  build-time constants from the bundled manifest. Runtime limits may be reduced,
  never raised. Verify actual GGUF bytes before llama.cpp loads them. Transport
  URLs and mirrors do not affect native model identity.
- Use the manifest context budget (2048 by default), matching logical batch,
  1024 maximum physical microbatch, two sequences, unified KV, 26 output rows,
  two CPU threads and no GPU layers. Record actual context values in diagnostics.
- Default to exact sharing within each request. Share only complete physical
  microbatch blocks of the state, then evaluate each branch sequentially on a
  copied prefix. A single question uses independent fused prefill. Clear memory
  before and after every request, including decode failure and cancellation.
- Read only verdict-slot logits at yes/no token IDs, divide their difference by
  manifest global temperature, and apply stable double-precision softmax.
  Reject invalid/nonfinite readouts. Existing response code owns confidence.
- Keep individual scoring available through a private diagnostic interface.
  Do not enable batched scoring, persistent prefix caching, category temperature,
  remote inference, model downloads or public configuration switches.
- Model-free tests prove integrity, readout arithmetic, slot mapping, decode
  scheduling, branch isolation and cleanup. They do not prove model parity.
- An optional native JSONL driver and Python harness consume the existing pinned
  M0 model/runtime/fixtures. Compare production token IDs and slot order against
  upstream, and production individual/exact probabilities against the unchanged
  upstream individual reference with strict differences below 1e-3. Require
  actual shared decode/copy evidence at the 1024-token boundary. Preserve fresh
  results, actual profiles and identities. Explicit missing inputs fail.

Real-model Linux CI reuses the existing verified M0 fetch. Local real inference
remains unrun unless the verified weights already exist. Archived M0 results do
not validate the production context profile; batched remains experimental.
