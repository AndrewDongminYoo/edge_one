# Flutter local engine

`LocalEngine` implements `SystemOneBackend` using the existing `eo_open`, `eo_evaluate`, `eo_cancel`, `eo_close`, and `eo_free` ABI.
It retains one evaluation isolate and one cancellation isolate per engine.
Blocking inference never runs in the caller isolate.
Competing evaluations fail with status 409 rather than entering an unbounded queue.

Open a `VerifiedModel` returned by `ModelStore` with `await LocalEngine.open(model)`.
The caller must keep its backing bytes immutable and untruncated from before open until the last engine using those bytes has completed `dispose()`.
Do not delete, replace, truncate, or redownload that backing file while an engine remains open.
`VerifiedModel` is a verification result, not a file lease; this wrapper does not coordinate other processes or model stores.

`cancel()` latches a request for the active evaluation.
The independent control isolate retries `eo_cancel` until the evaluation returns, including when the first cancellation arrived before native evaluation began.
Idle cancellation has no effect on the next evaluation.
Completion can win a race with cancellation.
`dispose()` blocks new evaluate/cancel calls immediately, drains active evaluation and cancellation callers, stops the control worker, and then closes the handle on the evaluation worker.
Repeated disposal returns the same future.
Worker failures preserve a cleanup error while remaining live workers are joined and closed.
Native statuses 409, 422, 499, 500, and 503 map to `LocalEngineException.kind`; calls after disposal throw `StateError`.
Each native result/error is copied into Dart and released with `eo_free`, including failure paths.

## Native build

The build hook uses the sibling `edge_one_core` CMake project and its hash-pinned source download, without downloading model weights.
Use Dart 3.10 or later and put CMake 3.24 or later and Make on `PATH`.
The package is currently workspace-only, as declared by `publish_to: none`.
Standalone pub distribution needs an additional source packaging decision.
The hook supports native macOS/Linux builds and declares Apple iOS cross-target flags.
It selects `Unix Makefiles`, statically links llama/ggml into one bundled core library, and uses consistent Apple install names.
This baseline uses CPU inference; Metal, Android, and Windows build integration are outside this slice.
Apple iOS arm64 and simulator acceptance still require their own build and app smoke evidence.

## Verification and generation

From the repository root, run:

```sh
flutter pub get --enforce-lockfile
bash tools/test_ffi_lifecycle.sh
flutter analyze packages/edge_one_flutter
```

The helper builds native CTest targets and a separate blocking `TestBackend/Probe` library, then runs all Flutter tests with its explicit library path.
The test scorer is never compiled into the production hook target.
The tests require this fixture instead of silently skipping native lifecycle coverage.
They also call all five bundled `@Native` ABI functions directly without opening a model.

Regenerate both binding sets from the C header:

```sh
cd packages/edge_one_flutter
dart run ffigen --config ffigen.yaml
dart run ffigen --config ffigen_native.yaml
```

The generated lookup bindings support the isolated native test library; production uses the generated native asset bindings.
Generation currently emits ffigen's YAML deprecation warning and the expected warning for the opaque `eo_engine` declaration.
See the lifecycle verification note for local evidence and outstanding issue #11 acceptance.
