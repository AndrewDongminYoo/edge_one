# M1 Test Support: FakeEngine, RecordingBackend, and Examples

## Scope

Issue #13 adds model- and network-free backends to `packages/edge_one`, exported from `package:edge_one/testing.dart`.
Both implement `SystemOneBackend`, so they work behind `DecisionClient` exactly like the planned local and remote backends.
The library stays pure Dart: recordings are written to a `StringSink` and replayed from a `String`, so callers choose the storage.

## FakeEngine

`FakeEngine` answers each question from fixed weights keyed by question key, then by the answer's probability key: the option name for Choice, `true` or `false` for Noul, and the level index for Score.
Weights are normalized; omitted keys weigh 0, and a question without weights receives a uniform distribution.
Negative or non-finite weights fail at construction, and weights naming an unknown key or summing to zero fail with `StateError` when the request arrives.

Choice answers choose the first most probable option in request order.
Choice and Score confidence is `(K × max(p) − 1) / (K − 1)`, and a single option is certain.
Score answers use level keys `0` through `K − 1`, echo each requested level as its legend value, and report `score = Σ index × p`; this local convention is not verified against remote Score semantics.
Responses echo the request `model`, report zero token usage, and set `x_engine` to `{"id": "edge-one-fake"}`.
The same request always produces the same response; nothing depends on call order, time, or randomness.

## Recording Format

`RecordingBackend.record` forwards each request to a backend and appends one JSON line per call:

```json
{"version":1,"request_sha256":"<64 lowercase hex>","request":{...},"response":{...}}
```

`request_sha256` is the SHA-256 of the UTF-8 bytes of `jsonEncode(SystemOneJson.encodeRequest(request))` before redaction, so object key order is part of the request identity.
The stored `request` is the output of a `RequestRedactor`; the default `redactState` replaces `state` with `"[redacted]"` and keeps the model and question definitions.
A redactor must keep question keys, types, Choice option names, and Score level counts, because the recorder rejects a stored request that no longer pairs with the response.
Responses must pass the schema and `checkAnswers` before a line is written, and they are stored unchanged.

`RecordingBackend.replay` parses every non-blank line before answering and rejects the whole recording with `RecordingFormatException` and a 1-based line number when a line is not a JSON object, has missing or extra fields, has another `version`, has a malformed digest, or has a request or response that fails the schema or `checkAnswers`.
Replay matches requests by digest; the first line wins when digests repeat, and an unrecorded request raises `RecordingMissException`.

Redaction removes the state text, not its identity: a digest of a short or guessable state can be confirmed by hashing candidates.
Commit only synthetic recordings; recordings of real users need the same consent and masking review as remote requests.

## Contract Examples

`schemas/examples/system-one-v1-examples.json` holds four representative requests with their `FakeEngine` weights and answers, covering Choice, Noul, and Score, string, object, and array state, and structured instructions, criteria, and levels.
They are synthetic requests shaped like the TypeSafe OpenAPI 0.2.0 contract, not copies of TypeSafe documentation examples, which were not retrievable from this environment.
`schemas/examples/system-one-v1-recording.jsonl` is the redacted recording of those answers.
`dart run tool/update_examples.dart` in `packages/edge_one` regenerates both files; format the examples afterward.

## Verification

`pnpm run schema:test` validates every example request, stored answer, and recorded request and response with Ajv, and checks the recording line fields, version, digest pattern, and redacted state.
`dart test` in `packages/edge_one` checks that `FakeEngine` and `DecisionClient.evaluateJson` reproduce each stored answer, that a fresh recording is byte-identical to the stored one, and that replay answers every example.
It also covers uniform and weighted distributions, tie-breaking, determinism, invalid weights, redaction, redactor misuse, invalid backend responses, misses, key order, duplicate digests, blank and CRLF lines, and each malformed-line case.
