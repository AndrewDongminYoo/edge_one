#!/usr/bin/env bash
set -euo pipefail

ffi_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ffi_build="$ffi_root/.cache/m0/ffi-lifecycle"
ffi_cmake="${EDGE_ONE_CMAKE:-cmake}"

"$ffi_cmake" -S "$ffi_root/packages/edge_one_core" -B "$ffi_build/core" \
  -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_OPENMP=OFF
"$ffi_cmake" --build "$ffi_build/core" --parallel 2
ctest --test-dir "$ffi_build/core" --output-on-failure

"$ffi_cmake" -S "$ffi_root/packages/edge_one_flutter/test/native" -B "$ffi_build/probe" \
  -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=Debug \
  "-DLLAMA_SOURCE=$ffi_build/core/_deps/llama_cpp-src"
"$ffi_cmake" --build "$ffi_build/probe" --parallel 2
case "$(uname -s)" in
  Darwin) ffi_library="$ffi_build/probe/libedge_one_ffi_test.dylib" ;;
  Linux) ffi_library="$ffi_build/probe/libedge_one_ffi_test.so" ;;
  *) echo 'FFI lifecycle tests currently support macOS and Linux' >&2; exit 1 ;;
esac

cd "$ffi_root/packages/edge_one_flutter"
EDGE_ONE_FFI_TEST_LIBRARY="$ffi_library" flutter test --reporter expanded "$@"
