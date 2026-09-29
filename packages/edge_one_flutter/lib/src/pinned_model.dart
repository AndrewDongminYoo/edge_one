import 'package:flutter/services.dart';

import 'model_manifest.dart';

/// Load the app-shipped manifest after checking its compiled-in digest.
Future<ModelManifest> loadPinnedModelManifest({AssetBundle? bundle}) async {
  final data = await (bundle ?? rootBundle).load(
    'packages/edge_one_flutter/assets/model_manifest.json',
  );
  return ModelManifest.parseBundled(
    Uint8List.sublistView(
      data.buffer.asUint8List(),
      data.offsetInBytes,
      data.offsetInBytes + data.lengthInBytes,
    ),
    expectedSha256: pinnedModelManifestSha256,
  );
}
