import 'dart:io';

import 'package:edge_one_flutter/src/pinned_model.dart';
import 'package:flutter/services.dart';
import 'package:test/test.dart';

final class MapAssetBundle extends CachingAssetBundle {
  MapAssetBundle(this.assets);

  final Map<String, Uint8List> assets;

  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(assets[key]!);
}

Future<Map<String, Uint8List>> bundledAssets() async => {
  for (final name in ['model_manifest.json', 'LICENSE', 'NOTICE'])
    'packages/edge_one_flutter/assets/$name': await File(
      'assets/$name',
    ).readAsBytes(),
};

void main() {
  test('bundled manifest and legal assets match the released model', () async {
    final assets = await bundledAssets();
    final bundle = MapAssetBundle(assets);
    final manifest = await loadPinnedModelManifest(bundle: bundle);
    expect(manifest.revision, 'edf37c26a1098f83cf4264b8adbe0dca2d2ebb0c');
    expect(manifest.bytes, 529296864);
    expect(
      manifest.sha256,
      '0a19bc29bacc33e0d871146c8612b24dd14c2ed2e61cedeb7a928b0852628bac',
    );
    expect(manifest.globalTemperature, 0.8800546821789332);
    expect(
      manifest.licenseSha256,
      'bbedc3fda3305820b977265f01b8619d87570a6739de3a5582c3464840f1e57a',
    );
    expect(
      manifest.noticeSha256,
      '5b20e266b5b9b9c12df4cb53db6801bc08fe8f1471355aaec15c1a9f9aa0b201',
    );
    final notices = await loadPinnedModelNotices(manifest, bundle: bundle);
    expect(notices.license, contains('Apache License'));
    expect(notices.notice, contains('chaoliangUNSW'));
  });

  test('altered manifest and legal assets are rejected', () async {
    final assets = await bundledAssets();
    const manifestKey = 'packages/edge_one_flutter/assets/model_manifest.json';
    const noticeKey = 'packages/edge_one_flutter/assets/NOTICE';
    assets[manifestKey]![0] ^= 1;
    await expectLater(
      loadPinnedModelManifest(bundle: MapAssetBundle(assets)),
      throwsFormatException,
    );
    assets[manifestKey] = await File(
      'assets/model_manifest.json',
    ).readAsBytes();
    assets[noticeKey]![0] ^= 1;
    await expectLater(
      loadPinnedModelManifest(bundle: MapAssetBundle(assets)),
      throwsFormatException,
    );
  });
}
