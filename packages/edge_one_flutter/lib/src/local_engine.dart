import 'dart:convert';

import 'package:edge_one/edge_one.dart';

import 'local_exception.dart';
import 'model_store.dart';
import 'native_engine.dart';

/// A local backend with a dedicated long-lived native evaluation isolate.
final class LocalEngine implements SystemOneBackend {
  LocalEngine._(this._native);

  final NativeEngine _native;

  /// Opens bytes already verified by [ModelStore].
  /// The caller must keep the backing file immutable and untruncated from
  /// before open until the last engine using those bytes finishes [dispose].
  /// Do not replace, delete, or redownload the file while any engine is open.
  static Future<LocalEngine> open(VerifiedModel model) =>
      openLocalEngine(model);

  @override
  Future<SystemOneResponse> evaluate(SystemOneRequest request) async {
    final snapshot = SystemOneJson.decodeRequest(
      SystemOneJson.encodeRequest(request),
    );
    final json = await _native.evaluate(
      jsonEncode(SystemOneJson.encodeRequest(snapshot)),
    );
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) {
        throw const LocalEngineException(500);
      }
      final response = SystemOneJson.decodeResponse(decoded);
      SystemOneJson.checkAnswers(snapshot.questions, response);
      return response;
    } on FormatException {
      throw const LocalEngineException(500);
    }
  }

  Future<void> cancel() => _native.cancel();

  /// Rejects new calls immediately; completes after native callers and close.
  /// Repeated calls share the same completion.
  Future<void> dispose() => _native.dispose();
}

// Internal test seam: production uses the bundled native asset.
Future<LocalEngine> openLocalEngine(
  VerifiedModel model, {
  String? libraryPath,
}) async {
  final manifest = model.manifest;
  final native = await NativeEngine.open(
    modelPath: model.file.absolute.path,
    libraryPath: libraryPath,
    manifestJson: jsonEncode({
      'id': manifest.id,
      'revision': manifest.revision,
      'file': manifest.file,
      'sha256': manifest.sha256,
      'bytes': manifest.bytes,
      'template': manifest.template,
      'readout': manifest.readout,
      'slot_tokens': manifest.slotTokens,
      'temperature': {'global': manifest.globalTemperature},
      'limits': manifest.limits,
    }),
  );
  return LocalEngine._(native);
}
