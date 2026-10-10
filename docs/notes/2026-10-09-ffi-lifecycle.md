# FFI and lifecycle slice verification

This is a partial implementation of [issue #11](https://github.com/AndrewDongminYoo/edge_one/issues/11), based on main `9f312e5a01b34f66f010e2ac6957208b6f040b1f`.
The feature commit is `212eac213166b519776bb566ee4b6362f463d9b6`.
The final read-only GitHub recheck still showed that main and open scorer [PR #42](https://github.com/AndrewDongminYoo/edge_one/pull/42) at `1df8d9312d3ed9c00e004cd02eaaf45baba58c48`.
No duplicate FFI implementation was found in the inspected local branches/worktrees or remote branches/open PRs.
The original checkout's staged and unstaged C API work was preserved in place; implementation used an independent local repository and linked worktree.
No relevant entry was found in the permitted Codex `memory_summary.md` lookup.

## Implemented behavior

Generated lookup and native asset bindings expose the existing five-function C ABI.
`LocalEngine` implements the Dart backend contract and snapshots mutable requests before awaiting native work.
One long-lived evaluation isolate retains each engine, while a separate control isolate delivers cancellation during blocking native evaluation.
Cancellation is latched and retried until the evaluation returns, so an early idle cancel cannot be lost at native entry.
Competing calls return busy; disposal rejects new calls, drains native callers, joins the control isolate, and closes the handle exactly once.
Cleanup continues after a control worker error and reports the first cleanup failure.
Owned success/error buffers are released with `eo_free` on every tested path.
The caller is responsible for keeping model backing bytes immutable and untruncated through the last close.

The hook builds the unchanged main CMake target with CPU-only llama/ggml linked statically into the bundled core.
No production scorer or model download was added.
The native blocking library reuses the existing `TestBackend/Probe` seam and is compiled only by the separate test target.
`tools/test_ffi_lifecycle.sh` reproduces native CTest and all Flutter tests from a clean build directory using hash-pinned source.

## Observed checks

Tests ran on macOS arm64 with Flutter 3.47.7 and Dart 3.13.5.
These gates inspect native ownership/caller ordering, contract behavior, generated drift, and build packaging; they do not establish real model inference.

| Check                               | Command or procedure                                                                                                                                                                                                    | Observed result                                                                                                                                                                                          |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Native CTest and Flutter regression | `bash tools/test_ffi_lifecycle.sh`                                                                                                                                                                                      | CTest 4/4; Flutter 47 passed                                                                                                                                                                             |
| Native blocking coverage            | Same helper, `test/native_engine_test.dart`                                                                                                                                                                             | Active and pre-entry cancellation, responsiveness, busy, delayed cancel/dispose, idle control worker exit, repeated close, separate engines, error ownership, malformed result, mutable request snapshot |
| Real bundled ABI                    | Direct generated `@Native` calls in the Flutter suite                                                                                                                                                                   | All five symbols resolved; expected native errors and owned frees checked without a model                                                                                                                |
| Pure Dart backend/contracts         | `dart test --reporter expanded` in `packages/edge_one`                                                                                                                                                                  | 287 passed                                                                                                                                                                                               |
| Calibration regression              | Same command in `packages/edge-one-calibrate`                                                                                                                                                                           | 75 passed; 1 skipped                                                                                                                                                                                     |
| Benchmark regression                | Same command in `packages/edge-one-benchmark`                                                                                                                                                                           | 65 passed                                                                                                                                                                                                |
| Consumer assets                     | `flutter test --reporter expanded` in `example/asset_host`                                                                                                                                                              | 1 passed; consumer lockfile regenerated                                                                                                                                                                  |
| Generation                          | Run both ffigen configs and compare SHA-256 before/after                                                                                                                                                                | Both files reproduced byte-for-byte                                                                                                                                                                      |
| Dart formatting                     | `dart format --output=none --set-exit-if-changed packages/edge_one_flutter/lib packages/edge_one_flutter/hook packages/edge_one_flutter/test/native_engine_test.dart`                                                   | 12 files; 0 changed                                                                                                                                                                                      |
| C++ formatting                      | Pinned clang-format 21.1.8 with core's `.clang-format`, scoped to the three changed C++ test files                                                                                                                      | Applied before the final helper run                                                                                                                                                                      |
| Lockfile                            | `flutter pub get --enforce-lockfile`                                                                                                                                                                                    | Passed                                                                                                                                                                                                   |
| Dart contract check                 | `dart run tools/check_dart_contract.dart`                                                                                                                                                                               | Passed                                                                                                                                                                                                   |
| Analysis                            | `dart analyze packages/edge_one`; `flutter analyze packages/edge_one_flutter`                                                                                                                                           | No issues                                                                                                                                                                                                |
| Trunk                               | `trunk check --no-fix` and normal pre-commit hook                                                                                                                                                                       | Passed for the feature commit                                                                                                                                                                            |
| macOS build                         | Task-local consuming fixture; `flutter build macos --release` with `FLUTTER_XCODE_CODE_SIGNING_ALLOWED=NO`, `FLUTTER_XCODE_CODE_SIGNING_REQUIRED=NO`, `FLUTTER_XCODE_ARCHS=arm64`, `FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES` | Release app built; arm64 executable and core framework inspected                                                                                                                                         |
| macOS bundle linkage                | `otool -L` on the embedded core framework                                                                                                                                                                               | Only system/Accelerate/libc++ dependencies; no separate llama/ggml dylibs                                                                                                                                |

The macOS executable has the linker's ad-hoc signature, no development team, and no sealed resources; no signing identity or account configuration was changed.
The app was built, not launched for a runtime smoke test.
The native build helper fetches source only, never weights.
New Dart dependencies came from pub.dev; the standalone formatter came from PyPI.
No security configuration or persistent credentials were changed.

### Regression power

Cancellation retry removal made the named pre-entry test fail: expected native 499, received 500 after the blocking test barrier timed out.
Restoring the retry passed the final Flutter suite.
The mutable criteria regression failed with status 500 before the snapshot fix and passed after it.
Reverting cleanup to stop at the control-worker error made the close-count assertion fail: expected 1, actual 0.
Restored cleanup passed the final suite.

The targeted commands, run from `packages/edge_one_flutter` with the native fixture environment, were:

- `flutter test --reporter expanded test/native_engine_test.dart --plain-name 'cancellation before native entry is latched until evaluate becomes active'`: retry removal failed with expected 499 versus actual 500.
- `flutter test --reporter expanded test/native_engine_test.dart --plain-name 'LocalEngine snapshots mutable criteria before native evaluation'`: the unfixed implementation failed with status 500.
- `flutter test --reporter expanded test/native_engine_test.dart --plain-name 'control worker exit still joins and closes the evaluation worker'`: interrupted cleanup failed with expected close count 1 versus actual 0.

Fix: `native_engine.dart` cancellation/disposal and `local_engine.dart` request snapshot preserve cancellation intent, caller ordering, and validation identity.
Mutation proof: the three failures above were observed; restored code passed `bash tools/test_ffi_lifecycle.sh`.
Blast radius: `LocalEngine` is the new native caller; `DecisionClient` and `RemoteBackend` follow the same snapshot/response-validation boundary, with their 287-test package suite passing.
Invariant: close occurs after every native evaluate/cancel caller has returned; native ABI adapters and the native lifecycle tests are the other sites found in the scoped search.
Suite: native CTest 4/4 and Flutter 47 passed on the final helper run.

### Independent review

Two read-only reviewers independently checked lifecycle/ownership and build/binding behavior.
They found the mutable request validation race and implicit multi-config generator assumption; both were repaired.
The hook explicitly selects `Unix Makefiles`, and Flutter tests also passed under `CMAKE_GENERATOR=Xcode`.
The lifecycle review's conditional cleanup concern was addressed with continued cleanup and control-exit fault injection.
Both reviewers reported no remaining concrete defects on the follow-up review.

## Integration boundaries and remaining acceptance

PR #42's CMake, scorer, engine, public header, and `model_store` files were not changed or copied.
The PR-loop follow-up adds one helper invocation to the existing CI contracts job; this is the only workflow integration conflict to reconcile with PR #42.
The only existing native test file changed is `tests/api_test.cpp`, which extracts its test backend into a shared test header.
Recheck the hook, generated bindings, manifest dependency tracking, and full regression suite after the scorer lands.
Current main still has the staged unavailable scorer; this work does not demonstrate successful model open or normal inference.

Hosted macOS iOS arm64 build, hosted app smoke, physical-device execution, macOS x64, and Linux hook validation were not run.
Android/Windows hooks and Metal integration remain outside this slice.
The existing CI contracts job now invokes the native lifecycle helper, including the blocking test double and bundled ABI tests.
Its exact-HEAD hosted result is required for this slice. The M0 unsigned iOS job does not validate this Flutter hook.
Standalone pub packaging of the sibling core is also deferred.
Issue #11 must remain open until its Apple build/runtime acceptance and dependency work have evidence.

The original implementation was local-only; user authorization subsequently published PR #46 and resumed bounded review.
No issue closure, merge, deployment, or model/user-data download was performed.
