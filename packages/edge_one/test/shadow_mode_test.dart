import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';
import 'package:test/test.dart';

import 'routing_support.dart';

final hash = 'c' * 64;
final profile = CalibrationProfile(
  modelSha256: hash,
  targetError: 0.05,
  questions: {
    'local': QuestionCalibration(type: 'noul', temperature: 1, threshold: 0),
  },
);
final request = routingRequest(questions: {'local': NoulQuestion()});

HybridRouter shadowRouter({RemoteBackend? remote, ShadowMode? shadow}) =>
    HybridRouter(
      local: FakeEngine(),
      modelSha256: hash,
      calibration: profile,
      remote: remote,
      shadow: shadow,
    );

void main() {
  test('shadow is off unless explicitly configured', () async {
    var calls = 0;
    final router = shadowRouter(
      remote: RemoteBackend(
        policy: allowedPolicy(),
        transport: (json) async {
          calls++;
          return fakeRemote(json);
        },
      ),
    );
    await router.evaluate(request);
    expect(calls, 0);
  });

  test(
    'injected deterministic sampler selects requests without changing results',
    () async {
      final expected = SystemOneJson.encodeResponse(
        await shadowRouter().evaluate(request),
      );
      var sampleCount = 0;
      var remoteCount = 0;
      final observations = <ShadowComparison>[];
      final router = shadowRouter(
        remote: RemoteBackend(
          policy: allowedPolicy(),
          transport: (json) async {
            remoteCount++;
            final response = await FakeEngine(
              weights: {
                'local': {'true': 1},
              },
            ).evaluate(SystemOneJson.decodeRequest(json));
            return RemoteTransportResponse(
              statusCode: 200,
              body: SystemOneJson.encodeResponse(response),
            );
          },
        ),
        shadow: ShadowMode(
          sample: (request) {
            expect(() => request.questions.clear(), throwsUnsupportedError);
            return ++sampleCount % 2 == 0;
          },
          observe: (comparison) async {
            await Future<void>.value();
            observations.add(comparison);
          },
        ),
      );
      for (var i = 0; i < 4; i++) {
        expect(
          SystemOneJson.encodeResponse(await router.evaluate(request)),
          expected,
        );
      }
      expect(remoteCount, 2);
      expect(observations, hasLength(2));
      expect(
        (observations.first.localAnswers['local'] as NoulAnswer).noul,
        0.5,
      );
      expect(
        (observations.first.remoteResponse!.answers['local'] as NoulAnswer)
            .noul,
        1,
      );
      expect(observations.first.error, isNull);
      expect(
        () => observations.first.localAnswers.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'mixed route shadows only local keys with masking before both calls',
    () async {
      final calls = <Map<String, Object?>>[];
      final maskKeys = <List<String>>[];
      final observations = <ShadowComparison>[];
      final budget = RemoteBudget(dailyLimitMicrocredits: 2);
      final router = HybridRouter(
        local: FakeEngine(),
        modelSha256: hash,
        calibration: profile,
        forcedRemoteKeys: {'forced'},
        remote: RemoteBackend(
          policy: allowedPolicy(
            budget: budget,
            beforeRemote: (outbound) {
              maskKeys.add(outbound.questions.keys.toList());
              return SystemOneRequest(
                state: '[masked]',
                model: outbound.model,
                questions: outbound.questions,
              );
            },
          ),
          transport: (json) async {
            calls.add(json);
            return fakeRemote(json);
          },
        ),
        shadow: ShadowMode(sample: (_) => true, observe: observations.add),
      );
      final response = await router.evaluate(
        routingRequest(
          questions: {'local': NoulQuestion(), 'forced': NoulQuestion()},
        ),
      );
      expect(response.xRoute, 'auto');
      expect(maskKeys, [
        ['forced'],
        ['local'],
      ]);
      expect(calls.map((call) => call['state']), ['[masked]', '[masked]']);
      expect(observations.single.localAnswers.keys, ['local']);
      expect(observations.single.remoteResponse!.answers.keys, ['local']);
      expect(budget.spentMicrocredits, 2);
    },
  );

  test(
    'shadow cannot consume credit already spent by primary remote',
    () async {
      var calls = 0;
      ShadowComparison? observed;
      final router = HybridRouter(
        local: FakeEngine(),
        modelSha256: hash,
        calibration: profile,
        forcedRemoteKeys: {'forced'},
        remote: RemoteBackend(
          policy: allowedPolicy(
            budget: RemoteBudget(dailyLimitMicrocredits: 1),
          ),
          transport: (json) async {
            calls++;
            return fakeRemote(json);
          },
        ),
        shadow: ShadowMode(
          sample: (_) => true,
          observe: (value) => observed = value,
        ),
      );
      final response = await router.evaluate(
        routingRequest(
          questions: {'local': NoulQuestion(), 'forced': NoulQuestion()},
        ),
      );
      expect(calls, 1);
      expect(response.answers.keys, ['local', 'forced']);
      expect(
        observed!.error,
        isA<RemotePolicyException>().having(
          (e) => e.reason,
          'reason',
          RemotePolicyReason.budgetExhausted,
        ),
      );
    },
  );

  for (final consent in [false, true]) {
    test(
      'shadow ${consent ? 'status error' : 'consent refusal'} leaves primary response intact',
      () async {
        var calls = 0;
        ShadowComparison? observed;
        final expected = SystemOneJson.encodeResponse(
          await shadowRouter().evaluate(request),
        );
        final router = shadowRouter(
          remote: RemoteBackend(
            policy: allowedPolicy(hasConsent: () => consent),
            transport: (_) async {
              calls++;
              return RemoteTransportResponse(statusCode: 529, body: null);
            },
          ),
          shadow: ShadowMode(
            sample: (_) => true,
            observe: (value) => observed = value,
          ),
        );
        expect(
          SystemOneJson.encodeResponse(await router.evaluate(request)),
          expected,
        );
        expect(calls, consent ? 1 : 0);
        expect(
          observed!.error,
          consent ? isA<RemoteStatusException>() : isA<RemotePolicyException>(),
        );
        expect(observed!.remoteResponse, isNull);
      },
    );
  }

  test(
    'sampler failure cannot trigger transport or change the primary response',
    () async {
      var calls = 0;
      final expected = SystemOneJson.encodeResponse(
        await shadowRouter().evaluate(request),
      );
      final router = shadowRouter(
        remote: RemoteBackend(
          policy: allowedPolicy(),
          transport: (json) async {
            calls++;
            return fakeRemote(json);
          },
        ),
        shadow: ShadowMode(
          sample: (_) => throw StateError('sampler'),
          observe: (_) {},
        ),
      );
      expect(
        SystemOneJson.encodeResponse(await router.evaluate(request)),
        expected,
      );
      expect(calls, 0);
    },
  );

  test(
    'asynchronous observer failure cannot change the primary response',
    () async {
      final expected = SystemOneJson.encodeResponse(
        await shadowRouter().evaluate(request),
      );
      final router = shadowRouter(
        remote: RemoteBackend(policy: allowedPolicy(), transport: fakeRemote),
        shadow: ShadowMode(
          sample: (_) => true,
          observe: (_) async {
            await Future<void>.value();
            throw StateError('observer');
          },
        ),
      );
      expect(
        SystemOneJson.encodeResponse(await router.evaluate(request)),
        expected,
      );
    },
  );

  test('all-remote primary result does not invoke shadow sampler', () async {
    var samples = 0;
    final router = HybridRouter(
      local: FakeEngine(),
      modelSha256: hash,
      forcedRemoteKeys: {'local'},
      remote: RemoteBackend(policy: allowedPolicy(), transport: fakeRemote),
      shadow: ShadowMode(
        sample: (_) {
          samples++;
          return true;
        },
        observe: (_) {},
      ),
    );
    expect((await router.evaluate(request)).xRoute, 'remote');
    expect(samples, 0);
  });
}
