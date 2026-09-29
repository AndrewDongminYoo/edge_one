import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';
import 'package:test/test.dart';

enum Team { billing, shipping, returns }

void main() {
  final request = SystemOneJson.decodeRequest({
    'state': {'ticket': 'Charged twice'},
    'model': 'test-model',
    'questions': {
      'team': {
        'type': 'choice',
        'criteria': {'billing': null, 'shipping': null, 'returns': null},
      },
      'urgent': {'type': 'noul'},
      'impact': {
        'type': 'score',
        'criteria': ['low', 'medium', 'high', 'critical'],
      },
    },
  });

  Future<Map<String, Object?>> answer(
    FakeEngine engine, [
    SystemOneRequest? r,
  ]) async => SystemOneJson.encodeResponse(await engine.evaluate(r ?? request));

  test('answers unconfigured questions uniformly', () async {
    final response = await answer(FakeEngine());
    expect(response['model'], 'test-model');
    expect(response['usage'], {'input_tokens': 0, 'output_tokens': 0});
    expect(response['x_engine'], FakeEngine.engine);
    final answers = response['answers'] as Map<String, Object?>;
    expect(answers['team'], {
      'type': 'choice',
      'choice': 'billing',
      'probabilities': {'billing': 1 / 3, 'shipping': 1 / 3, 'returns': 1 / 3},
      'confidence': 0.0,
    });
    expect(answers['urgent'], {'type': 'noul', 'noul': 0.5});
    expect(answers['impact'], {
      'type': 'score',
      'score': 1.5,
      'legend': {'0': 'low', '1': 'medium', '2': 'high', '3': 'critical'},
      'probabilities': {'0': 0.25, '1': 0.25, '2': 0.25, '3': 0.25},
      'confidence': 0.0,
    });
  });

  test('normalizes configured weights and zeroes omitted keys', () async {
    final engine = FakeEngine(
      weights: {
        'team': {'shipping': 6, 'returns': 2},
        'urgent': {'true': 1, 'false': 3},
        'impact': {'3': 1},
      },
    );
    final answers = (await answer(engine))['answers'] as Map<String, Object?>;
    expect(answers['team'], {
      'type': 'choice',
      'choice': 'shipping',
      'probabilities': {'billing': 0.0, 'shipping': 0.75, 'returns': 0.25},
      'confidence': closeTo(0.625, 1e-12),
    });
    expect(answers['urgent'], {'type': 'noul', 'noul': 0.25});
    expect((answers['impact'] as Map)['score'], 3.0);
    expect((answers['impact'] as Map)['confidence'], 1.0);
  });

  test('breaks ties by option order', () async {
    final engine = FakeEngine(
      weights: {
        'team': {'returns': 1, 'shipping': 1},
      },
    );
    final answers = (await answer(engine))['answers'] as Map<String, Object?>;
    expect((answers['team'] as Map)['choice'], 'shipping');
  });

  test('treats a single option as certain', () async {
    final single = SystemOneJson.decodeRequest({
      'state': 's',
      'model': 'm',
      'questions': {
        'only': {
          'type': 'choice',
          'criteria': {'yes': null},
        },
      },
    });
    final answers =
        (await answer(FakeEngine(), single))['answers'] as Map<String, Object?>;
    expect((answers['only'] as Map)['confidence'], 1.0);
  });

  test('returns identical responses regardless of call order', () async {
    final engine = FakeEngine(
      weights: {
        'team': {'billing': 2, 'returns': 1},
      },
    );
    final first = await answer(engine);
    await answer(
      engine,
      SystemOneJson.decodeRequest({
        ...SystemOneJson.encodeRequest(request),
        'model': 'other',
      }),
    );
    expect(await answer(engine), first);
    expect(await answer(FakeEngine(weights: engine.weights)), first);
  });

  test('produces answers that pass schema and pairing checks', () async {
    final response = await FakeEngine().evaluate(request);
    expect(
      () => SystemOneJson.checkAnswers(
        request.questions,
        SystemOneJson.decodeResponse(SystemOneJson.encodeResponse(response)),
      ),
      returnsNormally,
    );
  });

  test('drives typed decisions through DecisionClient', () async {
    final client = DecisionClient(
      FakeEngine(
        weights: {
          'team': {'returns': 9, 'billing': 1},
          'urgent': {'false': 1},
        },
      ),
      model: 'fake',
      minConfidence: 0.6,
    );
    final evaluation = await client.evaluate(
      state: 'Where is my refund?',
      questions: {
        'team': Choice.fromEnum(Team.values, 'Which team?'),
        'urgent': Noul('Urgent?'),
        'impact': Score('Impact?', ['low', 'high']),
      },
    );
    expect(
      evaluation.choice<Team>('team'),
      isA<Decided<Team>>().having((d) => d.value, 'value', Team.returns),
    );
    expect(
      evaluation.noul('urgent'),
      isA<Decided<bool>>().having((d) => d.value, 'value', isFalse),
    );
    expect(evaluation.score('impact'), isA<Uncertain<num>>());
  });

  test('normalizes weights whose sum would overflow', () async {
    for (final weight in [1e308, double.maxFinite, 5e-324]) {
      final engine = FakeEngine(
        weights: {
          'team': {'billing': weight, 'shipping': weight},
        },
      );
      final answers = (await answer(engine))['answers'] as Map<String, Object?>;
      expect((answers['team'] as Map)['probabilities'], {
        'billing': 0.5,
        'shipping': 0.5,
        'returns': 0.0,
      });
    }
  });

  test('rejects a Choice without options', () async {
    final empty = SystemOneJson.decodeRequest({
      'state': 's',
      'model': 'm',
      'questions': {
        'pick': {'type': 'choice', 'criteria': {}},
      },
    });
    await expectLater(
      FakeEngine().evaluate(empty),
      throwsA(
        isA<SystemOneFormatException>().having(
          (e) => e.pointer,
          'pointer',
          '/questions/pick/criteria',
        ),
      ),
    );
  });

  test('rejects weights that do not fit the question', () async {
    await expectLater(
      FakeEngine(
        weights: {
          'team': {'sales': 1},
        },
      ).evaluate(request),
      throwsStateError,
    );
    await expectLater(
      FakeEngine(
        weights: {
          'impact': {'4': 1},
        },
      ).evaluate(request),
      throwsStateError,
    );
    await expectLater(
      FakeEngine(
        weights: {
          'urgent': {'true': 0, 'false': 0},
        },
      ).evaluate(request),
      throwsStateError,
    );
  });

  test('rejects negative or non-finite weights', () {
    expect(
      () => FakeEngine(
        weights: {
          'team': {'billing': -1},
        },
      ),
      throwsArgumentError,
    );
    expect(
      () => FakeEngine(
        weights: {
          'team': {'billing': double.nan},
        },
      ),
      throwsArgumentError,
    );
  });
}
