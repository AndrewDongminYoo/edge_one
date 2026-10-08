import 'dart:async';

import 'package:edge_one/edge_one.dart';
import 'package:test/test.dart';

import 'routing_support.dart';

Matcher policyFailure(RemotePolicyReason reason) => throwsA(
  isA<RemotePolicyException>().having((e) => e.reason, 'reason', reason),
);

void main() {
  group('RemoteBackend policy', () {
    test('defaults to local-only and never invokes transport', () async {
      var calls = 0;
      final backend = RemoteBackend(
        transport: (request) async {
          calls++;
          return fakeRemote(request);
        },
      );
      await expectLater(
        backend.evaluate(routingRequest()),
        policyFailure(RemotePolicyReason.localOnly),
      );
      expect(calls, 0);
    });

    final denials = <RemotePolicyReason, RemotePolicy>{
      RemotePolicyReason.consentRequired: RemotePolicy(localOnly: false),
      RemotePolicyReason.networkUnavailable: RemotePolicy(
        localOnly: false,
        hasConsent: () => true,
      ),
      RemotePolicyReason.maskingRequired: RemotePolicy(
        localOnly: false,
        hasConsent: () => true,
        isNetworkAvailable: () => true,
      ),
      RemotePolicyReason.budgetRequired: RemotePolicy(
        localOnly: false,
        hasConsent: () => true,
        isNetworkAvailable: () => true,
        beforeRemote: (request) => request,
      ),
      RemotePolicyReason.costEstimateRequired: RemotePolicy(
        localOnly: false,
        hasConsent: () => true,
        isNetworkAvailable: () => true,
        beforeRemote: (request) => request,
        budget: RemoteBudget(dailyLimitMicrocredits: 1),
      ),
    };
    for (final entry in denials.entries) {
      test('refuses ${entry.key.name} before transport', () async {
        var calls = 0;
        final backend = RemoteBackend(
          policy: entry.value,
          transport: (request) async {
            calls++;
            return fakeRemote(request);
          },
        );
        await expectLater(
          backend.evaluate(routingRequest()),
          policyFailure(entry.key),
        );
        expect(calls, 0);
      });
    }

    test('rechecks consent after asynchronous masking', () async {
      var consent = true;
      var calls = 0;
      final budget = RemoteBudget(dailyLimitMicrocredits: 1);
      final backend = RemoteBackend(
        policy: allowedPolicy(
          hasConsent: () => consent,
          budget: budget,
          beforeRemote: (request) async {
            await Future<void>.value();
            consent = false;
            return request;
          },
        ),
        transport: (request) async {
          calls++;
          return fakeRemote(request);
        },
      );
      await expectLater(
        backend.evaluate(routingRequest()),
        policyFailure(RemotePolicyReason.consentRequired),
      );
      expect(calls, 0);
      expect(budget.spentMicrocredits, 0);
    });

    test(
      'clock callback revocation refuses dispatch without charging',
      () async {
        var consent = true;
        var calls = 0;
        final budget = RemoteBudget(
          dailyLimitMicrocredits: 1,
          now: () {
            consent = false;
            return DateTime.utc(2026, 10, 4);
          },
        );
        final backend = RemoteBackend(
          policy: allowedPolicy(hasConsent: () => consent, budget: budget),
          transport: (json) async {
            calls++;
            return fakeRemote(json);
          },
        );
        await expectLater(
          backend.evaluate(routingRequest()),
          policyFailure(RemotePolicyReason.consentRequired),
        );
        expect(calls, 0);
        expect(budget.spentMicrocredits, 0);
      },
    );

    test(
      'final network callback revocation refuses dispatch without charging',
      () async {
        var consent = true;
        var networkChecks = 0;
        var calls = 0;
        final budget = RemoteBudget(dailyLimitMicrocredits: 1);
        final backend = RemoteBackend(
          policy: allowedPolicy(
            budget: budget,
            hasConsent: () => consent,
            isNetworkAvailable: () {
              if (++networkChecks == 3) consent = false;
              return true;
            },
          ),
          transport: (json) async {
            calls++;
            return fakeRemote(json);
          },
        );
        await expectLater(
          backend.evaluate(routingRequest()),
          policyFailure(RemotePolicyReason.consentRequired),
        );
        expect(networkChecks, 3);
        expect(calls, 0);
        expect(budget.spentMicrocredits, 0);
      },
    );

    test(
      'wraps failing policy callbacks without leaking their messages',
      () async {
        final backend = RemoteBackend(
          policy: allowedPolicy(hasConsent: () => throw StateError('private')),
          transport: fakeRemote,
        );
        await expectLater(
          backend.evaluate(routingRequest()),
          throwsA(
            isA<RemotePolicyException>().having(
              (e) => e.toString(),
              'safe message',
              isNot(contains('private')),
            ),
          ),
        );
      },
    );
  });

  group('masking and validation', () {
    test(
      'masks state, instructions and criteria immediately before dispatch',
      () async {
        final order = <String>[];
        final original = routingRequest();
        final backend = RemoteBackend(
          policy: allowedPolicy(
            beforeRemote: (request) {
              order.add('mask');
              expect(
                () => (request.state as Map)['contact'] = 'changed',
                throwsUnsupportedError,
              );
              return SystemOneRequest(
                model: request.model,
                state: {'contact': '[masked]'},
                questions: {
                  'topic': ChoiceQuestion(
                    instructions: '[masked]',
                    criteria: {'a': '[masked]', 'b': 'other'},
                  ),
                },
              );
            },
            estimateCost: (request) {
              order.add('cost');
              expect(request.state, {'contact': '[masked]'});
              expect(() => request.questions.clear(), throwsUnsupportedError);
              return 1;
            },
          ),
          transport: (json) async {
            order.add('transport');
            expect(
              json.toString(),
              isNot(contains('synthetic@example.invalid')),
            );
            expect(json.toString(), isNot(contains('synthetic instruction')));
            expect(json.toString(), isNot(contains('synthetic criterion')));
            expect(() => json['model'] = 'changed', throwsUnsupportedError);
            expect(
              () => (json['questions'] as Map).clear(),
              throwsUnsupportedError,
            );
            return fakeRemote(json);
          },
        );
        final response = await backend.evaluate(original);
        expect(order, ['mask', 'cost', 'transport']);
        expect(response.xRoute, 'remote');
        expect(
          original.state.toString(),
          contains('synthetic@example.invalid'),
        );
      },
    );

    test('rejects changed answer shape without spending budget', () async {
      var calls = 0;
      final budget = RemoteBudget(dailyLimitMicrocredits: 1);
      final backend = RemoteBackend(
        policy: allowedPolicy(
          budget: budget,
          beforeRemote: (request) => SystemOneRequest(
            model: request.model,
            state: request.state,
            questions: {
              'topic': ChoiceQuestion(criteria: {'changed': null}),
            },
          ),
        ),
        transport: (request) async {
          calls++;
          return fakeRemote(request);
        },
      );
      await expectLater(
        backend.evaluate(routingRequest()),
        throwsA(isA<RemoteMaskingException>()),
      );
      expect(calls, 0);
      expect(budget.spentMicrocredits, 0);
    });

    test('wraps masking exceptions without leaking their messages', () async {
      final backend = RemoteBackend(
        policy: allowedPolicy(beforeRemote: (_) => throw StateError('private')),
        transport: fakeRemote,
      );
      await expectLater(
        backend.evaluate(routingRequest()),
        throwsA(
          isA<RemoteMaskingException>().having(
            (e) => e.toString(),
            'safe message',
            isNot(contains('private')),
          ),
        ),
      );
    });

    test('validates input without needing DecisionClient', () async {
      var calls = 0;
      final backend = RemoteBackend(
        policy: allowedPolicy(),
        transport: (request) async {
          calls++;
          return fakeRemote(request);
        },
      );
      await expectLater(
        backend.evaluate(
          SystemOneRequest(state: 's', model: 'm', questions: {}),
        ),
        throwsA(isA<SystemOneFormatException>()),
      );
      expect(calls, 0);
    });

    test(
      'rejects incomplete successful response as typed invalid response',
      () async {
        final backend = RemoteBackend(
          policy: allowedPolicy(),
          transport: (_) async => RemoteTransportResponse(
            statusCode: 200,
            body: {
              'model': 'm',
              'answers': {
                'wrong': {'type': 'noul', 'noul': 0.5},
              },
              'usage': {'input_tokens': 0, 'output_tokens': 0},
            },
          ),
        );
        await expectLater(
          backend.evaluate(routingRequest()),
          throwsA(isA<RemoteResponseException>()),
        );
      },
    );
  });

  group('cost budget', () {
    test('concurrent dispatch cannot both consume the final credit', () async {
      final release = Completer<void>();
      var calls = 0;
      final budget = RemoteBudget(dailyLimitMicrocredits: 1);
      final backend = RemoteBackend(
        policy: allowedPolicy(budget: budget),
        transport: (request) async {
          calls++;
          await release.future;
          return fakeRemote(request);
        },
      );
      final first = backend.evaluate(routingRequest());
      await expectLater(
        backend.evaluate(routingRequest()),
        policyFailure(RemotePolicyReason.budgetExhausted),
      );
      expect(calls, 1);
      expect(budget.spentMicrocredits, 1);
      release.complete();
      await first;
    });

    test('dispatched transport failures still consume reserved cost', () async {
      final budget = RemoteBudget(dailyLimitMicrocredits: 3);
      final backend = RemoteBackend(
        policy: allowedPolicy(budget: budget, estimateCost: (_) => 3),
        transport: (_) async => throw StateError('private'),
      );
      await expectLater(
        backend.evaluate(routingRequest()),
        throwsA(
          isA<RemoteTransportException>().having(
            (e) => e.toString(),
            'safe message',
            isNot(contains('private')),
          ),
        ),
      );
      expect(budget.spentMicrocredits, 3);
      await expectLater(
        backend.evaluate(routingRequest()),
        policyFailure(RemotePolicyReason.budgetExhausted),
      );
    });

    test(
      'new UTC day resets budget and clock rollback cannot replenish it',
      () {
        var clock = DateTime.utc(2026, 10, 4, 23, 59);
        final budget = RemoteBudget(
          dailyLimitMicrocredits: 2,
          now: () => clock,
        );
        expect(budget.tryCharge(2), isTrue);
        expect(budget.tryCharge(1), isFalse);
        clock = DateTime.utc(2026, 10, 5);
        expect(budget.tryCharge(1), isTrue);
        clock = DateTime.utc(2026, 10, 4);
        expect(budget.tryCharge(2), isFalse);
        expect(budget.spentMicrocredits, 1);
      },
    );

    test('rejects negative or unsafe integer limits and costs', () async {
      expect(
        () => RemoteBudget(dailyLimitMicrocredits: -1),
        throwsArgumentError,
      );
      expect(
        () => RemoteBudget(dailyLimitMicrocredits: 9007199254740992),
        throwsArgumentError,
      );
      final budget = RemoteBudget(dailyLimitMicrocredits: 1);
      expect(() => budget.tryCharge(-1), throwsArgumentError);
      final backend = RemoteBackend(
        policy: allowedPolicy(budget: budget, estimateCost: (_) => -1),
        transport: fakeRemote,
      );
      await expectLater(
        backend.evaluate(routingRequest()),
        policyFailure(RemotePolicyReason.costEstimateFailed),
      );
      expect(budget.spentMicrocredits, 0);
    });
  });

  group('status errors', () {
    for (final entry in {
      401: RemoteStatusKind.unauthorized,
      422: RemoteStatusKind.invalidRequest,
      429: RemoteStatusKind.rateLimited,
      529: RemoteStatusKind.overloaded,
      503: RemoteStatusKind.unexpected,
    }.entries) {
      test('maps ${entry.key} to ${entry.value.name}', () async {
        final budget = RemoteBudget(dailyLimitMicrocredits: 1);
        final backend = RemoteBackend(
          policy: allowedPolicy(budget: budget),
          transport: (_) async => RemoteTransportResponse(
            statusCode: entry.key,
            body: 'private remote message',
          ),
        );
        await expectLater(
          backend.evaluate(routingRequest()),
          throwsA(
            isA<RemoteStatusException>()
                .having((e) => e.statusCode, 'status', entry.key)
                .having((e) => e.kind, 'kind', entry.value)
                .having(
                  (e) => e.toString(),
                  'safe message',
                  isNot(contains('private')),
                ),
          ),
        );
        expect(budget.spentMicrocredits, 1);
      });
    }
  });
}
