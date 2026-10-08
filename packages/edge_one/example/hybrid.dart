import 'dart:convert';

import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';

// Synthetic demonstration only: both backends are FakeEngine instances and all
// data stays in this process. A production adapter supplies its own transport,
// consent/network checks, complete masking, pricing bound, and verified hash.
Future<void> main() async {
  final modelHash = 'a' * 64;
  final budget = RemoteBudget(dailyLimitMicrocredits: 2);
  final remote = RemoteBackend(
    policy: RemotePolicy(
      localOnly: false,
      hasConsent: () => true,
      isNetworkAvailable: () => true,
      beforeRemote: (request) => SystemOneRequest(
        model: request.model,
        state: '[masked synthetic state]',
        questions: {
          for (final entry in request.questions.entries)
            entry.key: switch (entry.value) {
              ChoiceQuestion(:final criteria) => ChoiceQuestion(
                instructions: '[masked]',
                criteria: {for (final key in criteria.keys) key: null},
              ),
              NoulQuestion() => const NoulQuestion(instructions: '[masked]'),
              ScoreQuestion(:final criteria) => ScoreQuestion(
                instructions: '[masked]',
                criteria: [for (final _ in criteria) '[masked]'],
              ),
            },
        },
      ),
      budget: budget,
      estimateCost: (_) => 1, // Synthetic cost, not real service pricing.
    ),
    transport: (json) async => RemoteTransportResponse(
      statusCode: 200,
      body: SystemOneJson.encodeResponse(
        await FakeEngine().evaluate(SystemOneJson.decodeRequest(json)),
      ),
    ),
  );
  final router = HybridRouter(
    local: FakeEngine(
      weights: {
        'topic': {'billing': 9, 'shipping': 1},
      },
    ),
    remote: remote,
    modelSha256: modelHash,
    calibration: CalibrationProfile.fromJson({
      'version': 1,
      'model_sha256': modelHash,
      'target_error': 0.05,
      'confidence': 'normalized_max_probability',
      'questions': {
        'topic': {'type': 'choice', 'temperature': 1.0, 'threshold': 0.5},
      },
    }),
    forcedRemoteKeys: {'urgent'},
    shadow: ShadowMode(
      sample: (_) =>
          true, // Deterministically sample this one synthetic request.
      observe: (comparison) {
        print('Shadow keys: ${comparison.localAnswers.keys.join(', ')}');
      },
    ),
  );
  final response = await router.evaluate(
    SystemOneRequest(
      model: 'synthetic-model',
      state: {'ticket': 'Synthetic billing example'},
      questions: {
        'topic': ChoiceQuestion(criteria: {'billing': null, 'shipping': null}),
        'urgent': NoulQuestion(instructions: 'Synthetic urgent question'),
      },
    ),
  );
  print(
    const JsonEncoder.withIndent(
      '  ',
    ).convert(SystemOneJson.encodeResponse(response)),
  );
  print('Synthetic cost: ${budget.spentMicrocredits} microcredits');
}
