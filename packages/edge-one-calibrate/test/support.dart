import 'dart:convert';

import 'package:crypto/crypto.dart';

final modelHash = 'a' * 64;

Map<String, Object?> record(int index, {double p = 0.9, bool correct = true}) =>
    {
      'version': 1,
      'request_sha256': sha256
          .convert(utf8.encode('synthetic request $index'))
          .toString(),
      'model_sha256': modelHash,
      'request': {
        'state': 'Synthetic item $index',
        'model': 'synthetic',
        'questions': {
          'topic': {
            'type': 'choice',
            'criteria': {'a': 'A', 'b': 'B'},
          },
          'flag': {'type': 'noul'},
          'level': {
            'type': 'score',
            'criteria': ['low', 'high'],
          },
        },
      },
      'response': {
        'model': 'synthetic',
        'answers': {
          'topic': {
            'type': 'choice',
            'choice': 'a',
            'probabilities': {'a': p, 'b': 1 - p},
            'confidence': 2 * p - 1,
          },
          'flag': {'type': 'noul', 'noul': p},
          'level': {
            'type': 'score',
            'score': p,
            'legend': {'low': 'low', 'high': 'high'},
            'probabilities': {'low': 1 - p, 'high': p},
            'confidence': 2 * p - 1,
          },
        },
        'usage': {'input_tokens': 0, 'output_tokens': 0},
      },
      'labels': {
        'topic': correct ? 'a' : 'b',
        'flag': correct,
        'level': correct ? 'high' : 'low',
      },
    };

String jsonl(Iterable<Map<String, Object?>> rows) =>
    rows.map(jsonEncode).join('\n');

List<Map<String, Object?>> fixture() => [
  for (var i = 0; i < 120; i++)
    record(
      i,
      p: i % 10 < 4
          ? 0.99
          : i % 10 < 7
          ? 0.85
          : 0.55,
      correct: i % 10 < 7 || i.isEven,
    ),
];

Map<String, Object?> copy(Map<String, Object?> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, Object?>;
