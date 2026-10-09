import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'generated/edge_one_bindings.dart' as lookup;
import 'generated/edge_one_native.dart' as native;
import 'local_exception.dart';

/// Internal ABI adapter. The explicit library path is only for native tests.
final class NativeApi {
  NativeApi(String? libraryPath)
    : _bindings = libraryPath == null
          ? null
          : lookup.EdgeOneBindings(DynamicLibrary.open(libraryPath));

  final lookup.EdgeOneBindings? _bindings;

  int open(String modelPath, String manifestJson) => using((arena) {
    // Embedded NULs must never silently change a native path or payload.
    if (modelPath.contains('\u0000') || manifestJson.contains('\u0000')) {
      throw const LocalEngineException(422);
    }
    final path = modelPath.toNativeUtf8(allocator: arena).cast<Char>();
    final manifest = manifestJson.toNativeUtf8(allocator: arena).cast<Char>();
    final error = arena<Pointer<Char>>();
    try {
      final address = _bindings == null
          ? native.eo_open(path, manifest, error).address
          : _bindings.eo_open(path, manifest, error).address;
      if (address == 0) throw const LocalEngineException(503);
      return address;
    } finally {
      // eo_open error strings are owned even when open fails.
      free(error.value);
    }
  });

  String evaluate(int address, String json) => using((arena) {
    if (json.contains('\u0000')) throw const LocalEngineException(422);
    final request = json.toNativeUtf8(allocator: arena).cast<Char>();
    final status = arena<Int32>()..value = 503;
    final result = _bindings == null
        ? native.eo_evaluate(Pointer.fromAddress(address), request, status)
        : _bindings.eo_evaluate(Pointer.fromAddress(address), request, status);
    try {
      if (status.value != 200) throw LocalEngineException(status.value);
      if (result == nullptr) throw const LocalEngineException(503);
      try {
        return result.cast<Utf8>().toDartString();
      } on FormatException {
        throw const LocalEngineException(500);
      }
    } finally {
      // Copies are returned to Dart; every success/error buffer is freed here.
      free(result);
    }
  });

  void cancel(int address) {
    if (_bindings == null) {
      native.eo_cancel(Pointer.fromAddress(address));
    } else {
      _bindings.eo_cancel(Pointer.fromAddress(address));
    }
  }

  void close(int address) {
    if (_bindings == null) {
      native.eo_close(Pointer.fromAddress(address));
    } else {
      _bindings.eo_close(Pointer.fromAddress(address));
    }
  }

  void free(Pointer<Char> value) {
    if (_bindings == null) {
      native.eo_free(value);
    } else {
      _bindings.eo_free(value);
    }
  }
}
