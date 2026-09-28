# M1 System One Contract Scaffold

## Scope

Issue #7 establishes `schemas/system-one-v1.schema.json` as the source for request, question, answer, usage, and `x_` response fields.
The Dart and TypeScript outputs are generated data types, not a router, native binding, JSON codec, or proof of remote API compatibility.
The base shape was compared with the official [TypeSafe OpenAPI 0.2.0](https://api.typesafe.ai/openapi.json) on September 29, 2026 (retrieved JSON SHA-256 `a191f8a7df6bd6fedced8120dd0fd106f88575d1d1c8360d08900a6c7c0360d5`); live request/response interoperability remains a release gate.

## Contract Decisions

The request requires structured `state`, `model`, and a nonempty `questions` map.
Choice criteria map option names to string, object, array, or null descriptions.
The OpenAPI document does not encode the blueprint's 255-choice remote ceiling; the planned local 26-choice limit belongs in issue #8's 422-equivalent validation.
Score criteria contain at least one ordered string, object, or array level; the blueprint's planned local 2–10 level policy belongs in issue #8's validation, not the remote wire schema.
Noul criteria may be null or describe `true` and `false`.
All three questions accept structured or null `instructions`.
Answers carry required `type` discriminants; Score `legend` and `probabilities` are maps keyed by level.
The response requires `model`, a nonempty `answers` map, and `usage` with integer `input_tokens` and `output_tokens`.
Known `x_route`, `x_latency_ms`, and `x_engine` fields and additional `x_` fields are response-only.
Unlike OpenAPI's implicit allowance for undeclared object fields, this versioned local profile rejects unknown request, question, and answer fields and non-`x_` response fields; revisit that restriction before claiming full upstream wire compatibility.
The generated Dart types use `Object`/`Object?` aliases for structured JSON values and do not enforce string/object/array membership on their own.
Probability values are range-checked by the schema, while cross-field totals and question-to-answer matching require runtime checks in a later implementation.

## Verification

`pnpm run schema:test` validates representative positive and negative request/response fixtures.
`pnpm run contracts:check` compares both generated files with the source schema, including its SHA-256 digest.
`pnpm run types:check`, `dart analyze packages/edge_one`, and `flutter analyze packages/edge_one_flutter` check that the generated and exported types compile.
`dart run tools/check_dart_contract.dart` checks that integer-valued JSON numbers can enter Dart `num` fields without a `double` cast.
GitHub's Linux contract job runs these checks with pinned Node, pnpm, and Flutter versions.
