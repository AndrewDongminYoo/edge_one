import 'dart:convert';

import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';

import 'support.dart';

/// Uses the real recorder so digests cover distinct original synthetic states,
/// while a custom structured redactor stores the same request for every row.
Future<List<Map<String, Object?>>> customRedactedRecords({
  int count = 8,
}) async {
  final sink = StringBuffer();
  final recorder = RecordingBackend.record(
    FakeEngine(
      weights: {
        'topic': {'a': 9, 'b': 1},
        'flag': {'true': 9, 'false': 1},
        'level': {'0': 1, '1': 9},
      },
    ),
    sink,
    redact: (request) => SystemOneRequest(
      state: const {'private': 'removed'},
      model: request.model,
      questions: request.questions,
    ),
  );
  for (var i = 0; i < count; i++) {
    await recorder.evaluate(SystemOneJson.decodeRequest(record(i)['request']));
  }
  return [
    for (final line in const LineSplitter().convert(sink.toString()))
      {
        ...jsonDecode(line) as Map<String, Object?>,
        'model_sha256': modelHash,
        'labels': {'topic': 'a', 'flag': true, 'level': '1'},
      },
  ];
}
