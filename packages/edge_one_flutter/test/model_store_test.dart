import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:edge_one_flutter/src/model_manifest.dart';
import 'package:edge_one_flutter/src/model_store.dart';
import 'package:test/test.dart';

const revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const modelName = 'model.gguf';
final modelBytes = utf8.encode('good');

ModelManifest fixtureManifest({List<String> mirrors = const []}) {
  final json = {
    'id': 'fixture-model',
    'revision': revision,
    'file': modelName,
    'sha256': sha256.convert(modelBytes).toString(),
    'bytes': modelBytes.length,
    'template': 'macjev-render-v1',
    'readout': 'verdict',
    'slot_tokens': {'yes': 1, 'no': 2, 'verdict_slot': 3},
    'limits': {'max_options': 26, 'max_levels': 10, 'n_ctx': 2048},
    'license': 'Apache-2.0',
    'source': 'https://example.test/resolve/$revision/$modelName',
    'mirrors': mirrors,
  };
  return parseFixture(json);
}

ModelManifest parseFixture(Map<String, Object?> json) {
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
  return ModelManifest.parseBundled(
    bytes,
    expectedSha256: sha256.convert(bytes).toString(),
  );
}

ModelResponse response(
  List<int> bytes, {
  int status = HttpStatus.ok,
  String? range,
  int? length,
}) => ModelResponse(
  statusCode: status,
  body: Stream.value(bytes),
  contentRange: range,
  contentLength: length ?? bytes.length,
);

final class FakeTransport implements ModelTransport {
  FakeTransport(this.reply);

  final Future<ModelResponse> Function(Uri url, int start) reply;
  final requests = <(Uri, int)>[];

  @override
  Future<ModelResponse> get(Uri url, {required int start}) {
    requests.add((url, start));
    return reply(url, start);
  }
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('edge-one-model-store-');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('app-pinned manifest matches the M0 model and rejects edits', () async {
    final bytes = await File('assets/model_manifest.json').readAsBytes();
    final manifest = ModelManifest.parseBundled(
      Uint8List.fromList(bytes),
      expectedSha256: pinnedModelManifestSha256,
    );
    expect(manifest.bytes, 529296864);
    expect(
      manifest.sha256,
      '0a19bc29bacc33e0d871146c8612b24dd14c2ed2e61cedeb7a928b0852628bac',
    );
    bytes[0] ^= 1;
    expect(
      () => ModelManifest.parseBundled(
        Uint8List.fromList(bytes),
        expectedSha256: pinnedModelManifestSha256,
      ),
      throwsFormatException,
    );
  });

  test(
    'unexpected source revision is rejected even with a matching digest',
    () {
      final valid = fixtureManifest();
      expect(valid.revision, revision);
      final json = {
        'id': 'fixture-model',
        'revision': revision,
        'file': modelName,
        'sha256': sha256.convert(modelBytes).toString(),
        'bytes': modelBytes.length,
        'template': 'macjev-render-v1',
        'readout': 'verdict',
        'slot_tokens': {'yes': 1, 'no': 2, 'verdict_slot': 3},
        'limits': {'max_options': 26, 'max_levels': 10, 'n_ctx': 2048},
        'license': 'Apache-2.0',
        'source': 'https://example.test/resolve/other/$modelName',
        'mirrors': <String>[],
      };
      expect(() => parseFixture(json), throwsFormatException);
    },
  );

  test('wrong hash rejects primary and accepts a verified mirror', () async {
    final manifest = fixtureManifest(
      mirrors: ['https://mirror.test/model.gguf'],
    );
    final transport = FakeTransport((url, start) async {
      return response(
        url.host == 'example.test' ? utf8.encode('evil') : modelBytes,
      );
    });
    final store = ModelStore(
      root: root,
      manifest: manifest,
      transport: transport,
      freeBytes: (_) async => 100,
    );
    final verified = await store.ensure();
    expect(await verified.file.readAsBytes(), modelBytes);
    expect(transport.requests.map((request) => request.$2), [0, 0]);
    expect(await File('${verified.file.path}.part').exists(), isFalse);
  });

  test(
    'truncated range leaves only a partial file and no verified path',
    () async {
      final manifest = fixtureManifest();
      final partial = File(
        '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}.part',
      );
      await partial.writeAsBytes(modelBytes.sublist(0, 2));
      final transport = FakeTransport(
        (_, start) async => ModelResponse(
          statusCode: HttpStatus.partialContent,
          body: Stream.value(modelBytes.sublist(2, 3)),
          contentRange: 'bytes 2-3/4',
        ),
      );
      final store = ModelStore(
        root: root,
        manifest: manifest,
        transport: transport,
        freeBytes: (_) async => 100,
      );
      await expectLater(store.ensure(), throwsA(isA<ModelDownloadException>()));
      expect(transport.requests.single.$2, 2);
      expect(await partial.readAsBytes(), modelBytes.sublist(0, 3));
      expect(
        await File(
          '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}',
        ).exists(),
        isFalse,
      );
    },
  );

  test('valid range resumes a partial download and commits it', () async {
    final manifest = fixtureManifest();
    final partial = File(
      '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}.part',
    );
    await partial.writeAsBytes(modelBytes.sublist(0, 2));
    final transport = FakeTransport(
      (_, start) async => response(
        modelBytes.sublist(start),
        status: HttpStatus.partialContent,
        range: 'bytes 2-3/4',
      ),
    );
    final store = ModelStore(
      root: root,
      manifest: manifest,
      transport: transport,
      freeBytes: (_) async => 100,
    );
    expect(await (await store.ensure()).file.readAsBytes(), modelBytes);
    expect(transport.requests.single.$2, 2);
    expect(await partial.exists(), isFalse);
  });

  test('full response to a range request restarts the partial file', () async {
    final manifest = fixtureManifest();
    final partial = File(
      '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}.part',
    );
    await partial.writeAsBytes(modelBytes.sublist(0, 2));
    final transport = FakeTransport((_, _) async => response(modelBytes));
    final store = ModelStore(
      root: root,
      manifest: manifest,
      transport: transport,
      freeBytes: (_) async => 100,
    );
    expect(await (await store.ensure()).file.readAsBytes(), modelBytes);
    expect(transport.requests.single.$2, 2);
  });

  test(
    'corrupt complete partial retries the primary source immediately',
    () async {
      final manifest = fixtureManifest();
      final partial = File(
        '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}.part',
      );
      await partial.writeAsString('evil');
      final transport = FakeTransport((_, _) async => response(modelBytes));
      final store = ModelStore(
        root: root,
        manifest: manifest,
        transport: transport,
        freeBytes: (_) async => 100,
      );
      expect(await (await store.ensure()).file.readAsBytes(), modelBytes);
      expect(transport.requests.single.$2, 0);
    },
  );

  test(
    'corrupt incomplete partial retries the primary from zero once',
    () async {
      final manifest = fixtureManifest();
      final partial = File(
        '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}.part',
      );
      await partial.writeAsString('ev');
      final transport = FakeTransport(
        (_, start) async => start == 2
            ? response(
                modelBytes.sublist(2),
                status: HttpStatus.partialContent,
                range: 'bytes 2-3/4',
              )
            : response(modelBytes),
      );
      final store = ModelStore(
        root: root,
        manifest: manifest,
        transport: transport,
        freeBytes: (_) async => 100,
      );
      expect(await (await store.ensure()).file.readAsBytes(), modelBytes);
      expect(transport.requests.map((request) => request.$2), [2, 0]);
    },
  );

  test('a source with a wrong digest is retried only once', () async {
    final manifest = fixtureManifest();
    final partial = File(
      '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}.part',
    );
    await partial.writeAsString('ev');
    final transport = FakeTransport(
      (_, start) async => start == 2
          ? response(
              modelBytes.sublist(2),
              status: HttpStatus.partialContent,
              range: 'bytes 2-3/4',
            )
          : response(utf8.encode('evil')),
    );
    final store = ModelStore(
      root: root,
      manifest: manifest,
      transport: transport,
      freeBytes: (_) async => 100,
    );
    await expectLater(store.ensure(), throwsA(isA<ModelDownloadException>()));
    expect(transport.requests.map((request) => request.$2), [2, 0]);
  });

  test('verified complete partial commits without a new download', () async {
    final manifest = fixtureManifest();
    final partial = File(
      '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}.part',
    );
    await partial.writeAsBytes(modelBytes);
    final transport = FakeTransport(
      (_, _) async => throw StateError('network'),
    );
    final store = ModelStore(
      root: root,
      manifest: manifest,
      transport: transport,
      freeBytes: (_) async => 0,
    );
    expect(await (await store.ensure()).file.readAsBytes(), modelBytes);
    expect(transport.requests, isEmpty);
  });

  test('oversized partial is removed before the space check', () async {
    final manifest = fixtureManifest();
    final partial = File(
      '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}.part',
    );
    await partial.writeAsString('oversized');
    final store = ModelStore(
      root: root,
      manifest: manifest,
      transport: FakeTransport((_, _) async => throw StateError('network')),
      freeBytes: (_) async => 0,
    );
    await expectLater(store.ensure(), throwsA(isA<ModelDownloadException>()));
    expect(await partial.exists(), isFalse);
  });

  test('stalled response cancels and falls back to a mirror', () async {
    final controller = StreamController<List<int>>();
    controller.add(modelBytes.sublist(0, 2));
    var cancelled = false;
    controller.onCancel = () => cancelled = true;
    addTearDown(controller.close);
    final manifest = fixtureManifest(
      mirrors: ['https://mirror.test/model.gguf'],
    );
    final transport = FakeTransport((url, _) async {
      if (url.host == 'example.test') {
        return ModelResponse(
          statusCode: HttpStatus.ok,
          body: controller.stream,
        );
      }
      return response(
        modelBytes.sublist(2),
        status: HttpStatus.partialContent,
        range: 'bytes 2-3/4',
      );
    });
    final store = ModelStore(
      root: root,
      manifest: manifest,
      transport: transport,
      freeBytes: (_) async => 100,
      idleTimeout: const Duration(milliseconds: 50),
    );
    expect(
      await (await store.ensure().timeout(
        const Duration(seconds: 1),
      )).file.readAsBytes(),
      modelBytes,
    );
    expect(cancelled, isTrue);
    expect(transport.requests.length, 2);
    expect(transport.requests.last.$2, 2);
  });

  test(
    'stalled response headers time out without disabling the client',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        if (request.uri.path == '/stalled') return;
        request.response.write('good');
        unawaited(request.response.close());
      });
      final transport = HttpModelTransport(
        responseHeaderTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(transport.close);
      final host = '127.0.0.1:${server.port}';

      await expectLater(
        transport
            .get(Uri.http(host, '/stalled'), start: 0)
            .timeout(
              const Duration(seconds: 3),
              onTimeout: () => throw StateError('Header timeout did not fire'),
            ),
        throwsA(isA<TimeoutException>()),
      );
      final healthy = await transport.get(Uri.http(host, '/healthy'), start: 0);
      expect(await healthy.body.expand((chunk) => chunk).toList(), modelBytes);
    },
  );

  test('complete verified partial survives a terminal stream error', () async {
    Stream<List<int>> brokenBody() async* {
      yield modelBytes;
      throw const SocketException('connection closed after body');
    }

    final manifest = fixtureManifest();
    final transport = FakeTransport(
      (_, _) async => ModelResponse(
        statusCode: HttpStatus.ok,
        body: brokenBody(),
        contentLength: modelBytes.length,
      ),
    );
    final store = ModelStore(
      root: root,
      manifest: manifest,
      transport: transport,
      freeBytes: (_) async => 100,
    );
    final verified = await store.ensure();
    expect(await verified.file.readAsBytes(), modelBytes);
    expect(transport.requests.length, 1);
    expect(await File('${verified.file.path}.part').exists(), isFalse);
  });

  test('wrong content range cannot append to a partial file', () async {
    final manifest = fixtureManifest();
    final partial = File(
      '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}.part',
    );
    await partial.writeAsBytes(modelBytes.sublist(0, 2));
    final transport = FakeTransport(
      (_, _) async => response(
        modelBytes.sublist(2),
        status: HttpStatus.partialContent,
        range: 'bytes 1-3/4',
      ),
    );
    final store = ModelStore(
      root: root,
      manifest: manifest,
      transport: transport,
      freeBytes: (_) async => 100,
    );
    await expectLater(store.ensure(), throwsA(isA<ModelDownloadException>()));
    expect(await partial.readAsBytes(), modelBytes.sublist(0, 2));
  });

  test('insufficient space stops before the network request', () async {
    final transport = FakeTransport((_, _) async => response(modelBytes));
    final store = ModelStore(
      root: root,
      manifest: fixtureManifest(),
      transport: transport,
      freeBytes: (_) async => modelBytes.length * 2 - 1,
    );
    await expectLater(store.ensure(), throwsA(isA<ModelDownloadException>()));
    expect(transport.requests, isEmpty);
  });

  test('resuming still enforces the full-model space reserve', () async {
    final manifest = fixtureManifest();
    final partial = File(
      '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}.part',
    );
    await partial.writeAsBytes(modelBytes.sublist(0, 2));
    final transport = FakeTransport((_, _) async => response(modelBytes));
    final store = ModelStore(
      root: root,
      manifest: manifest,
      transport: transport,
      freeBytes: (_) async => modelBytes.length * 2 - 1,
    );
    await expectLater(store.ensure(), throwsA(isA<ModelDownloadException>()));
    expect(transport.requests, isEmpty);
    expect(await partial.length(), 2);
  });

  test('failed replacement preserves the previous revision', () async {
    final old = File('${root.path}/previous-model.gguf');
    await old.writeAsString('old model');
    final store = ModelStore(
      root: root,
      manifest: fixtureManifest(),
      transport: FakeTransport((_, _) async => response(modelBytes)),
      freeBytes: (_) async => 100,
      commit: (_, _) async => throw const FileSystemException('rename denied'),
    );
    await expectLater(store.ensure(), throwsA(isA<ModelDownloadException>()));
    expect(await old.readAsString(), 'old model');
    expect(
      await File('${root.path}/fixture-model-$revision-$modelName').exists(),
      isFalse,
    );
  });

  test('verified cached model is reopened without downloading', () async {
    final manifest = fixtureManifest();
    final cached = File(
      '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}',
    );
    await cached.writeAsBytes(modelBytes);
    final transport = FakeTransport(
      (_, _) async => throw StateError('network'),
    );
    final store = ModelStore(
      root: root,
      manifest: manifest,
      transport: transport,
      freeBytes: (_) async => 0,
    );
    expect((await store.ensure()).file.path, cached.path);
    expect(transport.requests, isEmpty);
  });
}
