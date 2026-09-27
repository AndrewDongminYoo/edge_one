# Repository Guidelines

## Project Structure & Module Organization

This repository is at the blueprint stage: `BLUEPRINT.md` defines the planned on-device decision runtime; source packages, tests, and build manifests are not yet present.
Keep specifications in `docs/specs/`, implementation plans in `docs/plans/`, and working notes in `docs/notes/`.

The planned monorepo uses Melos and pnpm workspaces:

- `edge_one_core`: shared C++17/CMake inference core with a pinned llama.cpp submodule.
- `edge_one`: pure Dart contract types and routing, without Flutter dependencies.
- `edge_one_flutter`: Flutter FFI integration and model storage.
- `react-native-edge-one`: TypeScript and C++ TurboModule bindings.
- `edge-one-calibrate`: Dart CLI for temperature and threshold fitting.

Package directory locations remain to be established.
Generate Dart and TypeScript contract types from one JSON Schema; change the schema rather than generated output.

## Build, Test, and Development Commands

No runnable build or test workflow exists yet.
When scaffolding packages, document exact working directories and scripts.
The following are intended package-level checks once the corresponding manifests exist:

- `dart format <paths>`: format explicitly selected Dart files.
- `dart analyze` and `dart test`: analyze and test pure Dart packages.
- `flutter analyze` and `flutter test`: analyze and test Flutter packages.

Define native CMake and pnpm scripts during scaffolding; do not assume root-level commands already work.

## Coding Style & Naming Conventions

Use standard Dart formatting, `snake_case.dart` filenames, and `UpperCamelCase` types.
Establish TypeScript and C++ formatter configurations before expanding those packages.
Keep inference off the UI thread and platform behavior inside bindings.
Preserve the System One JSON contract and isolate extension fields with `x_` prefixes.

## Testing Guidelines

No test framework configuration or coverage threshold exists yet.
Use `test/*_test.dart` for Dart and Flutter tests when scaffolded.
Prioritize contract fixtures, delimiter escaping, question-level routing, cancellation, and model integrity checks.
Validate shared-prefix inference against separate prefill, targeting probability differences below `1e-3` as specified in the blueprint.
Report benchmark device, model revision, and cold/warm/sustained conditions.

## Commit & Pull Request Guidelines

There is no commit history to establish conventions.
Use concise Conventional Commit messages, such as `feat(core): validate choice requests`.
Include the problem, scope, verification commands and results, and relevant issues in PR descriptions.
Attach screenshots for demo UI changes and measured evidence for performance claims.

## Security & Configuration

Default to local-only routing; require consent and masking before remote requests.
Keep API keys out of Git.
Pin model revisions, verify SHA-256 hashes, and validate manifests before loading models.
