# Repository Guidelines

## Project Structure & Module Organization

`BLUEPRINT.md` defines the planned on-device decision runtime.
`spikes/m0/` contains the implemented desktop and iOS feasibility experiments; production packages are not yet present.
Python tests live in `spikes/m0/tests/`, iOS app and UI tests in `spikes/m0/ios/`, and measured records in `docs/notes/`.
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

From the repository root, run `python3 -m unittest discover -s spikes/m0/tests -v` for unit tests and `python3 spikes/m0/check_report.py docs/notes/2026-09-27-m0-desktop.json` for archived numerical evidence.
On hosted Linux, `bash setup.sh` creates the hash-locked Python environment; set `EDGE_ONE_FETCH_MODEL=1` only for native inference work.
See `README.md` for pinned model fetch, native build, and iOS commands.
The following checks apply once production packages are scaffolded:

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

M0 uses Python `unittest` and iOS XCTest; no coverage threshold is set.
Use `test/*_test.dart` for Dart and Flutter tests when scaffolded.
Prioritize contract fixtures, delimiter escaping, question-level routing, cancellation, and model integrity checks.
Validate shared-prefix inference against separate prefill, targeting probability differences below `1e-3` as specified in the blueprint.
Report benchmark device, model revision, and cold/warm/sustained conditions.

## Commit & Pull Request Guidelines

History uses concise Conventional Commit messages, such as `feat(m0): validate pinned desktop inference and prefix sharing`.
Include the problem, scope, verification commands and results, and relevant issues in PR descriptions.
Attach screenshots for demo UI changes and measured evidence for performance claims.

## Security & Configuration

Default to local-only routing; require consent and masking before remote requests.
Keep API keys out of Git.
Pin model revisions, verify SHA-256 hashes, and validate manifests before loading models.
Linux CI owns unit, archived-report, native-build, and exact-prefix desktop parity checks; hosted macOS CI owns unsigned Apple builds.
Do not infer physical-device GPU placement, simulator Metal parity, or sustained thermal behavior from those jobs.
