# M1 Contract Scaffold Plan

## Goal

Close issue #7 with one versioned schema, reproducible Dart and TypeScript types, minimal package manifests, and a Linux CI drift gate.

## Steps and Checks

1. Define the OpenAPI-aligned JSON wire shape in `schemas/system-one-v1.schema.json`; verify valid and invalid fixtures with `pnpm run schema:test`.
2. Generate Dart and TypeScript types from that file; verify `pnpm run contracts:check` fails after a deliberate generated-file edit, then passes after regeneration.
3. Add Pub/Melos, pnpm, and CMake package scaffolds with lockfiles; verify `flutter pub get --enforce-lockfile`, `pnpm install --frozen-lockfile`, and language analyzers.
4. Put the checks in hosted Linux CI; verify the PR's contract job and existing gates before requesting merge.

## Boundary

The schema follows the upstream OpenAPI 0.2.0 base shape and adds local `x_` response extensions; live interoperability remains unverified.
No runtime inference, FFI, TurboModule, calibration algorithm, or publishing is included.
