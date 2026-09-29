import 'package:edge_one/edge_one.dart';
import 'package:test/test.dart';

import 'support.dart';

enum Team { billing, shipping, returns }

void main() {
  final questions = <String, Question<Object?>>{
    'team': Choice.fromEnum(
      Team.values,
      'Which team should handle this?',
      descriptions: {Team.billing: 'payments and refunds'},
    ),
    'urgent': Noul('Does this need urgent human attention?'),
    'impact': Score('How large is the impact?', ['low', 'medium', 'high']),
  };
  SystemOneResponse response({
    num confidence = 0.7,
    num noul = 0.9,
    num scoreConfidence = 0.5,
  }) => SystemOneJson.decodeResponse({
    'model': 'm',
    'answers': {
      'team': {
        'type': 'choice',
        'choice': 'billing',
        'probabilities': {'billing': 0.8, 'shipping': 0.15, 'returns': 0.05},
        'confidence': confidence,
      },
      'urgent': {'type': 'noul', 'noul': noul},
      'impact': {
        'type': 'score',
        'score': 1.2,
        'legend': {'0': 'low', '1': 'medium', '2': 'high'},
        'probabilities': {'0': 0.2, '1': 0.4, '2': 0.4},
        'confidence': scoreConfidence,
      },
    },
    'usage': {'input_tokens': 10, 'output_tokens': 0},
  });
  Evaluation evaluate(SystemOneResponse response, {double threshold = 0.6}) =>
      Evaluation(
        questions: questions,
        response: response,
        minConfidence: threshold,
      );

  group('questions', () {
    test('Choice.fromEnum names options after the enum values', () {
      final team = questions['team'] as Choice;
      expect(team.options, {
        'billing': Team.billing,
        'shipping': Team.shipping,
        'returns': Team.returns,
      });
      expect(team.definition.instructions, 'Which team should handle this?');
      expect(team.definition.criteria, {
        'billing': 'payments and refunds',
        'shipping': null,
        'returns': null,
      });
    });

    test('Choice requires options and known descriptions', () {
      expect(() => Choice<int>('pick', {}), throwsArgumentError);
      expect(
        () => Choice('pick', {'one': 1}, descriptions: {'two': 'second'}),
        throwsArgumentError,
      );
    });

    test('Noul includes only the described outcomes', () {
      expect(Noul('urgent?').definition.criteria, isNull);
      expect(Noul('urgent?', whenTrue: 'act now').definition.criteria, {
        'true': 'act now',
      });
      expect(
        Noul('urgent?', whenTrue: 'yes', whenFalse: ['no']).definition.criteria,
        {
          'true': 'yes',
          'false': ['no'],
        },
      );
    });

    test('Score requires at least one level', () {
      expect(() => Score('impact?', []), throwsArgumentError);
      expect(Score('impact?', ['low']).definition.criteria, ['low']);
    });
  });

  group('Evaluation', () {
    test('resolves a confident Choice to its enum value', () {
      final decision = evaluate(response()).choice<Team>('team');
      expect(decision, isA<Decided<Team>>());
      final decided = decision as Decided<Team>;
      expect(decided.value, Team.billing);
      expect(decided.confidence, 0.7);
      expect(decided.probabilities, {
        'billing': 0.8,
        'shipping': 0.15,
        'returns': 0.05,
      });
    });

    test('keeps probabilities when a Choice is uncertain', () {
      final decision = evaluate(response(confidence: 0.4)).choice<Team>('team');
      expect(decision, isA<Uncertain<Team>>());
      expect(decision.confidence, 0.4);
      expect(decision.probabilities['shipping'], 0.15);
    });

    test('supports exhaustive pattern matching', () {
      String route(Decision<Team> decision) => switch (decision) {
        Decided(:final value, :final confidence) => '$value@$confidence',
        Uncertain(:final probabilities) => 'review ${probabilities.length}',
      };
      expect(route(evaluate(response()).choice('team')), 'Team.billing@0.7');
      expect(
        route(evaluate(response(confidence: 0.1)).choice('team')),
        'review 3',
      );
    });

    test('accepts a per-question threshold override', () {
      final evaluation = evaluate(response(confidence: 0.4));
      expect(
        evaluation.choice<Team>('team', minConfidence: 0.4),
        isA<Decided<Team>>(),
      );
      expect(
        evaluation.choice<Team>('team', minConfidence: 0.41),
        isA<Uncertain<Team>>(),
      );
      expect(
        () => evaluation.choice<Team>('team', minConfidence: 1.1),
        throwsArgumentError,
      );
      expect(
        () => evaluation.choice<Team>('team', minConfidence: double.nan),
        throwsArgumentError,
      );
    });

    test('derives Noul confidence from the yes probability', () {
      final yes = evaluate(response(noul: 0.9)).noul('urgent');
      expect(yes, isA<Decided<bool>>());
      expect((yes as Decided<bool>).value, isTrue);
      expect(yes.confidence, closeTo(0.8, 1e-12));
      expect(yes.probabilities['true'], 0.9);
      expect(yes.probabilities['false'], closeTo(0.1, 1e-12));

      final no = evaluate(response(noul: 0.1)).noul('urgent');
      expect((no as Decided<bool>).value, isFalse);
      expect(no.confidence, closeTo(0.8, 1e-12));

      final even = evaluate(response(noul: 0.5)).noul('urgent');
      expect(even, isA<Uncertain<bool>>());
      expect(even.confidence, 0);
    });

    test('resolves a Score to its weighted score', () {
      final decision = evaluate(response()).score('impact', minConfidence: 0.5);
      expect((decision as Decided<num>).value, 1.2);
      expect(decision.probabilities, {'0': 0.2, '1': 0.4, '2': 0.4});
      expect(evaluate(response()).score('impact'), isA<Uncertain<num>>());
    });

    test('rejects accessors for other question kinds', () {
      final evaluation = evaluate(response());
      expect(() => evaluation.choice<Team>('missing'), throwsArgumentError);
      expect(() => evaluation.choice<String>('team'), throwsArgumentError);
      expect(() => evaluation.choice<Team>('urgent'), throwsArgumentError);
      expect(() => evaluation.noul('team'), throwsArgumentError);
      expect(() => evaluation.score('urgent'), throwsArgumentError);
    });

    test('validates the response against the questions', () {
      expect(
        () => Evaluation(
          questions: {...questions, 'extra': Noul('extra?')},
          response: response(),
          minConfidence: 0.6,
        ),
        throwsFormatAt('/answers'),
      );
      expect(
        () => Evaluation(
          questions: questions,
          response: const SystemOneResponse(
            model: 'm',
            answers: {'urgent': NoulAnswer(noul: 1.5)},
            usage: Usage(inputTokens: 1, outputTokens: 0),
          ),
          minConfidence: 0.6,
        ),
        throwsFormatAt('/answers/urgent/noul'),
      );
      expect(
        () => Evaluation(
          questions: {
            'team': Choice('pick', {'billing': 1}),
          },
          response: SystemOneResponse(
            model: 'm',
            answers: {'team': response().answers['team']!},
            usage: const Usage(inputTokens: 1, outputTokens: 0),
          ),
          minConfidence: 0.6,
        ),
        throwsFormatAt('/answers/team/probabilities/shipping'),
      );
    });

    test('rejects thresholds outside [0, 1]', () {
      expect(() => evaluate(response(), threshold: -0.1), throwsArgumentError);
      expect(() => evaluate(response(), threshold: 1.5), throwsArgumentError);
    });
  });
}
