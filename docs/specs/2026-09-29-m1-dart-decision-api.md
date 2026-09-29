# M1 Dart Contract and Decision API

## Scope

Issue #10 adds the pure Dart layer of `packages/edge_one` on top of the generated System One types.
It contains a strict JSON codec, typed question builders, the `Decision<T>` result, per-question accessors, and a raw JSON entrypoint.
It has no Flutter, FFI, network, or inference dependency; the local engine, remote backend, router, and test doubles remain in issues #8, #12, #13, and #16.

## Codec

`SystemOneJson.decodeRequest` and `decodeResponse` accept exactly the documents that `schemas/system-one-v1.schema.json` accepts and return unmodifiable deep copies.
`encodeRequest` and `encodeResponse` validate their own output, so hand-built Dart objects with non-JSON values, empty maps, or out-of-range numbers are rejected before they reach a backend or caller.
Violations raise `SystemOneFormatException`, a `FormatException` with an RFC 6901 pointer; the request-side case is the Dart counterpart of the planned 422-equivalent status.
Integer fields accept integral JSON numbers that Dart parses as doubles, such as `12.0`, up to 2^53 − 1.
Explicit `null` values for `instructions`, Noul `criteria`, and `x_engine` are omitted on encode; other `x_` fields keep their `null` values.
Encoding rejects `xExtensions` keys that lack the `x_` prefix or duplicate `x_route`, `x_latency_ms`, or `x_engine`.

`SystemOneJson.checkAnswers` applies the cross-field rules that the schema leaves to runtime:

- every question has exactly one answer, and each answer has the question's type;
- Choice probabilities cover exactly the requested options, and `choice` is one of them;
- a Score legend has one entry per requested level, and its keys match the probability keys;
- each probability map sums to 1 within `SystemOneJson.probabilitySumTolerance` (`1e-2`).

The tolerance allows per-value rounding in remote responses; it is not the `1e-3` per-probability parity gate for local inference.
Score legend keys are not tied to level positions, and `choice` is not required to be the most probable option, because the upstream contract does not state either rule.

## Decisions

`Choice<T>`, `Noul`, and `Score` build wire question definitions; `Choice.fromEnum` names options after enum values.
`Evaluation` validates a response against typed questions and resolves each answer against a confidence threshold in `[0, 1]`: `Decided` when `confidence >= minConfidence`, otherwise `Uncertain`.
Both branches keep the raw probabilities keyed by wire names.
`choice<T>` returns the option's value, `noul` returns `noul >= 0.5`, and `score` returns the answer's weighted `score`.
The wire Noul answer has no confidence, so `noul` applies the Choice formula with two options, `|2 × noul − 1|`; remote Noul confidence may differ.
`choice<T>` checks that every option value is a `T` instead of checking the Choice's type argument, because a `Map<String, Question<Object?>>` context infers `Choice.fromEnum` as `Choice<Enum>`.

## Entrypoints

`SystemOneBackend` is the interface that local, remote, recording, and fake engines will implement.
`DecisionClient.evaluate` builds, validates, and sends a request from typed questions and returns an `Evaluation`.
`DecisionClient.evaluateJson` accepts a pasted `/v1/systemone` request map and returns the validated response map.
Both reject an invalid request before calling the backend and reject a response that fails the schema or `checkAnswers`.

## Verification

`schemas/fixtures/system-one-v1-cases.json` is checked by Ajv in `pnpm run schema:test` and by the Dart codec in `schema_agreement_test.dart`, which also derives required-field, undeclared-field, `x_` pattern, `type` constant, and `x_route` enum probes from the schema.
`dart test` in `packages/edge_one` covers Choice, Noul, Score, usage, extension fields, malformed data, answer pairing, decisions, and both client entrypoints.
