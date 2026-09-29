# edge_one

An on-device decision runtime planned for Flutter and React Native, with optional remote escalation.
The production API and architecture are described in [BLUEPRINT.md](BLUEPRINT.md).
The repository contains the M0 feasibility experiment and M1 contract scaffolding; production inference and mobile bindings are not available yet.

## System One contracts

`schemas/system-one-v1.schema.json` is the versioned source for the request, question, answer, usage, and `x_` extension shapes.
Its base fields were checked against [TypeSafe OpenAPI 0.2.0](https://api.typesafe.ai/openapi.json); runtime interoperability and release readiness remain unverified.
Generated Dart types live in `packages/edge_one/lib/src/generated/`; generated TypeScript types live in `packages/react-native-edge-one/src/generated/`.
Edit the schema and rerun generation instead of editing either output.
The generated Dart classes are typed data shapes, not JSON codecs or a running backend yet; validate wire data against the schema at a boundary.

From the repository root:

```bash
pnpm install --frozen-lockfile
pnpm run schema:test
pnpm run contracts:generate
pnpm run contracts:check
pnpm run types:check
flutter pub get --enforce-lockfile
dart run tools/check_dart_contract.dart
dart analyze packages/edge_one
flutter analyze packages/edge_one_flutter
```

The pnpm workspace contains the planned React Native package; the Melos/Pub workspace contains `edge_one`, `edge_one_flutter`, and `edge_one_calibrate`.
`packages/edge_one_core/` has a C++17 CMake target without inference sources yet.
GitHub's Linux contract job validates schema fixtures, generated drift, TypeScript, and the Dart workspace.
See the [contract specification](docs/specs/2026-09-29-m1-system-one-contract.md) for current limits.

## M0 Desktop Spike

The spike uses the selected model's original GGUF runtime and native scorer at pinned revisions.
It compares individual prefill with exact and batched prefix sharing for Choice, Noul, and Score questions.
Python is experimental tooling; the planned production core remains C++17.

Requires Python 3.12, [uv](https://docs.astral.sh/uv/), a C++17 compiler, and a native build toolchain.
On macOS, install the Xcode command-line tools and Metal toolchain before building.
CMake, NumPy, and tokenizers are installed in a local environment from the hashed lockfile.
NumPy and tokenizers are required by the upstream runtime; CMake builds the native scorer without a global installation.

Run from the repository root:

```bash
python3 -m unittest discover -s spikes/m0/tests -v
python3 spikes/m0/check_report.py docs/notes/2026-09-27-m0-desktop.json
uv venv --python 3.12 .cache/m0/.venv
uv pip sync --python .cache/m0/.venv/bin/python --require-hashes spikes/m0/requirements.lock
.cache/m0/.venv/bin/python spikes/m0/setup.py fetch
.cache/m0/.venv/bin/python spikes/m0/setup.py build --jobs 2
.cache/m0/.venv/bin/python spikes/m0/run.py --output .cache/m0/desktop.json --repetitions 5 --threads 4
```

Fetch downloads the Q4_K_M model (529,296,864 bytes), runtime, tokenizer, and native source.
It verifies the pinned manifest and file hashes before use.
Weights, upstream code, builds, logs, and the environment remain under ignored `.cache/m0/`.
Run one native build or inference job at a time.
An existing output report is never overwritten; choose a new filename for another run.

Each fixture runs in a fresh scorer process per mode, followed by repeated warm calls.
Memory is reset before every call, so warm measurements do not reuse a previous request's prefix.
First-request timings are separate from model startup, and OS caches are not controlled.
Exit code 1 indicates a completed probability comparison failed the strict `< 1e-3` gate; inspect the report instead of loosening the threshold.
Other errors may also exit nonzero and leave a `.partial` report.

## Results and Limits

See the [desktop report](docs/notes/2026-09-27-m0-desktop.md) and [raw results](docs/notes/2026-09-27-m0-desktop.json).
The small synthetic fixture set checks numerical parity and prefix-sharing behavior, not classification accuracy or mobile performance.
M0 still requires a separate iOS warm-latency measurement.
Remote calls, model publishing, and device writes are outside this spike.

## M0 Server Comparison

Approved redacted server exports can be compared with matching local scorer exports
using `spikes/m0/compare_server.py`. The tool verifies request and token-ID hashes,
reports per-question probability differences, and separates matching-version runtime
differences from model or scorer configuration drift. See the
[export specification](docs/specs/2026-09-28-m0-server-comparison.md) and synthetic
example fixtures; no server credentials or private request contents are stored here.

## Development

Keep specs in `docs/specs/`, plans in `docs/plans/`, and measurements in `docs/notes/`.
The approved [M0 plan](docs/plans/2026-09-27-m0-desktop-spike.md) records the readout correction and acceptance criteria.

```bash
trunk check --no-fix
uv pip compile spikes/m0/requirements.in --python-version 3.12 --generate-hashes -o spikes/m0/requirements.lock
```

The first command checks changed files with the repository's configured linters.
Run the second only when changing experimental dependencies and include both input and lockfile in the same change.
Preserve the upstream model's LICENSE and NOTICE with downloaded artifacts.

GitHub Actions runs the unit tests and validates archived measurements against current fixture and model pins.
It also builds the pinned native scorer on Ubuntu, requires exact-prefix numerical parity with one warm sample, and builds unsigned iPhone and simulator apps on a hosted macOS runner.
The `ios-27-numerical` job checks Xcode 27, the iOS 27 simulator and the Metal tool before building and running `NativeRepro` on a hosted iPhone simulator.
It compares direct CPU and Metal logits against the fixed desktop reference with a strict probability difference below `1e-3`; missing runner support or failed parity fails the job, with preflight, raw logits and summary uploaded when available.
The Linux run still records batched-prefix results, but batched sharing remains experimental and is not a required production gate.
Each new gate summary identifies its worst fixture, phase, sample, and question; see the [Linux batched-drift investigation](docs/notes/2026-09-28-m0-linux-batched-drift.md) for the observed failures and promotion criteria.
The report checker recomputes probability gates, native sharing observations, and timing summaries from stored records.
CI build evidence excludes the 0.53 GB model and is retained for three days; a hosted build does not establish physical-device placement or sustained latency.
Simulator numerical parity alone does not prove that GPU layers were placed on physical hardware.

## Hosted Linux setup

For Codex Cloud, select the universal Linux image, set Python to 3.12, and configure the environment setup command as `bash setup.sh`.
The script creates `.cache/m0/.venv` from the hash-locked requirements and checks for a C++ compiler and build tool.
It also installs the Trunk launcher to `/usr/local/bin/trunk`, downloads the CLI version, runtimes, and linters pinned in `.trunk/trunk.yaml`, and syncs Trunk's git hooks, so the agent phase does not need to download tools before `trunk check`.
It is safe to run again after a cached environment resumes.
The setup phase has network access, while agent-phase access depends on the cloud environment setting.
For a native task that needs the pinned 0.53 GB model, set `EDGE_ONE_FETCH_MODEL=1` in that environment so the setup phase runs the repository's verified fetcher; leave it unset for contract, documentation, and unit-test tasks.
The cloud environment must invoke the repository command explicitly; the universal image's own initialization is separate.
The local Docker daemon was unavailable when this setup was added, so the GitHub Ubuntu job is the Linux execution check and an actual Codex Cloud run remains to be observed.

## M0 iOS Spike

Host inference and unsigned iOS/simulator arm64 builds have passed.
Two observed [iPhone 16 Pro reports](docs/notes/2026-09-28-m0-ios-device-validation.md) pass the physical report-format and numerical gates; actual GPU layer placement was not independently observed.
Simulator CPU parity passes, while the default simulator Metal path fails parity; see the [validation record](docs/notes/2026-09-27-m0-ios-validation.md).
The [direct native diagnostic](docs/notes/2026-09-28-m0-metal-diagnostic.md) reproduces the simulator Metal failure without Scorer or Swift; its root cause remains unverified despite the passing requested-profile iPhone report.
Both SDK builds and source receipts were refreshed after the model-integrity repair; the wrong-model rejection test passes.
The experimental SwiftUI app calls the pinned native Scorer in process.
It verifies model and fixture SHA-256, loads one context, resets memory before each request, and exports the first request plus 20 warm samples.
The physical-device run then continues in the same context for at least two minutes, recording each request and its ending thermal state; the simulator runs a two-second format probe that is not performance evidence.
The request is rendered and tokenized on the Mac; timings cover native scoring, its internal memory resets and verdict softmax, excluding the outer reset, tokenization, hashing, loading and export.
These timings are not the production API's end-to-end latency.

Requires the desktop M0 environment, Xcode with its Metal toolchain, and an existing XcodeGen installation.
Build one target at a time from the repository root:

```bash
.cache/m0/.venv/bin/python spikes/m0/ios/prepare.py
.cache/m0/.venv/bin/python spikes/m0/ios/build.py --sdk host
.cache/m0/.venv/bin/python spikes/m0/ios/build.py --sdk iphoneos --jobs 2
# Build the simulator separately when needed.
.cache/m0/.venv/bin/python spikes/m0/ios/build.py --sdk iphonesimulator --jobs 2
```

The host target is a smoke-test binary at `.cache/m0/ios/host/m0-host`; it accepts model and fixture filenames and prints a report with two warm samples.
App projects, bundled model/license resources, source/library receipts and unsigned Release products are generated under `.cache/m0/ios/<sdk>/`.
Change the generator or source files instead of editing generated projects.
The build command refuses to start when the one-minute load exceeds the detected CPU count.
An unsigned build still needs local signing before physical-device installation.
`M0_CPU_ONLY=1` disables GPU layers and operation/KV offload for a diagnostic run; the report records these settings.
The simulator CPU XCTest checks completed run counts and the export button across repeated runs.
Other targeted diagnostic tests check fusion, shared buffers and direct upstream decoding; select a single test with `xcodebuild -only-testing:<target>/<class>/<method>` and keep parallel testing disabled.
The direct repro's `--invalid-model` test selects the bundled JSON fixture as a wrong model input and requires SHA-256 rejection before backend/model initialization.
Validate the exported JSON separately: a passing UI test does not establish numerical parity.

After exporting a report to a new local filename:

```bash
python3 spikes/m0/ios/report.py path/to/m0-ios-report.json --fixture .cache/m0/ios/fixture.json --require-device-metadata
```

The reader recomputes distributions from native yes/no scores, checks baseline and sustained samples against the desktop reference with the strict `1e-3` gate, and calculates warm and final 30-second sustained-tail medians separately.
The reader validates the declared Release/arm64 build receipt and timing boundary; `declared_physical_ios` describes metadata, not independently verified execution origin.
`--require-device-metadata` additionally requires exactly 20 warm samples, at least two minutes of continued scoring with 10 final-window samples and complete thermal readings, plus the default requested Metal profile: 999 GPU layers, operation/KV offload enabled, and neither diagnostic Metal switch requested.
CPU-only, modified and missing backend settings are rejected by that CLI gate even when numerical parity passes; recorded settings still do not independently prove GPU execution.
Physical-device acceptance additionally requires an observed approved run and export from the connected iPhone, comparison with its local build receipt, and review of the first, warm and sustained conditions.
Omit `--require-device-metadata` when validating a host or simulator smoke test.
The [iOS spec](docs/specs/2026-09-27-m0-ios-spike.md) and [plan](docs/plans/2026-09-27-m0-ios-spike.md) define the remaining build and device checks.
