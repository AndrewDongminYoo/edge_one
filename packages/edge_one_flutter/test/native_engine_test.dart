import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:edge_one/edge_one.dart';
import 'package:ffi/ffi.dart';
import 'package:edge_one_flutter/src/generated/edge_one_native.dart' as native;
import 'package:edge_one_flutter/src/local_engine.dart';
import 'package:edge_one_flutter/src/local_exception.dart';
import 'package:edge_one_flutter/src/model_manifest.dart';
import 'package:edge_one_flutter/src/model_store.dart';
import 'package:edge_one_flutter/src/native_engine.dart';
import 'package:test/test.dart';

const requestJson =
    '{"state":"synthetic","model":"test","questions":'
    '{"q":{"type":"choice","criteria":{"a":null,"b":null}}}}';

Matcher statusIs(int value) => isA<LocalEngineException>().having(
  (error) => error.statusCode,
  'native status',
  value,
);

void main() {
  final libraryPath = Platform.environment['EDGE_ONE_FFI_TEST_LIBRARY'];
  if (libraryPath == null || !File(libraryPath).existsSync()) {
    throw StateError('Build test/native and set EDGE_ONE_FFI_TEST_LIBRARY');
  }
  final library = DynamicLibrary.open(libraryPath);
  final reset = library
      .lookupFunction<Void Function(Int32), void Function(int)>(
        'eo_test_reset',
      );
  final read = library.lookupFunction<Int32 Function(Int32), int Function(int)>(
    'eo_test_read',
  );
  final release = library
      .lookupFunction<Void Function(Int32), void Function(int)>(
        'eo_test_release',
      );
  late String manifest;
  final engines = <NativeEngine>[];

  Future<void> waitFor(int key) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (read(key) == 0) {
      if (DateTime.now().isAfter(deadline)) {
        fail('native probe $key did not enter before the deadline');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<NativeEngine> open({String path = 'synthetic', String? json}) async {
    final engine = await NativeEngine.open(
      modelPath: path,
      manifestJson: json ?? manifest,
      libraryPath: libraryPath,
    );
    engines.add(engine);
    return engine;
  }

  setUpAll(() async {
    manifest = await File('assets/model_manifest.json').readAsString();
  });
  setUp(() => reset(0));
  tearDown(() async {
    release(0);
    release(1);
    for (final engine in engines) {
      await engine.dispose();
    }
    engines.clear();
    expect(read(3), 0, reason: 'every owned result/error must reach eo_free');
    expect(read(4), 0, reason: 'close must join ALL evaluate/cancel callers');
    expect(read(5), 0, reason: 'no native caller may remain after dispose');
  });

  test(
    'bundled Native asset resolves all five real ABI symbols without a model',
    () {
      using((arena) {
        final error = arena<Pointer<Char>>();
        final handle = native.eo_open(nullptr, nullptr, error);
        try {
          expect(handle, nullptr);
          expect(error.value, isNot(nullptr));
          expect(
            error.value.cast<Utf8>().toDartString(),
            'Model path is empty',
          );
        } finally {
          native.eo_free(error.value);
        }
        final status = arena<Int32>();
        final result = native.eo_evaluate(nullptr, nullptr, status);
        try {
          expect(status.value, 503);
          expect(
            jsonDecode(result.cast<Utf8>().toDartString())['error']['message'],
            'Engine is null',
          );
        } finally {
          native.eo_free(result);
        }
        native.eo_cancel(nullptr);
        native.eo_close(nullptr);
        native.eo_free(nullptr);
      });
    },
  );

  test(
    'control worker exit still joins and closes the evaluation worker',
    () async {
      final engine = await open();
      await terminateControlWorker(engine);
      await expectLater(engine.dispose(), throwsA(statusIs(503)));
      expect(read(2), 1);
      expect(read(6), 1);
      await expectLater(engine.dispose(), throwsA(statusIs(503)));
      engines.remove(
        engine,
      ); // The expected failed disposal is already complete.
    },
  );

  test(
    'open failure and missing library complete without leaked error strings',
    () async {
      await expectLater(open(path: 'fail-open'), throwsA(statusIs(503)));
      await expectLater(open(json: '{}'), throwsA(statusIs(503)));
      await expectLater(open(path: 'bad\u0000path'), throwsA(statusIs(422)));
      await expectLater(
        NativeEngine.open(
          modelPath: 'synthetic',
          manifestJson: manifest,
          libraryPath: '$libraryPath.missing',
        ),
        throwsA(statusIs(503)),
      );
      expect(read(2), 0);
    },
  );

  test(
    'one open serves repeated requests; idle cancellation is harmless',
    () async {
      final engine = await open();
      await engine.cancel();
      final first = await engine.evaluate(requestJson);
      final second = await engine.evaluate(requestJson);
      expect(jsonDecode(first)['answers']['q']['probabilities']['a'], 0.5);
      expect(jsonDecode(second)['answers']['q']['probabilities']['a'], 0.5);
      expect(
        read(8),
        1,
        reason: 'the model/backend is retained across requests',
      );
      expect(read(1), 0, reason: 'idle cancel must not call native');
      await engine.dispose();
      expect(jsonDecode(first)['answers']['q']['probabilities']['a'], 0.5);
      expect(read(6), 1);
    },
  );

  test(
    'real blocking evaluation keeps the caller isolate responsive and cancels',
    () async {
      reset(1);
      final engine = await open();
      var ticks = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      addTearDown(heartbeat.cancel);
      final outcome = expectLater(
        engine.evaluate(requestJson),
        throwsA(statusIs(499)),
      );
      await waitFor(7);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ticks, greaterThan(0));
      await expectLater(engine.evaluate(requestJson), throwsA(statusIs(409)));
      await Future.wait(List.generate(8, (_) => engine.cancel()));
      await outcome;
      expect(read(1), greaterThan(0));
      release(2);
      expect(jsonDecode(await engine.evaluate(requestJson))['model'], 'test');
    },
  );

  test(
    'cancellation before native entry is latched until evaluate becomes active',
    () async {
      reset(4);
      final engine = await open();
      final outcome = expectLater(
        engine.evaluate(requestJson),
        throwsA(statusIs(499)),
      );
      await waitFor(
        0,
      ); // ABI wrapper has entered, real eo_evaluate is still idle.
      await engine.cancel();
      expect(read(7), 0);
      expect(read(1), greaterThan(0));
      release(0);
      await outcome;
    },
  );

  test(
    'dispose during evaluation blocks new calls and joins delayed cancel callers',
    () async {
      reset(5);
      final engine = await open();
      final outcome = expectLater(
        engine.evaluate(requestJson),
        throwsA(statusIs(499)),
      );
      await waitFor(7);
      var cancelFinished = 0;
      final cancellations = List.generate(
        4,
        (_) => engine.cancel().then((_) => cancelFinished++),
      );
      await waitFor(1); // eo_cancel is held inside the native barrier.
      var disposed = false;
      final disposal = engine.dispose();
      expect(identical(disposal, engine.dispose()), isTrue);
      final completion = disposal.then((_) => disposed = true);
      await expectLater(engine.evaluate(requestJson), throwsStateError);
      await expectLater(engine.cancel(), throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(disposed, isFalse);
      expect(cancelFinished, 0);
      expect(read(2), 0);
      release(1);
      await Future.wait(cancellations);
      await outcome;
      await completion;
      await engine.dispose();
      expect(read(2), 1);
      expect(read(6), 1);
      expect(cancelFinished, 4);
    },
  );

  test(
    'disposing idle engines repeatedly closes each handle exactly once',
    () async {
      for (var i = 0; i < 20; i++) {
        final engine = await open();
        await Future.wait([engine.dispose(), engine.dispose()]);
        await expectLater(engine.evaluate(requestJson), throwsStateError);
      }
      expect(read(2), 20);
      expect(read(6), 20);
    },
  );

  test('different engines can evaluate independently', () async {
    reset(1);
    final a = await open();
    final b = await open();
    final aResult = expectLater(
      a.evaluate(requestJson),
      throwsA(statusIs(499)),
    );
    final bResult = expectLater(
      b.evaluate(requestJson),
      throwsA(statusIs(499)),
    );
    await waitFor(7);
    await Future.wait([a.cancel(), b.cancel()]);
    await Future.wait([aResult, bResult]);
  });

  test('native validation maps to 422 and frees error JSON', () async {
    final engine = await open();
    await expectLater(engine.evaluate('{'), throwsA(statusIs(422)));
    await expectLater(engine.evaluate('{}'), throwsA(statusIs(422)));
    await expectLater(engine.evaluate('bad\u0000json'), throwsA(statusIs(422)));
    expect(read(3), 0);
  });

  for (final (mode, status) in [(2, 500), (3, 503), (6, 503), (7, 500)]) {
    test('native mode $mode maps status $status and frees output', () async {
      reset(mode);
      final engine = await open();
      await expectLater(
        engine.evaluate(requestJson),
        throwsA(statusIs(status)),
      );
    });
  }

  test(
    'LocalEngine implements typed backend and validates its response',
    () async {
      final bytes = await File('assets/model_manifest.json').readAsBytes();
      final model = VerifiedModel(
        File('synthetic.gguf'),
        ModelManifest.parseBundled(
          bytes,
          expectedSha256: pinnedModelManifestSha256,
        ),
      );
      final engine = await openLocalEngine(model, libraryPath: libraryPath);
      addTearDown(engine.dispose);
      final request = SystemOneJson.decodeRequest(jsonDecode(requestJson));
      final response = await engine.evaluate(request);
      expect(response.model, 'test');
      expect((response.answers['q'] as ChoiceAnswer).choice, 'a');
      await engine.dispose();
      await expectLater(engine.evaluate(request), throwsStateError);
      expect(read(8), 1);
    },
  );

  test(
    'LocalEngine snapshots mutable criteria before native evaluation',
    () async {
      reset(1);
      final model = VerifiedModel(
        File('synthetic.gguf'),
        ModelManifest.parseBundled(
          await File('assets/model_manifest.json').readAsBytes(),
          expectedSha256: pinnedModelManifestSha256,
        ),
      );
      final engine = await openLocalEngine(model, libraryPath: libraryPath);
      addTearDown(engine.dispose);
      final criteria = <String, StructuredValue?>{'a': null, 'b': null};
      final questions = <String, SystemOneQuestion>{
        'q': ChoiceQuestion(criteria: criteria),
      };
      final request = SystemOneRequest(
        state: 'synthetic',
        model: 'test',
        questions: questions,
      );
      final response = engine.evaluate(request);
      await waitFor(7);
      criteria['c'] = null;
      release(3);
      expect((await response).answers.keys, ['q']);
      await engine.dispose();
    },
  );

  test('LocalEngine rejects malformed native success JSON', () async {
    reset(8);
    final model = VerifiedModel(
      File('synthetic.gguf'),
      ModelManifest.parseBundled(
        await File('assets/model_manifest.json').readAsBytes(),
        expectedSha256: pinnedModelManifestSha256,
      ),
    );
    final engine = await openLocalEngine(model, libraryPath: libraryPath);
    addTearDown(engine.dispose);
    await expectLater(
      engine.evaluate(SystemOneJson.decodeRequest(jsonDecode(requestJson))),
      throwsA(statusIs(500)),
    );
    await engine.dispose();
  });

  test('all status kinds preserve the native code', () {
    for (final (code, kind) in [
      (409, LocalStatusKind.busy),
      (422, LocalStatusKind.invalidRequest),
      (499, LocalStatusKind.cancelled),
      (500, LocalStatusKind.internal),
      (503, LocalStatusKind.unavailable),
      (418, LocalStatusKind.unexpected),
    ]) {
      expect(LocalEngineException(code).kind, kind);
    }
  });
}
