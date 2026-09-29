import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';
import 'package:test/test.dart';

import '../tool/update_examples.dart' show fakeEngineFor;
import 'support.dart';

typedef Json = Map<String, Object?>;

void main() {
  final examples =
      ((readRepoJson('schemas/examples/system-one-v1-examples.json')
                  as Json)['examples']
              as List)
          .cast<Json>();
  final recording = readRepoText(
    'schemas/examples/system-one-v1-recording.jsonl',
  );

  test('examples cover every question type and structured values', () {
    final requests = [
      for (final example in examples)
        SystemOneJson.decodeRequest(example['request']),
    ];
    final questions = [
      for (final request in requests) ...request.questions.values,
    ];
    expect(questions.whereType<ChoiceQuestion>(), isNotEmpty);
    expect(questions.whereType<NoulQuestion>(), isNotEmpty);
    expect(questions.whereType<ScoreQuestion>(), isNotEmpty);
    expect(requests.map((r) => r.state), contains(isA<Map>()));
    expect(requests.map((r) => r.state), contains(isA<String>()));
    expect(requests.map((r) => r.state), contains(isA<List>()));
    expect(questions.map(_instructions), contains(isA<Map>()));
    expect(questions.map(_instructions), contains(isA<List>()));
  });

  for (final example in examples) {
    final name = example['name'];

    test('FakeEngine answers "$name" with its stored response', () async {
      final request = SystemOneJson.decodeRequest(example['request']);
      final response = await fakeEngineFor(example).evaluate(request);
      expect(SystemOneJson.encodeResponse(response), example['fake_response']);
      expect(
        () => SystemOneJson.checkAnswers(
          request.questions,
          SystemOneJson.decodeResponse(example['fake_response']),
        ),
        returnsNormally,
      );
    });

    test('DecisionClient.evaluateJson accepts "$name"', () async {
      final client = DecisionClient(
        fakeEngineFor(example),
        model: 'unused',
        minConfidence: 0,
      );
      expect(
        await client.evaluateJson(example['request'] as Json),
        example['fake_response'],
      );
    });
  }

  test('the stored recording matches a fresh recording', () async {
    final sink = StringBuffer();
    for (final example in examples) {
      await RecordingBackend.record(
        fakeEngineFor(example),
        sink,
      ).evaluate(SystemOneJson.decodeRequest(example['request']));
    }
    expect(
      sink.toString(),
      recording,
      reason: 'Run dart run tool/update_examples.dart in packages/edge_one',
    );
  });

  test('the stored recording replays every example', () async {
    final replay = RecordingBackend.replay(recording);
    for (final example in examples) {
      final response = await replay.evaluate(
        SystemOneJson.decodeRequest(example['request']),
      );
      expect(SystemOneJson.encodeResponse(response), example['fake_response']);
    }
  });
}

OptionalStructuredValue _instructions(SystemOneQuestion question) =>
    switch (question) {
      ChoiceQuestion(:final instructions) => instructions,
      ScoreQuestion(:final instructions) => instructions,
      NoulQuestion(:final instructions) => instructions,
    };
