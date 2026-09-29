import 'dart:convert';

import 'package:edge_one/edge_one.dart';
import 'package:test/test.dart';

import 'support.dart';

enum Team { billing, shipping }

final class StubBackend implements SystemOneBackend {
  StubBackend(this.respond);

  final Object? Function(SystemOneRequest request) respond;
  final requests = <SystemOneRequest>[];

  @override
  Future<SystemOneResponse> evaluate(SystemOneRequest request) async {
    requests.add(request);
    return SystemOneJson.decodeResponse(respond(request));
  }
}

final class FixedBackend implements SystemOneBackend {
  const FixedBackend(this.response);

  final SystemOneResponse response;

  @override
  Future<SystemOneResponse> evaluate(SystemOneRequest request) async =>
      response;
}

Map<String, Object?> answersFor(SystemOneRequest request) => {
  'model': request.model,
  'answers': {
    for (final MapEntry(:key, :value) in request.questions.entries)
      key: switch (value) {
        ChoiceQuestion(:final criteria) => {
          'type': 'choice',
          'choice': criteria.keys.first,
          'probabilities': {
            for (final (index, name) in criteria.keys.indexed)
              name: index == 0 ? 1 : 0,
          },
          'confidence': 1,
        },
        NoulQuestion() => {'type': 'noul', 'noul': 0.1},
        ScoreQuestion(:final criteria) => {
          'type': 'score',
          'score': 0,
          'legend': {
            for (final (index, level) in criteria.indexed) '$index': level,
          },
          'probabilities': {
            for (final (index, _) in criteria.indexed)
              '$index': index == 0 ? 1 : 0,
          },
          'confidence': 1,
        },
      },
  },
  'usage': {'input_tokens': 7, 'output_tokens': 0},
  'x_route': 'local',
  'x_trace': ['stub'],
};

void main() {
  group('evaluate', () {
    test('sends a validated request and returns typed decisions', () async {
      final backend = StubBackend(answersFor);
      final client = DecisionClient(
        backend,
        model: 'local-model',
        minConfidence: 0.6,
      );
      final evaluation = await client.evaluate(
        state: {'ticket': 'Charged twice'},
        questions: {
          'team': Choice.fromEnum(Team.values, 'Which team?'),
          'urgent': Noul('Urgent?'),
          'impact': Score('Impact?', ['low', 'high']),
        },
      );

      final request = backend.requests.single;
      expect(request.model, 'local-model');
      expect(SystemOneJson.encodeRequest(request)['questions'], {
        'team': {
          'type': 'choice',
          'instructions': 'Which team?',
          'criteria': {'billing': null, 'shipping': null},
        },
        'urgent': {'type': 'noul', 'instructions': 'Urgent?'},
        'impact': {
          'type': 'score',
          'instructions': 'Impact?',
          'criteria': ['low', 'high'],
        },
      });
      expect(
        () => (request.state as Map)['ticket'] = 'changed',
        throwsUnsupportedError,
      );

      expect(
        evaluation.choice<Team>('team'),
        isA<Decided<Team>>().having((d) => d.value, 'value', Team.billing),
      );
      expect(
        evaluation.noul('urgent'),
        isA<Decided<bool>>().having((d) => d.value, 'value', isFalse),
      );
      expect(evaluation.score('impact'), isA<Decided<num>>());
      expect(evaluation.response.xExtensions, {
        'x_trace': ['stub'],
      });
    });

    test('rejects an invalid request before calling the backend', () async {
      final backend = StubBackend(answersFor);
      final client = DecisionClient(backend, model: 'm', minConfidence: 0.5);
      await expectLater(
        client.evaluate(state: 'ticket', questions: {'urgent': Noul(42)}),
        throwsFormatAt('/questions/urgent/instructions'),
      );
      await expectLater(
        client.evaluate(state: 'ticket', questions: {}),
        throwsFormatAt('/questions'),
      );
      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      await expectLater(
        client.evaluate(state: cyclic, questions: {'urgent': Noul('Urgent?')}),
        throwsFormatAt('/state/self'),
      );
      expect(backend.requests, isEmpty);
    });

    test('rejects a response that skips a question', () async {
      final client = DecisionClient(
        StubBackend(
          (request) => {
            ...answersFor(request),
            'answers': {
              'urgent': {'type': 'noul', 'noul': 0.5},
            },
          },
        ),
        model: 'm',
        minConfidence: 0.5,
      );
      await expectLater(
        client.evaluate(
          state: 'ticket',
          questions: {
            'urgent': Noul('Urgent?'),
            'team': Choice.fromEnum(Team.values, 'Which team?'),
          },
        ),
        throwsFormatAt('/answers'),
      );
    });

    test('rejects thresholds outside [0, 1]', () {
      expect(
        () => DecisionClient(
          StubBackend(answersFor),
          model: 'm',
          minConfidence: 2,
        ),
        throwsArgumentError,
      );
    });
  });

  group('evaluateJson', () {
    const rawRequest = '''
{
  "state": {"ticket": "Where is my parcel?"},
  "model": "remote-model",
  "questions": {
    "team": {"type": "choice", "criteria": {"billing": null, "shipping": "parcels"}},
    "urgent": {"type": "noul", "criteria": null}
  }
}
''';

    test('evaluates a pasted SDK request', () async {
      final backend = StubBackend(answersFor);
      final client = DecisionClient(backend, model: 'unused', minConfidence: 0);
      final response = await client.evaluateJson(
        jsonDecode(rawRequest) as Map<String, Object?>,
      );
      expect(backend.requests.single.model, 'remote-model');
      expect(jsonDecode(jsonEncode(response)), {
        'model': 'remote-model',
        'answers': {
          'team': {
            'type': 'choice',
            'choice': 'billing',
            'probabilities': {'billing': 1, 'shipping': 0},
            'confidence': 1,
          },
          'urgent': {'type': 'noul', 'noul': 0.1},
        },
        'usage': {'input_tokens': 7, 'output_tokens': 0},
        'x_route': 'local',
        'x_trace': ['stub'],
      });
    });

    test('rejects a malformed request before calling the backend', () async {
      final backend = StubBackend(answersFor);
      final client = DecisionClient(backend, model: 'm', minConfidence: 0);
      final request = jsonDecode(rawRequest) as Map<String, Object?>;
      await expectLater(
        client.evaluateJson({...request, 'state': 42}),
        throwsFormatAt('/state'),
      );
      await expectLater(
        client.evaluateJson({...request, 'x_route': 'remote'}),
        throwsFormatAt('/x_route'),
      );
      expect(backend.requests, isEmpty);
    });

    test('rejects a backend response outside the contract', () async {
      final request = jsonDecode(rawRequest) as Map<String, Object?>;
      final extra = DecisionClient(
        StubBackend(
          (decoded) => {
            ...answersFor(decoded),
            'answers': {
              ...answersFor(decoded)['answers'] as Map<String, Object?>,
              'impact': {'type': 'noul', 'noul': 0.5},
            },
          },
        ),
        model: 'm',
        minConfidence: 0,
      );
      await expectLater(
        extra.evaluateJson(request),
        throwsFormatAt('/answers/impact'),
      );

      final invalid = DecisionClient(
        const FixedBackend(
          SystemOneResponse(
            model: 'm',
            answers: {'urgent': NoulAnswer(noul: 1.5)},
            usage: Usage(inputTokens: 1, outputTokens: 0),
          ),
        ),
        model: 'm',
        minConfidence: 0,
      );
      await expectLater(
        invalid.evaluateJson(request),
        throwsFormatAt('/answers/urgent/noul'),
      );
    });
  });
}
