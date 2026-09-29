import 'package:edge_one_flutter/edge_one_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:test/test.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  test('a host loads the pinned manifest and upstream notices', () async {
    final manifest = await loadPinnedModelManifest();
    final notices = await loadPinnedModelNotices(manifest);
    expect(manifest.globalTemperature, 0.8800546821789332);
    expect(notices.license, contains('Apache License'));
    expect(notices.notice, contains('chaoliangUNSW'));
  });
}
