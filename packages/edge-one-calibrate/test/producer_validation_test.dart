import 'dart:convert';
import 'dart:io';

import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';
import 'package:edge_one_calibrate/edge_one_calibrate.dart';
import 'package:test/test.dart';

import 'support.dart';

Future<(List<SystemOneRequest>, List<Map<String, Object?>>)> capture({
  bool hidden = false,
  String? drift,
}) async {
  final originals = <SystemOneRequest>[];
  final sink = StringBuffer();
  final recorder = RecordingBackend.record(
    FakeEngine(
      weights: {
        'q': {'a': 9, 'b': 1},
      },
    ),
    sink,
    redact: (request) => hidden
        ? SystemOneRequest(
            state: {'removed': true},
            model: request.model,
            questions: {
              'q': ChoiceQuestion(
                instructions: 'removed',
                criteria: {'a': 'removed', 'b': 'removed'},
              ),
            },
          )
        : request,
  );
  for (var i = 0; i < 8; i++) {
    final request = SystemOneRequest(
      state: 'Synthetic item $i',
      model: 'test',
      questions: {
        'q': ChoiceQuestion(
          instructions: drift == 'instructions' ? 'version ${i % 2}' : 'fixed',
          criteria: {
            'a': drift == 'criteria' ? 'meaning ${i % 2}' : 'A',
            'b': 'B',
          },
        ),
      },
    );
    originals.add(request);
    await recorder.evaluate(request);
  }
  return (
    originals,
    [
      for (final line in const LineSplitter().convert(sink.toString()))
        {
          ...jsonDecode(line) as Map<String, Object?>,
          'model_sha256': modelHash,
          'labels': {'q': 'a'},
        },
    ],
  );
}

void main() {
  for (final drift in ['instructions', 'criteria']) {
    test(
      'producer rejects original $drift drift hidden by real custom recorder',
      () async {
        final (originals, rows) = await capture(hidden: true, drift: drift);
        expect(
          rows.map((row) => jsonEncode(row['request'])).toSet(),
          hasLength(1),
        );
        expect(
          () => CalibrationIdentitySidecar.fromRequests(originals),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('changes definition'),
            ),
          ),
        );
      },
    );
  }

  test(
    'producer preserves Choice Score and structured instruction order in definitions',
    () {
      final definitions = <List<Map<String, Object?>>>[
        [
          {
            'type': 'choice',
            'criteria': {'a': 'A', 'b': 'B'},
          },
          {
            'type': 'choice',
            'criteria': {'b': 'B', 'a': 'A'},
          },
        ],
        [
          {
            'type': 'score',
            'criteria': ['low', 'high'],
          },
          {
            'type': 'score',
            'criteria': ['high', 'low'],
          },
        ],
        [
          {
            'type': 'noul',
            'instructions': {'a': 1, 'b': 2},
          },
          {
            'type': 'noul',
            'instructions': {'b': 2, 'a': 1},
          },
        ],
      ];
      for (final pair in definitions) {
        final originals = [
          for (var i = 0; i < pair.length; i++)
            SystemOneJson.decodeRequest({
              'state': 'item $i',
              'model': 'test',
              'questions': {'q': pair[i]},
            }),
        ];
        expect(
          () => CalibrationIdentitySidecar.fromRequests(originals),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('changes definition'),
            ),
          ),
        );
      }
    },
  );

  test(
    'stable masked original definitions remain usable through explicit producer trust',
    () async {
      final (originals, rows) = await capture(hidden: true);
      final sidecar = CalibrationIdentitySidecar.fromRequests(originals);
      final trusted = fitCalibration(
        CalibrationDataset.parse(
          jsonl(rows),
          modelSha256: modelHash,
          identitySidecar: sidecar,
          redactedRequests: true,
          trustIdentitySidecar: true,
        ),
      );
      final verified = fitCalibration(
        CalibrationDataset.parse(
          jsonl(rows),
          modelSha256: modelHash,
          identitySidecar: sidecar,
          redactedRequests: true,
          originalRequests: {
            for (final request in originals)
              RecordingBackend.requestSha256(request): request,
          },
        ),
      );
      expect(trusted.report, verified.report);
      expect(trusted.profile.toJson(), verified.profile.toJson());
    },
  );

  test(
    'legacy unhidden recorder rows reject stale and arbitrary raw digests',
    () async {
      final (_, rows) = await capture();
      expect(
        fitCalibration(
          CalibrationDataset.parse(jsonl(rows), modelSha256: modelHash),
        ).report['version'],
        1,
      );
      for (final mutate in <void Function(Map<String, Object?>)>[
        (row) => row['request_sha256'] = '0' * 64,
        (row) => (row['request'] as Map)['state'] = 'changed after capture',
      ]) {
        final changed = rows.map(copy).toList();
        mutate(changed.first);
        expect(
          () =>
              CalibrationDataset.parse(jsonl(changed), modelSha256: modelHash),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('raw request digest mismatch'),
            ),
          ),
        );
      }
    },
  );

  test(
    'CLI rejects unhidden legacy hash mismatch before publishing outputs',
    () async {
      final (_, rows) = await capture();
      final dir = Directory.systemTemp.createTempSync('legacy-integrity-');
      addTearDown(() => dir.deleteSync(recursive: true));
      rows.first['request_sha256'] = '0' * 64;
      final input = File('${dir.path}/input.jsonl')
        ..writeAsStringSync(jsonl(rows));
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/edge_one_calibrate.dart',
        'fit',
        '--input',
        input.path,
        '--model-sha256',
        modelHash,
        '--output',
        '${dir.path}/thresholds.json',
        '--report',
        '${dir.path}/report.json',
      ]);
      expect(result.exitCode, 65, reason: '${result.stderr}');
      expect(result.stderr, contains('raw request digest mismatch'));
      expect(File('${dir.path}/thresholds.json').existsSync(), isFalse);
      expect(File('${dir.path}/report.json').existsSync(), isFalse);
    },
  );
}
