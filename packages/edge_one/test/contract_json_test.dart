import 'dart:convert';

import 'package:edge_one/edge_one.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final request = {
    'state': {
      'ticket': 'Charged twice',
      'tags': ['refund', 2],
    },
    'model': 'model-revision',
    'questions': {
      'team': {
        'type': 'choice',
        'instructions': [
          'Pick one',
          {'locale': 'en'},
        ],
        'criteria': {'billing': 'payments', 'shipping': null},
      },
      'urgent': {
        'type': 'noul',
        'criteria': {'true': 'act now'},
      },
      'impact': {
        'type': 'score',
        'criteria': [
          'low',
          {'level': 'high'},
        ],
      },
    },
  };
  final response = {
    'model': 'model-revision',
    'answers': {
      'team': {
        'type': 'choice',
        'choice': 'billing',
        'probabilities': {'billing': 0.8, 'shipping': 0.2},
        'confidence': 0.6,
      },
      'urgent': {'type': 'noul', 'noul': 0.9},
      'impact': {
        'type': 'score',
        'score': 0.7,
        'legend': {
          '0': 'low',
          '1': {'level': 'high'},
        },
        'probabilities': {'0': 0.3, '1': 0.7},
        'confidence': 0.4,
      },
    },
    'usage': {'input_tokens': 120, 'output_tokens': 0},
    'x_route': 'local',
    'x_latency_ms': 42,
    'x_engine': {'quantization': 'Q4_K_M'},
    'x_trace': ['render', 'score'],
  };

  group('requests', () {
    test('decode Choice, Noul, and Score questions', () {
      final decoded = SystemOneJson.decodeRequest(request);
      expect(decoded.model, 'model-revision');
      expect(decoded.state, request['state']);
      final team = decoded.questions['team'] as ChoiceQuestion;
      expect(team.instructions, [
        'Pick one',
        {'locale': 'en'},
      ]);
      expect(team.criteria.keys, ['billing', 'shipping']);
      expect(team.criteria['shipping'], isNull);
      final urgent = decoded.questions['urgent'] as NoulQuestion;
      expect(urgent.instructions, isNull);
      expect(urgent.criteria, {'true': 'act now'});
      final impact = decoded.questions['impact'] as ScoreQuestion;
      expect(impact.criteria, [
        'low',
        {'level': 'high'},
      ]);
    });

    test('round-trip through jsonEncode unchanged', () {
      final encoded = SystemOneJson.encodeRequest(
        SystemOneJson.decodeRequest(jsonDecode(jsonEncode(request))),
      );
      expect(jsonDecode(jsonEncode(encoded)), request);
    });

    test('omit null instructions and Noul criteria when encoding', () {
      final encoded = SystemOneJson.encodeRequest(
        const SystemOneRequest(
          state: 'ticket',
          model: 'm',
          questions: {'q': NoulQuestion()},
        ),
      );
      expect(encoded['questions'], {
        'q': {'type': 'noul'},
      });
    });

    test('decode into unmodifiable copies', () {
      final source = copyJson(request) as Map<String, Object?>;
      final decoded = SystemOneJson.decodeRequest(source);
      ((source['state'] as Map)['tags'] as List).add('late');
      expect((decoded.state as Map)['tags'], ['refund', 2]);
      expect(
        () => (decoded.state as Map)['ticket'] = 'changed',
        throwsUnsupportedError,
      );
      expect(() => decoded.questions.remove('team'), throwsUnsupportedError);
    });

    test('reject non-JSON values when encoding', () {
      expect(
        () => SystemOneJson.encodeRequest(
          SystemOneRequest(
            state: {'at': DateTime(2026)},
            model: 'm',
            questions: const {'q': NoulQuestion()},
          ),
        ),
        throwsFormatAt('/state/at'),
      );
      expect(
        () => SystemOneJson.encodeRequest(
          const SystemOneRequest(
            state: {'score': double.nan},
            model: 'm',
            questions: {'q': NoulQuestion()},
          ),
        ),
        throwsFormatAt('/state/score'),
      );
      expect(
        () => SystemOneJson.encodeRequest(
          const SystemOneRequest(state: 's', model: 'm', questions: {}),
        ),
        throwsFormatAt('/questions'),
      );
    });

    test('reject non-string object keys', () {
      expect(
        () => SystemOneJson.decodeRequest({
          ...request,
          'state': {1: 'one'},
        }),
        throwsFormatAt('/state'),
      );
    });

    test('reject cyclic values but accept shared ones', () {
      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      expect(
        () => SystemOneJson.decodeRequest({...request, 'state': cyclic}),
        throwsFormatAt('/state/self'),
      );
      final loop = <Object?>[];
      loop.add(loop);
      expect(
        () => SystemOneJson.encodeResponse(
          SystemOneResponse(
            model: 'm',
            answers: const {'q': NoulAnswer(noul: 0.5)},
            usage: const Usage(inputTokens: 1, outputTokens: 0),
            xExtensions: {'x_loop': loop},
          ),
        ),
        throwsFormatAt('/x_loop/0'),
      );
      final shared = {'tier': 'pro'};
      expect(
        SystemOneJson.decodeRequest({
          ...request,
          'state': {'a': shared, 'b': shared},
        }).state,
        {'a': shared, 'b': shared},
      );
    });

    test('escape JSON Pointer characters in error locations', () {
      expect(
        () => SystemOneJson.decodeRequest({
          'state': 's',
          'model': 'm',
          'questions': {
            'a/b~c': {'type': 'noul', 'criteria': 'yes'},
          },
        }),
        throwsFormatAt('/questions/a~1b~0c/criteria'),
      );
    });
  });

  group('responses', () {
    test('decode answers, usage, and extension fields', () {
      final decoded = SystemOneJson.decodeResponse(response);
      final team = decoded.answers['team'] as ChoiceAnswer;
      expect(team.choice, 'billing');
      expect(team.probabilities, {'billing': 0.8, 'shipping': 0.2});
      expect(team.confidence, 0.6);
      expect((decoded.answers['urgent'] as NoulAnswer).noul, 0.9);
      final impact = decoded.answers['impact'] as ScoreAnswer;
      expect(impact.score, 0.7);
      expect(impact.legend['1'], {'level': 'high'});
      expect(decoded.usage.inputTokens, 120);
      expect(decoded.usage.outputTokens, 0);
      expect(decoded.xRoute, 'local');
      expect(decoded.xLatencyMs, 42);
      expect(decoded.xEngine, {'quantization': 'Q4_K_M'});
      expect(decoded.xExtensions, {
        'x_trace': ['render', 'score'],
      });
    });

    test('round-trip through jsonEncode unchanged', () {
      final encoded = SystemOneJson.encodeResponse(
        SystemOneJson.decodeResponse(jsonDecode(jsonEncode(response))),
      );
      expect(jsonDecode(jsonEncode(encoded)), response);
    });

    test('accept integral token counts parsed as doubles', () {
      final decoded = SystemOneJson.decodeResponse(
        jsonDecode(
          '{"model":"m","answers":{"q":{"type":"noul","noul":0.5}},'
          '"usage":{"input_tokens":12.0,"output_tokens":1e1}}',
        ),
      );
      expect(decoded.usage.inputTokens, 12);
      expect(decoded.usage.outputTokens, 10);
    });

    test('reject token counts beyond the JSON-safe integer range', () {
      expect(
        () => SystemOneJson.decodeResponse({
          ...response,
          'usage': {'input_tokens': 9007199254740992.0, 'output_tokens': 0},
        }),
        throwsFormatAt('/usage/input_tokens'),
      );
      expect(
        () => SystemOneJson.decodeResponse({
          ...response,
          'usage': {'input_tokens': 0, 'output_tokens': 9007199254740992},
        }),
        throwsFormatAt('/usage/output_tokens'),
      );
      expect(
        () => SystemOneJson.encodeResponse(
          const SystemOneResponse(
            model: 'm',
            answers: {'q': NoulAnswer(noul: 0.5)},
            usage: Usage(inputTokens: 9007199254740992, outputTokens: 0),
          ),
        ),
        throwsFormatAt('/usage/input_tokens'),
      );
    });

    test('reject non-finite numbers', () {
      expect(
        () => SystemOneJson.decodeResponse({
          ...response,
          'x_latency_ms': double.infinity,
        }),
        throwsFormatAt('/x_latency_ms'),
      );
      expect(
        () => SystemOneJson.decodeResponse({
          ...response,
          'answers': {
            'urgent': {'type': 'noul', 'noul': double.nan},
          },
        }),
        throwsFormatAt('/answers/urgent/noul'),
      );
    });

    test('keep extension fields out of the dedicated fields', () {
      final decoded = SystemOneJson.decodeResponse({
        ...response,
        'x_engine': null,
        'x_debug': null,
      });
      expect(decoded.xEngine, isNull);
      expect(decoded.xExtensions, {
        'x_trace': ['render', 'score'],
        'x_debug': null,
      });
      final encoded = SystemOneJson.encodeResponse(decoded);
      expect(encoded.containsKey('x_engine'), isFalse);
      expect(encoded['x_debug'], isNull);
      expect(encoded.containsKey('x_debug'), isTrue);
    });

    const minimal = SystemOneResponse(
      model: 'm',
      answers: {'q': NoulAnswer(noul: 0.5)},
      usage: Usage(inputTokens: 1, outputTokens: 0),
    );

    test('reject extension names without the x_ prefix when encoding', () {
      expect(
        () => SystemOneJson.encodeResponse(
          const SystemOneResponse(
            model: 'm',
            answers: {'q': NoulAnswer(noul: 0.5)},
            usage: Usage(inputTokens: 1, outputTokens: 0),
            xExtensions: {'model': 'other'},
          ),
        ),
        throwsFormatAt('/model'),
      );
    });

    test('reject extensions that shadow dedicated fields', () {
      expect(
        () => SystemOneJson.encodeResponse(
          const SystemOneResponse(
            model: 'm',
            answers: {'q': NoulAnswer(noul: 0.5)},
            usage: Usage(inputTokens: 1, outputTokens: 0),
            xExtensions: {'x_route': 'local'},
          ),
        ),
        throwsFormatAt('/x_route'),
      );
    });

    test('validate dedicated fields when encoding', () {
      expect(SystemOneJson.encodeResponse(minimal)['model'], 'm');
      expect(
        () => SystemOneJson.encodeResponse(
          const SystemOneResponse(
            model: 'm',
            answers: {'q': NoulAnswer(noul: 0.5)},
            usage: Usage(inputTokens: -1, outputTokens: 0),
          ),
        ),
        throwsFormatAt('/usage/input_tokens'),
      );
      expect(
        () => SystemOneJson.encodeResponse(
          const SystemOneResponse(
            model: 'm',
            answers: {'q': NoulAnswer(noul: 0.5)},
            usage: Usage(inputTokens: 1, outputTokens: 0),
            xRoute: 'edge',
          ),
        ),
        throwsFormatAt('/x_route'),
      );
    });

    test('report the pointer in toString', () {
      expect(
        SystemOneFormatException('', 'expected an object').toString(),
        'SystemOneFormatException at /: expected an object',
      );
    });
  });

  group('checkAnswers', () {
    final questions = SystemOneJson.decodeRequest(request).questions;
    final valid = response['answers'] as Map<String, Object?>;

    SystemOneResponse answers(Map<String, Object?> answers) =>
        SystemOneJson.decodeResponse({...response, 'answers': answers});

    Map<String, Object?> answer(String key, Map<String, Object?> changes) => {
      ...valid,
      key: {...valid[key] as Map<String, Object?>, ...changes},
    };

    test('accept answers that match every question', () {
      expect(
        () => SystemOneJson.checkAnswers(
          questions,
          SystemOneJson.decodeResponse(response),
        ),
        returnsNormally,
      );
    });

    test('reject a missing answer', () {
      expect(
        () => SystemOneJson.checkAnswers(
          questions,
          answers({...valid}..remove('urgent')),
        ),
        throwsFormatAt('/answers'),
      );
    });

    test('reject an answer without a question', () {
      expect(
        () => SystemOneJson.checkAnswers(
          questions,
          answers({
            ...valid,
            'extra': {'type': 'noul', 'noul': 0.5},
          }),
        ),
        throwsFormatAt('/answers/extra'),
      );
    });

    test('reject an answer of another type', () {
      expect(
        () => SystemOneJson.checkAnswers(
          questions,
          answers({
            ...valid,
            'team': {'type': 'noul', 'noul': 0.5},
          }),
        ),
        throwsFormatAt('/answers/team/type'),
      );
    });

    test('reject Choice probabilities for other options', () {
      expect(
        () => SystemOneJson.checkAnswers(
          questions,
          answers(
            answer('team', {
              'probabilities': {'billing': 1},
            }),
          ),
        ),
        throwsFormatAt('/answers/team/probabilities'),
      );
      expect(
        () => SystemOneJson.checkAnswers(
          questions,
          answers(
            answer('team', {
              'probabilities': {'billing': 0.5, 'shipping': 0.3, 'sales': 0.2},
            }),
          ),
        ),
        throwsFormatAt('/answers/team/probabilities/sales'),
      );
    });

    test('reject a choice outside the options', () {
      expect(
        () => SystemOneJson.checkAnswers(
          questions,
          answers(answer('team', {'choice': 'sales'})),
        ),
        throwsFormatAt('/answers/team/choice'),
      );
    });

    test('reject probabilities that do not sum to one', () {
      expect(
        () => SystemOneJson.checkAnswers(
          questions,
          answers(
            answer('team', {
              'probabilities': {'billing': 0.8, 'shipping': 0.1},
            }),
          ),
        ),
        throwsFormatAt('/answers/team/probabilities'),
      );
      expect(
        () => SystemOneJson.checkAnswers(
          questions,
          answers(
            answer('team', {
              'probabilities': {'billing': 0.5, 'shipping': 0.489},
            }),
          ),
        ),
        throwsFormatAt('/answers/team/probabilities'),
      );
    });

    test('accept probability totals on the tolerance boundary', () {
      // Both totals differ from 1 by 0.010000000000000009 in binary64.
      for (final shipping in [0.49, 0.51]) {
        expect(
          () => SystemOneJson.checkAnswers(
            questions,
            answers(
              answer('team', {
                'probabilities': {'billing': 0.5, 'shipping': shipping},
              }),
            ),
          ),
          returnsNormally,
        );
      }
    });

    test('reject a Score legend with another level count', () {
      expect(
        () => SystemOneJson.checkAnswers(
          questions,
          answers(
            answer('impact', {
              'legend': {'0': 'low'},
              'probabilities': {'0': 1},
            }),
          ),
        ),
        throwsFormatAt('/answers/impact/legend'),
      );
    });

    test('reject Score probabilities keyed by other levels', () {
      expect(
        () => SystemOneJson.checkAnswers(
          questions,
          answers(
            answer('impact', {
              'probabilities': {'0': 0.3, '2': 0.7},
            }),
          ),
        ),
        throwsFormatAt('/answers/impact/probabilities'),
      );
      expect(
        () => SystemOneJson.checkAnswers(
          questions,
          answers(
            answer('impact', {
              'probabilities': {'0': 0.3, '1': 0.6, '2': 0.1},
            }),
          ),
        ),
        throwsFormatAt('/answers/impact/probabilities/2'),
      );
    });
  });
}
