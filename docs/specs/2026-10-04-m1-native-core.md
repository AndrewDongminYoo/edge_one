# M1 Native C API and Renderer

Issue #8 implements the blueprint's five-function C ABI in C++17. The library
loads the pinned llama.cpp model and exposes blocking evaluation, cancellation,
and explicit ownership through `eo_free`. Bindings must verify model bytes and
the manifest digest before opening; the native layer validates runtime fields.

## Contract

- `eo_open` returns an opaque handle or null and an owned UTF-8 error string.
- `eo_evaluate` returns an owned JSON string and a status: 200 success, 422
  invalid request or local budget, 409 concurrent evaluation, 499 cancellation,
  503 unavailable engine, or 500 unexpected native failure. Allocation failure
  may return null with status 503. Optional output pointers may be null.
- Null `eo_cancel`, `eo_close`, and `eo_free` are harmless. Evaluate is serialized
  per engine; simultaneous evaluations fail with 409. Cancel can be called from
  another thread and affects only the active evaluation. Destruction requires
  external synchronization: prevent new calls, cancel if needed and join every
  evaluation/cancel caller before calling close. Close must not run concurrently
  with any other call. Never reuse a closed handle. Handles are independent.
- JSON schema validation follows `schemas/system-one-v1.schema.json`. Additional
  local limits require 1..26 Choice options and 2..10 Score levels, reduced by
  manifest limits. Object insertion order determines option order. Duplicate JSON
  keys, documents over 4 MiB and nesting over 128 levels are rejected. Malformed UTF-8 is rejected.
- State, instructions and criteria retain JSON structure. Plain strings remain
  text. Untrusted string controls, backslashes, angle brackets and line breaks
  are escaped before rendering to prevent forged template lines, special tokens
  and verdict arrows. No untrusted text is interpreted as a special token.
- The pinned `macjev-render-v1` segment boundaries and explicit verdict slot
  indices are retained. The context budget counts the state prefix once plus
  every question suffix; no input is truncated. The manifest defaults to 2048.

## Dependency and scorer boundary

Use the existing M0 llama.cpp commit and archive SHA-256, including its bundled
nlohmann JSON header. CMake fetches only source, never model weights. Tests use a
private backend seam to exercise the ABI without a model. Production scoring
and exact-prefix parity belong to #9; no synthetic production answers are allowed.
Batched prefix sharing stays disabled after the recorded M0 Linux drift.

## Verification

Native tests cover the shared schema corpus, local limits, malformed and nested
JSON, manifest fields, structured and forged input, token-budget boundaries,
owned result lifetime, concurrent calls, cancellation and synchronized engine teardown.
A C translation unit compiles the public header. Linux builds link real pinned
llama.cpp. Model loading/parity with weights and Apple checks remain separate.
