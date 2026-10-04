import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';
import 'package:test/test.dart';

import 'routing_support.dart';

final modelHash = 'a' * 64;

CalibrationProfile calibration({
  Map<String, String> types = const {'topic': 'choice'},
  double temperature = 1,
  double? threshold = 0.5,
  String? hash,
}) => CalibrationProfile(
  modelSha256: hash ?? modelHash,
  targetError: 0.05,
  questions: {
    for (final entry in types.entries)
      entry.key: QuestionCalibration(
        type: entry.value,
        temperature: temperature,
        threshold: threshold,
      ),
  },
);

Map<String, Object?> routingFor(SystemOneResponse response, String key) =>
    ((response.xExtensions['x_routing'] as Map)[key] as Map)
        .cast<String, Object?>();

final class TransformBackend implements SystemOneBackend {
  const TransformBackend(this.transform);

  final SystemOneResponse Function(SystemOneResponse) transform;

  @override
  Future<SystemOneResponse> evaluate(SystemOneRequest request) async =>
      transform(await FakeEngine().evaluate(request));
}

void main() {
  test('mixes accepted, uncertain and forced keys in original order', () async {
    final local = CapturingBackend(
      backend: FakeEngine(
        weights: {
          'certain': {'true': 1, 'false': 0},
          'uncertain': {'true': 1, 'false': 1},
        },
      ),
    );
    final remoteRequests = <SystemOneRequest>[];
    final router = HybridRouter(
      local: local,
      modelSha256: modelHash,
      calibration: calibration(types: {'certain': 'noul', 'uncertain': 'noul'}),
      forcedRemoteKeys: {'forced'},
      remote: RemoteBackend(
        policy: allowedPolicy(),
        transport: (json) async {
          final request = SystemOneJson.decodeRequest(json);
          remoteRequests.add(request);
          return RemoteTransportResponse(
            statusCode: 200,
            body: SystemOneJson.encodeResponse(
              await FakeEngine(
                weights: {
                  'uncertain': {'true': 0, 'false': 1},
                  'forced': {'a': 0, 'b': 1},
                },
              ).evaluate(request),
            ),
          );
        },
      ),
    );
    final request = routingRequest(
      questions: {
        'forced': ChoiceQuestion(criteria: {'a': null, 'b': null}),
        'certain': NoulQuestion(),
        'uncertain': NoulQuestion(),
      },
    );
    final response = await router.evaluate(request);
    expect(local.requests.single.questions.keys, ['certain', 'uncertain']);
    expect(remoteRequests.single.questions.keys, ['forced', 'uncertain']);
    expect(response.answers.keys, request.questions.keys);
    expect((response.answers['forced'] as ChoiceAnswer).choice, 'b');
    expect((response.answers['certain'] as NoulAnswer).noul, 1);
    expect((response.answers['uncertain'] as NoulAnswer).noul, 0);
    expect(response.xRoute, 'auto');
    expect(routingFor(response, 'certain')['route'], 'local');
    expect(routingFor(response, 'uncertain')['route'], 'remote');
    expect(routingFor(response, 'forced')['gate'], 'forced');
    SystemOneJson.checkAnswers(request.questions, response);
  });

  test(
    'forced-only requests skip local inference and label remote route',
    () async {
      final local = CapturingBackend();
      final router = HybridRouter(
        local: local,
        modelSha256: modelHash,
        forcedRemoteKeys: {'topic'},
        remote: RemoteBackend(policy: allowedPolicy(), transport: fakeRemote),
      );
      expect((await router.evaluate(routingRequest())).xRoute, 'remote');
      expect(local.requests, isEmpty);
    },
  );

  test('unknown forced keys fail before any backend call', () async {
    final local = CapturingBackend();
    final router = HybridRouter(
      local: local,
      modelSha256: modelHash,
      forcedRemoteKeys: {'typo'},
    );
    await expectLater(router.evaluate(routingRequest()), throwsArgumentError);
    expect(local.requests, isEmpty);
  });

  test('snapshots configured forced keys', () async {
    final forced = {'topic'};
    final local = CapturingBackend();
    final router = HybridRouter(
      local: local,
      modelSha256: modelHash,
      forcedRemoteKeys: forced,
      remote: RemoteBackend(policy: allowedPolicy(), transport: fakeRemote),
    );
    forced.clear();
    await router.evaluate(routingRequest());
    expect(local.requests, isEmpty);
  });

  test(
    'ordinary denial preserves a complete local answer with failure metadata',
    () async {
      final request = routingRequest();
      final expected = await FakeEngine().evaluate(request);
      final router = HybridRouter(
        local: FakeEngine(),
        modelSha256: modelHash,
        calibration: calibration(),
        remote: RemoteBackend(transport: fakeRemote),
      );
      final response = await router.evaluate(request);
      expect(
        SystemOneJson.encodeResponse(response)['answers'],
        SystemOneJson.encodeResponse(expected)['answers'],
      );
      expect(response.xRoute, 'local');
      expect(routingFor(response, 'topic')['remote_error'], 'localOnly');
      expect(routingFor(response, 'topic')['gate'], 'rejected');
    },
  );

  test(
    'forced remote denial throws instead of returning a partial answer',
    () async {
      final router = HybridRouter(
        local: FakeEngine(),
        modelSha256: modelHash,
        forcedRemoteKeys: {'forced'},
        remote: RemoteBackend(transport: fakeRemote),
      );
      await expectLater(
        router.evaluate(
          routingRequest(
            questions: {'forced': NoulQuestion(), 'local': NoulQuestion()},
          ),
        ),
        throwsA(
          isA<RemotePolicyException>().having(
            (e) => e.reason,
            'reason',
            RemotePolicyReason.localOnly,
          ),
        ),
      );
    },
  );

  for (final forced in [false, true]) {
    test(
      'status failure ${forced ? 'throws for forced' : 'falls back for uncertain'} keys',
      () async {
        final router = HybridRouter(
          local: FakeEngine(),
          modelSha256: modelHash,
          forcedRemoteKeys: forced ? {'topic'} : {},
          remote: RemoteBackend(
            policy: allowedPolicy(),
            transport: (_) async =>
                RemoteTransportResponse(statusCode: 429, body: null),
          ),
        );
        if (forced) {
          await expectLater(
            router.evaluate(routingRequest()),
            throwsA(isA<RemoteStatusException>()),
          );
        } else {
          final response = await router.evaluate(routingRequest());
          expect(response.answers.keys, ['topic']);
          expect(routingFor(response, 'topic')['remote_error'], 'rateLimited');
        }
      },
    );
  }

  test('missing remote backend falls back except for forced keys', () async {
    final router = HybridRouter(local: FakeEngine(), modelSha256: modelHash);
    final response = await router.evaluate(routingRequest());
    expect(routingFor(response, 'topic')['remote_error'], 'backendUnavailable');
    await expectLater(
      HybridRouter(
        local: FakeEngine(),
        modelSha256: modelHash,
        forcedRemoteKeys: {'topic'},
      ).evaluate(routingRequest()),
      throwsA(isA<RemotePolicyException>()),
    );
  });

  test(
    'rejects incomplete local responses instead of returning partial answers',
    () async {
      final router = HybridRouter(
        local: TransformBackend(
          (response) => SystemOneResponse(
            model: response.model,
            answers: {'other': NoulAnswer(noul: 0.5)},
            usage: response.usage,
          ),
        ),
        modelSha256: modelHash,
      );
      await expectLater(
        router.evaluate(routingRequest()),
        throwsA(isA<SystemOneFormatException>()),
      );
    },
  );

  test('invalid remote response falls back to entire local answer', () async {
    final router = HybridRouter(
      local: FakeEngine(),
      modelSha256: modelHash,
      remote: RemoteBackend(
        policy: allowedPolicy(),
        transport: (_) async =>
            RemoteTransportResponse(statusCode: 200, body: {}),
      ),
    );
    final request = routingRequest();
    final response = await router.evaluate(request);
    SystemOneJson.checkAnswers(request.questions, response);
    expect(routingFor(response, 'topic')['remote_error'], 'invalidResponse');
  });

  group('calibration', () {
    test(
      'temperature controls the gate while raw probabilities remain unchanged',
      () async {
        var calls = 0;
        final router = HybridRouter(
          local: FakeEngine(
            weights: {
              'topic': {'a': 4, 'b': 1},
            },
          ),
          modelSha256: modelHash,
          calibration: calibration(temperature: 0.5, threshold: 0.8),
          remote: RemoteBackend(
            policy: allowedPolicy(),
            transport: (json) async {
              calls++;
              return fakeRemote(json);
            },
          ),
        );
        final response = await router.evaluate(routingRequest());
        final answer = response.answers['topic'] as ChoiceAnswer;
        expect(calls, 0);
        expect(answer.probabilities, {'a': 0.8, 'b': 0.2});
        expect(answer.confidence, closeTo(0.6, 1e-12));
        expect(
          routingFor(response, 'topic')['calibrated_confidence'],
          closeTo(15 / 17, 1e-12),
        );
        // Routing acceptance does not override the caller's DecisionClient gate.
        final evaluation = Evaluation(
          questions: {
            'topic': Choice(null, {'a': 'a', 'b': 'b'}),
          },
          response: response,
          minConfidence: 0.8,
        );
        expect(evaluation.choice<String>('topic'), isA<Uncertain<String>>());
      },
    );

    test(
      'Noul and Score use calibrated distributions with inclusive threshold',
      () async {
        final router = HybridRouter(
          local: FakeEngine(
            weights: {
              'noul': {'true': 3, 'false': 1},
              'score': {'0': 3, '1': 1},
            },
          ),
          modelSha256: modelHash,
          calibration: calibration(types: {'noul': 'noul', 'score': 'score'}),
        );
        final response = await router.evaluate(
          routingRequest(
            questions: {
              'noul': NoulQuestion(),
              'score': ScoreQuestion(criteria: ['low', 'high']),
            },
          ),
        );
        for (final key in response.answers.keys) {
          expect(routingFor(response, key)['gate'], 'accepted');
          expect(routingFor(response, key)['calibrated_confidence'], 0.5);
          expect(
            routingFor(response, key).containsKey('remote_error'),
            isFalse,
          );
        }
        expect((response.answers['score'] as ScoreAnswer).score, 0.25);
      },
    );

    test('null threshold rejects even a certain answer', () async {
      final router = HybridRouter(
        local: FakeEngine(
          weights: {
            'topic': {'a': 1},
          },
        ),
        modelSha256: modelHash,
        calibration: calibration(threshold: null),
      );
      final response = await router.evaluate(routingRequest());
      expect(routingFor(response, 'topic')['calibrated_confidence'], 1);
      expect(routingFor(response, 'topic')['gate'], 'rejected');
    });

    final fallbacks = <String, CalibrationProfile?>{
      'missingProfile': null,
      'modelHashMismatch': calibration(hash: 'b' * 64),
      'missingQuestion': calibration(types: {'unknown': 'choice'}),
      'questionTypeMismatch': calibration(types: {'topic': 'noul'}),
    };
    for (final entry in fallbacks.entries) {
      test(
        '${entry.key} warns and rejects even a certain local answer',
        () async {
          var calls = 0;
          final router = HybridRouter(
            local: FakeEngine(
              weights: {
                'topic': {'a': 1},
              },
            ),
            modelSha256: modelHash,
            calibration: entry.value,
            remote: RemoteBackend(
              policy: allowedPolicy(),
              transport: (json) async {
                calls++;
                return fakeRemote(json);
              },
            ),
          );
          final response = await router.evaluate(routingRequest());
          expect(calls, 1);
          expect(routingFor(response, 'topic')['warning'], entry.key);
          expect(routingFor(response, 'topic')['gate'], 'rejected');
          expect(
            routingFor(response, 'topic').containsKey('calibrated_confidence'),
            isFalse,
          );
        },
      );
    }

    test('requires a verified-format model hash', () {
      expect(
        () => HybridRouter(local: FakeEngine(), modelSha256: 'bad'),
        throwsArgumentError,
      );
    });
  });

  for (final field in ['input_tokens', 'output_tokens']) {
    for (final forced in [false, true]) {
      test(
        '$field overflow ${forced ? 'throws typed forced error' : 'falls back locally'}',
        () async {
          final router = HybridRouter(
            local: TransformBackend(
              (response) => SystemOneResponse(
                model: response.model,
                answers: response.answers,
                usage: Usage(inputTokens: 1, outputTokens: 1),
              ),
            ),
            modelSha256: modelHash,
            forcedRemoteKeys: forced ? {'forced'} : {},
            remote: RemoteBackend(
              policy: allowedPolicy(),
              transport: (json) async {
                final result = await fakeRemote(json);
                return RemoteTransportResponse(
                  statusCode: 200,
                  body: {
                    ...(result.body as Map<String, Object?>),
                    'usage': {
                      'input_tokens': 0,
                      'output_tokens': 0,
                      field: 9007199254740991,
                    },
                  },
                );
              },
            ),
          );
          final request = routingRequest(
            questions: {
              'local': NoulQuestion(),
              if (forced) 'forced': NoulQuestion(),
            },
          );
          if (forced) {
            await expectLater(
              router.evaluate(request),
              throwsA(isA<RemoteResponseException>()),
            );
          } else {
            final response = await router.evaluate(request);
            expect(response.xRoute, 'local');
            expect(response.answers.keys, ['local']);
            expect(response.usage.inputTokens, 1);
            expect(response.usage.outputTokens, 1);
            expect(
              routingFor(response, 'local')['remote_error'],
              'invalidResponse',
            );
          }
        },
      );
    }
  }

  test('sums primary usage and labels the actual source models', () async {
    final router = HybridRouter(
      local: TransformBackend(
        (response) => SystemOneResponse(
          model: 'local-id',
          answers: response.answers,
          usage: Usage(inputTokens: 7, outputTokens: 2),
        ),
      ),
      modelSha256: modelHash,
      calibration: calibration(types: {'local': 'noul'}, threshold: 0),
      forcedRemoteKeys: {'forced'},
      remote: RemoteBackend(
        policy: allowedPolicy(),
        transport: (json) async {
          final result = await fakeRemote(json);
          return RemoteTransportResponse(
            statusCode: 200,
            body: {
              ...(result.body as Map<String, Object?>),
              'model': 'remote-id',
              'usage': {'input_tokens': 11, 'output_tokens': 3},
            },
          );
        },
      ),
    );
    final response = await router.evaluate(
      routingRequest(
        questions: {'local': NoulQuestion(), 'forced': NoulQuestion()},
      ),
    );
    expect(response.model, 'synthetic-model');
    expect(response.usage.inputTokens, 18);
    expect(response.usage.outputTokens, 5);
    expect(routingFor(response, 'local')['model'], 'local-id');
    expect(routingFor(response, 'forced')['model'], 'remote-id');
  });
}
