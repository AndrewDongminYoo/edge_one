# M1 Test Support Plan

## Goal

Close issue #13 with deterministic fake answers, JSON Lines record and replay, and representative examples that pass local contract validation on Linux.

## Steps and Checks

1. Add `FakeEngine` behind `SystemOneBackend`; verify uniform and weighted distributions, tie-breaking, determinism, invalid weights, and typed decisions through `DecisionClient`.
2. Add `RecordingBackend` with a versioned line format, SHA-256 request identity, and state redaction by default; verify redaction, misses, duplicates, and every malformed-line case.
3. Add representative example requests, their fake answers, and a redacted recording; verify them with Ajv and with byte-identical regeneration in `dart test`.
4. Mutate redaction, duplicate handling, replay pairing, version checks, tie-breaking, and Score weighting; verify each mutation fails a test.

## Boundary

No local inference, remote transport, file I/O in the library, or cross-language replay is included.
Verbatim TypeSafe documentation examples and remote Score semantics remain unverified.
