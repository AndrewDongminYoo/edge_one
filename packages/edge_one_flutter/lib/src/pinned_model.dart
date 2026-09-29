import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';

import 'model_manifest.dart';

/// Load the app-shipped manifest after checking its compiled-in digest.
Future<ModelManifest> loadPinnedModelManifest({AssetBundle? bundle}) async {
  final selectedBundle = bundle ?? rootBundle;
  final data = await selectedBundle.load(
    'packages/edge_one_flutter/assets/model_manifest.json',
  );
  final manifest = ModelManifest.parseBundled(
    _bytes(data),
    expectedSha256: pinnedModelManifestSha256,
  );
  await loadPinnedModelNotices(manifest, bundle: selectedBundle);
  return manifest;
}

/// Return verified upstream text for the host app's open-source notices.
Future<({String license, String notice})> loadPinnedModelNotices(
  ModelManifest manifest, {
  AssetBundle? bundle,
}) async {
  final selectedBundle = bundle ?? rootBundle;
  Future<String> verifiedText(String name, String expectedSha256) async {
    final data = await selectedBundle.load(
      'packages/edge_one_flutter/assets/$name',
    );
    final bytes = _bytes(data);
    if (crypto.sha256.convert(bytes).toString() != expectedSha256) {
      throw FormatException('Bundled $name digest mismatch');
    }
    return utf8.decode(bytes);
  }

  return (
    license: await verifiedText('LICENSE', manifest.licenseSha256),
    notice: await verifiedText('NOTICE', manifest.noticeSha256),
  );
}

Uint8List _bytes(ByteData data) => Uint8List.sublistView(
  data.buffer.asUint8List(),
  data.offsetInBytes,
  data.offsetInBytes + data.lengthInBytes,
);
