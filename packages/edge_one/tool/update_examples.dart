// Regenerates the FakeEngine answers and replay recording for the examples.
//
// Run from packages/edge_one: dart run tool/update_examples.dart
// Then format the examples file with `trunk fmt` or prettier.
import 'dart:convert';
import 'dart:io';

import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';

const examplesPath = '../../schemas/examples/system-one-v1-examples.json';
const recordingPath = '../../schemas/examples/system-one-v1-recording.jsonl';

Future<void> main() async {
  final file = File(examplesPath);
  final document = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final recording = StringBuffer();
  final examples = <Object?>[];
  for (final example in document['examples'] as List) {
    final fields = example as Map<String, Object?>;
    final engine = fakeEngineFor(fields);
    final request = SystemOneJson.decodeRequest(fields['request']);
    final response = await RecordingBackend.record(
      engine,
      recording,
    ).evaluate(request);
    examples.add({
      'name': fields['name'],
      'request': fields['request'],
      'fake_weights': fields['fake_weights'],
      'fake_response': SystemOneJson.encodeResponse(response),
    });
  }
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'examples': examples})}\n',
  );
  File(recordingPath).writeAsStringSync(recording.toString());
}

/// Builds the FakeEngine configured by an example's `fake_weights`.
FakeEngine fakeEngineFor(Map<String, Object?> example) => FakeEngine(
  weights: {
    for (final MapEntry(:key, :value)
        in (example['fake_weights'] as Map<String, Object?>).entries)
      key: (value as Map<String, Object?>).cast<String, num>(),
  },
);
