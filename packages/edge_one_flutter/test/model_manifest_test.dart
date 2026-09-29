import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:edge_one_flutter/src/model_manifest.dart';
import 'package:test/test.dart';

const revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, Object?> fixture() => {
  'id': 'fixture-model',
  'revision': revision,
  'file': 'model.gguf',
  'sha256': List.filled(64, 'b').join(),
  'bytes': 4,
  'template': 'macjev-render-v1',
  'readout': 'verdict',
  'slot_tokens': {'yes': 1, 'no': 2, 'verdict_slot': 3},
  'temperature': {'global': 0.8800546821789332},
  'limits': {'max_options': 26, 'max_levels': 10, 'n_ctx': 2048},
  'license': 'Apache-2.0',
  'legal_assets': {
    'license_sha256': List.filled(64, 'c').join(),
    'notice_sha256': List.filled(64, 'd').join(),
  },
  'source': 'https://example.test/resolve/$revision/model.gguf',
  'mirrors': <String>[],
};

ModelManifest parseFixture(Map<String, Object?> json) {
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
  return ModelManifest.parseBundled(
    bytes,
    expectedSha256: sha256.convert(bytes).toString(),
  );
}

void main() {
  test('manifest requires a positive global readout temperature', () {
    final missing = fixture()..remove('temperature');
    expect(() => parseFixture(missing), throwsFormatException);
    final invalid = fixture()..['temperature'] = {'global': 0};
    expect(() => parseFixture(invalid), throwsFormatException);
  });

  test('manifest requires well-formed legal asset digests', () {
    final missing = fixture()..remove('legal_assets');
    expect(() => parseFixture(missing), throwsFormatException);
    final invalid = fixture()
      ..['legal_assets'] = {
        'license_sha256': 'bad',
        'notice_sha256': List.filled(64, 'd').join(),
      };
    expect(() => parseFixture(invalid), throwsFormatException);
  });

  test('source must use the pinned revision and file', () {
    final wrongRevision = fixture()
      ..['source'] = 'https://example.test/resolve/other/model.gguf';
    expect(() => parseFixture(wrongRevision), throwsFormatException);
  });
}
