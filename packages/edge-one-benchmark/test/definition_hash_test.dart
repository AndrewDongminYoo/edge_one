import 'dart:convert';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one_benchmark/edge_one_benchmark.dart';
import 'package:test/test.dart';
import 'support/bundle.dart';

Map<String, Object?> _choice({
  String instructions = 'Select topic.',
  Map<String, Object?> criteria = const {'a': 'Alpha', 'b': 'Beta'},
}) => {'type': 'choice', 'instructions': instructions, 'criteria': criteria};

Map<String, Object?> _score(List<String> criteria) => {
  'type': 'score',
  'instructions': 'Select urgency.',
  'criteria': criteria,
};

Map<String, String> _files(
  List<Map<String, Object?>> definitions, {
  bool reverseCases = false,
}) {
  final files = smallFiles();
  final requests = [
    for (var i = 0; i < definitions.length; i++)
      <String, Object?>{
        'state': 'synthetic definition identity $i',
        'model': 'fixture',
        'questions': {'question': definitions[i]},
      },
  ];
  final cases = [
    for (var i = 0; i < requests.length; i++)
      {
        'version': 1,
        'case_id': 'tickets:$i',
        'request_sha256': requestHash(requests[i]),
        'dataset_id': 'tickets',
        'source_split': 'synthetic',
        'partition': 'evaluation',
        'labels': {'question': definitions[i]['type'] == 'choice' ? 'a' : '0'},
      },
  ];
  replaceFile(files, 'requests.jsonl', lines(requests));
  replaceFile(
    files,
    'cases.jsonl',
    lines(reverseCases ? cases.reversed : cases),
  );
  replaceFile(
    files,
    'backend_fixtures.jsonl',
    lines([
      for (var i = 0; i < requests.length; i++)
        exchange(
          requests[i],
          'local',
          SystemOneJson.encodeResponse(
            SystemOneResponse(
              model: 'fixture',
              answers: {
                'question': switch (definitions[i]['type']) {
                  'choice' => ChoiceAnswer(
                    choice: 'a',
                    probabilities: {
                      for (final key
                          in (definitions[i]['criteria'] as Map).keys)
                        key as String: key == 'a' ? 1 : 0,
                    },
                    confidence: 1,
                  ),
                  _ => ScoreAnswer(
                    score: 0,
                    legend: {
                      for (final entry
                          in (definitions[i]['criteria'] as List<String>)
                              .indexed)
                        '${entry.$1}': entry.$2,
                    },
                    probabilities: {
                      for (
                        var j = 0;
                        j < (definitions[i]['criteria'] as List).length;
                        j++
                      )
                        '$j': j == 0 ? 1 : 0,
                    },
                    confidence: 1,
                  ),
                },
              },
              usage: const Usage(inputTokens: 1, outputTokens: 1),
            ),
          ),
        ),
    ]),
  );
  final suite = jsonDecode(files['suite.json']!) as Map<String, dynamic>;
  suite['runs'] = (suite['runs'] as List)
      .where((run) => run['mode'] == 'local')
      .toList();
  files['suite.json'] = jsonEncode(suite);
  return files;
}

Future<String> _definitionHash(
  List<Map<String, Object?>> definitions, {
  bool reverseCases = false,
}) async {
  final bundle = parseBenchmarkBundle(
    _files(definitions, reverseCases: reverseCases),
  );
  final captures = await replayBenchmark(bundle);
  expect(captures.map((capture) => capture.outcome), everyElement('answered'));
  final report = benchmarkReport(bundle, captures);
  return ((report['datasets'] as List).single['question_definition_sha256']
          as Map)['question']
      as String;
}

void main() {
  final choice = _choice();
  final reorderedChoice = _choice(criteria: {'b': 'Beta', 'a': 'Alpha'});

  test('definition hash ignores Choice option insertion order', () async {
    expect(
      await _definitionHash([reorderedChoice]),
      await _definitionHash([choice]),
    );
  });

  test(
    'definition hash ignores case order for equivalent definitions',
    () async {
      final definitions = [choice, reorderedChoice];
      expect(
        await _definitionHash(definitions, reverseCases: true),
        await _definitionHash(definitions),
      );
    },
  );

  test(
    'definition hash distinguishes instructions and option meanings',
    () async {
      final definitions = [
        choice,
        _choice(instructions: 'Select the other topic.'),
        _choice(criteria: {'a': 'Alpha', 'b': 'Changed meaning'}),
        _choice(criteria: {'a': 'Alpha', 'c': 'Beta'}),
        _choice(criteria: {'a': 'Alpha'}),
      ];
      final hashes = [
        for (final definition in definitions)
          await _definitionHash([definition]),
      ];
      expect(hashes.toSet(), hasLength(definitions.length));
    },
  );

  test('definition hash preserves ordered Score criteria', () async {
    expect(
      await _definitionHash([
        _score(['low', 'high']),
      ]),
      isNot(
        await _definitionHash([
          _score(['high', 'low']),
        ]),
      ),
    );
  });

  test(
    'loader still rejects semantically different definitions in one bundle',
    () {
      for (final definitions in [
        [choice, _choice(instructions: 'Different instructions.')],
        [
          choice,
          _choice(criteria: {'a': 'Changed meaning', 'b': 'Beta'}),
        ],
        [
          _score(['low', 'high']),
          _score(['high', 'low']),
        ],
      ]) {
        expect(
          () => parseBenchmarkBundle(_files(definitions)),
          throwsFormatException,
        );
      }
    },
  );
}
