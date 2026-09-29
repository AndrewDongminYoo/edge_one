# M1 Dart Decision API Plan

## Goal

Close issue #10 with a pure Dart codec, Decision API, and raw JSON entrypoint that agree with the versioned schema and pass `dart analyze` and `dart test` on Linux.

## Steps and Checks

1. Add an opt-in, SHA-256-verified Flutter 3.47.5 install to `setup.sh`; verify `EDGE_ONE_INSTALL_FLUTTER=1 bash setup.sh` installs Dart 3.13.4 and `flutter pub get --enforce-lockfile` succeeds.
2. Add `SystemOneJson` and a shared request/response corpus; verify Ajv and the Dart codec agree on every case and that removing a required-field or undeclared-field check fails `dart test`.
3. Add `Choice`, `Noul`, `Score`, `Decision<T>`, and `Evaluation`; verify decisions, thresholds, accessor misuse, and answer pairing with unit tests.
4. Add `SystemOneBackend` and `DecisionClient`; verify invalid requests never reach the backend and invalid responses are rejected on both entrypoints.
5. Run `dart test` in the Linux contract job alongside the existing contract checks.

## Boundary

No local inference, request limits, prompt rendering, remote transport, routing, calibration, or recording is included.
Remote Noul confidence, Score legend key semantics, and live TypeSafe interoperability remain unverified.
