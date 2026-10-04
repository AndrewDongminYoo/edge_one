// Regenerates synthetic inputs only. Baselines require explicit review; this
// tool deliberately does not regenerate them as part of a test or CI run.
import 'dart:convert';
import 'dart:io';

import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart' show RecordingBackend;
import 'package:edge_one_calibrate/edge_one_calibrate.dart';

import '../test/support.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    File('test/fixtures/labeled.jsonl')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${jsonl(fixture())}\n');
    return;
  }
  if (args.length != 1 || args.single != '--comparison') {
    throw ArgumentError('expected no arguments or --comparison');
  }
  final rows = fixture().take(24).toList();
  final originals = [
    for (final row in rows) SystemOneJson.decodeRequest(row['request']),
  ];
  for (var i = 0; i < rows.length; i++) {
    rows[i]['request_sha256'] = RecordingBackend.requestSha256(originals[i]);
  }
  File('test/fixtures/comparison-labeled.jsonl')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${jsonl(rows)}\n');
  File('test/fixtures/comparison-sidecar.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(CalibrationIdentitySidecar.fromRequests(originals).toJson())}\n',
  );
}
