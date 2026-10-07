import 'dart:convert';
import 'dart:io';

import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';
import 'package:edge_one_calibrate/edge_one_calibrate.dart';
import 'package:test/test.dart';

import 'support.dart';

Future<List<Map<String, Object?>>> capture(
  String model,
  String physical, {
  RequestRedactor? redact,
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
    redact: redact ?? (request) => request,
  );
  for (var i = 0; i < 16; i++) {
    final request = Map<String, Object?>.from(record(i)['request']! as Map);
    request['model'] = model;
    await recorder.evaluate(SystemOneJson.decodeRequest(request));
  }
  return [
    for (final line in const LineSplitter().convert(sink.toString()))
      {
        ..._recordingLine(line),
        'model_sha256': physical,
        'labels': {'topic': 'a', 'flag': true, 'level': '1'},
      },
  ];
}

Map<String, Object?> _recordingLine(String line) {
  final value = jsonDecode(line) as Map<String, Object?>;
  expect(value.keys.toSet(), {
    'version',
    'request_sha256',
    'request',
    'response',
  });
  return value;
}

List<SystemOneRequest> originals(List<Map<String, Object?>> rows) => [
  for (final row in rows) SystemOneJson.decodeRequest(row['request']),
];

CalibrationDataset dataset(
  List<Map<String, Object?>> rows, {
  CalibrationIdentitySidecar? sidecar,
  bool redacted = false,
  bool trust = false,
  Map<String, SystemOneRequest>? originalRequests,
}) => CalibrationDataset.parse(
  jsonl(rows),
  modelSha256: rows.first['model_sha256']! as String,
  identitySidecar:
      sidecar ?? CalibrationIdentitySidecar.fromRequests(originals(rows)),
  redactedRequests: redacted,
  trustIdentitySidecar: trust,
  originalRequests: originalRequests,
);

void main() {
  test(
    'real recapture/refit compares changed logical and physical models',
    () async {
      final old = await capture('model-v1', modelHash);
      final newer = await capture('model-v2', 'b' * 64);
      final a = fitCalibration(dataset(old));
      final b = fitCalibration(dataset(newer));
      expect(old.first['request_sha256'], isNot(newer.first['request_sha256']));
      expect(checkRegression(a.report, b.report), isEmpty);
      expect(a.report['version'], 2);
      expect(a.report['identity_scheme'], comparisonIdentityScheme);
      expect(a.report['split_scheme'], comparisonSplitScheme);
      expect(a.report['split'], b.report['split']);
      expect(a.report['provenance'], isNot(b.report['provenance']));
      expect(a.profile.modelSha256, modelHash);
      expect(b.profile.modelSha256, 'b' * 64);
      expect(b.profile.forQuestion('topic', modelSha256: modelHash), isNull);
      expect(fitCalibration(dataset(old.reversed.toList())).report, a.report);
      final legacy = fitCalibration(
        CalibrationDataset.parse(jsonl(old), modelSha256: modelHash),
      );
      expect(legacy.report['version'], 1);
      expect(
        () => checkRegression(legacy.report, a.report),
        throwsFormatException,
      );
      final legacyNew = fitCalibration(
        CalibrationDataset.parse(jsonl(newer), modelSha256: 'b' * 64),
      );
      expect(
        () => checkRegression(legacy.report, legacyNew.report),
        throwsFormatException,
      );
    },
  );

  test('ordered digest golden and changes only omit top-level model', () {
    final base = {
      'state': {
        'model': 'nested',
        'n': 1,
        'items': [true, null, 'é'],
      },
      'model': 'one',
      'questions': {
        'x': {
          'type': 'choice',
          'criteria': {'a': 'A', 'b': 'B'},
        },
        'y': {'type': 'noul'},
      },
    };
    String digest(Map<String, Object?> value) =>
        comparisonRequestSha256(SystemOneJson.decodeRequest(value));
    expect(
      digest(base),
      '464ad4d2182ccedd04617e7a8222ea18d5bb4ce503107f3fa3fb1644c64ec94e',
    );
    expect(digest({...base, 'model': 'two'}), digest(base));
    final variants = <Map<String, Object?>>[
      {
        ...base,
        'state': {
          'n': 1,
          'model': 'nested',
          'items': [true, null, 'é'],
        },
      },
      {
        ...base,
        'state': {
          'model': 'changed',
          'n': 1,
          'items': [true, null, 'é'],
        },
      },
      {
        ...base,
        'state': {
          'model': 'nested',
          'n': 1.0,
          'items': [true, null, 'é'],
        },
      },
      {
        ...base,
        'state': {
          'model': 'nested',
          'n': '1',
          'items': [true, null, 'é'],
        },
      },
      {
        ...base,
        'state': {
          'model': 'nested',
          'n': 1,
          'items': [null, true, 'é'],
        },
      },
      {
        ...base,
        'state': {
          'model': 'nested',
          'n': 1,
          'items': [true, null, 'e\u0301'],
        },
      },
      {
        ...base,
        'questions': {
          'y': {'type': 'noul'},
          'x': {
            'type': 'choice',
            'criteria': {'a': 'A', 'b': 'B'},
          },
        },
      },
      {
        ...base,
        'questions': {
          'x': {
            'type': 'choice',
            'criteria': {'b': 'B', 'a': 'A'},
          },
          'y': {'type': 'noul'},
        },
      },
      {
        ...base,
        'questions': {
          'x': {
            'type': 'choice',
            'instructions': 'changed',
            'criteria': {'a': 'A', 'b': 'B'},
          },
          'y': {'type': 'noul'},
        },
      },
    ];
    for (final value in variants) {
      expect(digest(value), isNot(digest(base)));
    }
  });

  test(
    'strict sidecar rejects corrupt duplicate conflicting and missing associations',
    () async {
      final rows = await capture('one', modelHash);
      final sidecar = CalibrationIdentitySidecar.fromRequests(originals(rows));
      final json = sidecar.toJson();
      expect(CalibrationIdentitySidecar.parse(json).toJson(), json);
      final entries = json['associations']! as List;
      for (final broken in [
        {...json, 'version': 2},
        {...json, 'identity_scheme': 'unknown'},
        {...json, 'extra': true},
        {...json, 'associations': []},
        {
          ...json,
          'associations': [...entries, entries.first],
        },
        {
          ...json,
          'associations': [
            entries.first,
            {
              ...entries[1] as Map<String, Object?>,
              'comparison_sha256': (entries.first as Map)['comparison_sha256'],
            },
          ],
        },
        {
          ...json,
          'associations': [
            {
              ...entries.first as Map<String, Object?>,
              'comparison_sha256': 'bad',
            },
          ],
        },
        {
          ...json,
          'associations': [
            entries.first,
            {
              ...entries.first as Map<String, Object?>,
              'comparison_sha256': '0' * 64,
            },
          ],
        },
      ]) {
        expect(
          () => CalibrationIdentitySidecar.parse(broken),
          throwsFormatException,
        );
      }
      expect(
        () => dataset(
          rows,
          sidecar: CalibrationIdentitySidecar.parse({
            ...json,
            'associations': entries.skip(1).toList(),
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => dataset(rows.skip(1).toList(), sidecar: sidecar),
        throwsFormatException,
      );
      final corrupt = CalibrationIdentitySidecar.parse({
        ...json,
        'associations': [
          {
            ...entries.first as Map<String, Object?>,
            'comparison_sha256': '0' * 64,
          },
          ...entries.skip(1),
        ],
      });
      expect(
        () => dataset(rows, sidecar: corrupt, trust: true),
        throwsFormatException,
      );
      final badRaw = rows.map(copy).toList();
      badRaw.first['request_sha256'] = '0' * 64;
      final corruptRaw = CalibrationIdentitySidecar.parse({
        ...json,
        'associations': [
          {
            ...entries.first as Map<String, Object?>,
            'request_sha256': '0' * 64,
          },
          ...entries.skip(1),
        ],
      });
      expect(
        () => dataset(badRaw, sidecar: corruptRaw, trust: true),
        throwsFormatException,
      );
      expect(
        () => CalibrationIdentitySidecar.fromRequests([
          originals(rows).first,
          originals(rows).first,
        ]),
        throwsFormatException,
      );
      final mixed = await capture('two', modelHash);
      expect(
        () => CalibrationIdentitySidecar.fromRequests([
          originals(rows).first,
          originals(mixed)[1],
        ]),
        throwsFormatException,
      );
      expect(
        () => dataset([...rows.take(8), ...mixed.skip(8)], sidecar: sidecar),
        throwsFormatException,
      );
      final physical = rows.map(copy).toList()
        ..first['model_sha256'] = 'b' * 64;
      expect(() => dataset(physical, sidecar: sidecar), throwsFormatException);
    },
  );

  test(
    'redacted collisions require trust or exact verified originals',
    () async {
      final rows = await capture('one', modelHash);
      final sidecar = CalibrationIdentitySidecar.fromRequests(originals(rows));
      final hidden = rows.map(copy).toList();
      for (final row in hidden) {
        (row['request'] as Map)['state'] = '[redacted]';
      }
      expect(() => dataset(hidden, sidecar: sidecar), throwsFormatException);
      expect(
        dataset(hidden, sidecar: sidecar, trust: true).sha256,
        dataset(rows).sha256,
      );
      final source = {
        for (final r in originals(rows)) RecordingBackend.requestSha256(r): r,
      };
      expect(
        dataset(hidden, sidecar: sidecar, originalRequests: source).sha256,
        dataset(rows).sha256,
      );
      final incomplete = {...source}..remove(source.keys.first);
      expect(
        () => dataset(
          hidden,
          sidecar: sidecar,
          originalRequests: incomplete,
          trust: true,
        ),
        throwsFormatException,
      );
      expect(
        () => dataset(
          hidden,
          sidecar: sidecar,
          originalRequests: {...source, '0' * 64: source.values.first},
        ),
        throwsFormatException,
      );
      final incorrect = {...source, source.keys.first: source.values.last};
      expect(
        () => dataset(
          hidden,
          sidecar: sidecar,
          originalRequests: incorrect,
          trust: true,
        ),
        throwsFormatException,
      );
      for (final row in hidden) {
        (row['request'] as Map)['state'] = {'private': 'removed'};
      }
      expect(
        dataset(hidden, sidecar: sidecar, redacted: true, trust: true).sha256,
        dataset(rows).sha256,
      );
      expect(
        () => dataset(hidden, sidecar: sidecar, trust: true),
        throwsFormatException,
      );
      final changed = rows.map(copy).toList();
      (changed.first['request'] as Map)['state'] = 'different original';
      changed.first['request_sha256'] = RecordingBackend.requestSha256(
        SystemOneJson.decodeRequest(changed.first['request']),
      );
      expect(dataset(changed).sha256, isNot(dataset(rows).sha256));
    },
  );

  test(
    'content labels question definitions and ordered Score legends bind identity',
    () async {
      final rows = await capture('one', modelHash);
      final baseline = fitCalibration(dataset(rows)).report;
      for (final change in <void Function(Map<String, Object?>)>[
        (row) => (row['labels'] as Map)['topic'] = 'b',
        (row) => (row['request'] as Map)['state'] =
            '${(row['request'] as Map)['state']} changed',
        (row) =>
            (((row['request'] as Map)['questions'] as Map)['topic']
                    as Map)['instructions'] =
                'new',
        (row) =>
            (((row['request'] as Map)['questions'] as Map)['topic']
                as Map)['criteria'] = {
              'b': 'B',
              'a': 'A',
            },
        (row) =>
            (((row['response'] as Map)['answers'] as Map)['level']
                as Map)['legend'] = {
              '1': 'high',
              '0': 'low',
            },
        (row) =>
            (((row['response'] as Map)['answers'] as Map)['level']
                as Map)['legend'] = {
              '0': 'changed',
              '1': 'high',
            },
      ]) {
        final changed = rows.map(copy).toList();
        for (final row in changed) {
          change(row);
          row['request_sha256'] = RecordingBackend.requestSha256(
            SystemOneJson.decodeRequest(row['request']),
          );
        }
        expect(
          () => checkRegression(
            baseline,
            fitCalibration(dataset(changed)).report,
          ),
          throwsFormatException,
        );
      }
      for (final key in ['identity_scheme', 'split_scheme']) {
        expect(
          () => checkRegression(baseline, {...baseline, key: 'unknown'}),
          throwsFormatException,
        );
      }
      expect(
        () => checkRegression(baseline, {...baseline, 'provenance': []}),
        throwsFormatException,
      );
    },
  );

  test(
    'CLI accepts sidecar and protects all input paths including aliases',
    () async {
      final rows = await capture('one', modelHash);
      final dir = Directory.systemTemp.createTempSync('identity-cli-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final input = File('${dir.path}/input.jsonl')
        ..writeAsStringSync(jsonl(rows));
      final sidecar = File('${dir.path}/sidecar.json')
        ..writeAsStringSync(
          jsonEncode(
            CalibrationIdentitySidecar.fromRequests(originals(rows)).toJson(),
          ),
        );
      final original = File('${dir.path}/originals.json')
        ..writeAsStringSync(
          jsonEncode(originals(rows).map(SystemOneJson.encodeRequest).toList()),
        );
      Future<ProcessResult> run(String output, {String? identity}) =>
          Process.run(Platform.resolvedExecutable, [
            'run',
            'bin/edge_one_calibrate.dart',
            'fit',
            '--input',
            input.path,
            '--identity-sidecar',
            identity ?? sidecar.path,
            '--original-requests',
            original.path,
            '--model-sha256',
            modelHash,
            '--output',
            output,
            '--report',
            '${dir.path}/report.json',
          ]);
      final ok = await run('${dir.path}/thresholds.json');
      expect(ok.exitCode, 0, reason: '${ok.stderr}');
      expect(
        (jsonDecode(File('${dir.path}/report.json').readAsStringSync())
            as Map)['version'],
        2,
      );
      final sidecarBytes = sidecar.readAsStringSync();
      for (final path in [sidecar.path, original.path]) {
        expect((await run(path)).exitCode, 64);
        final link = Link('${dir.path}/alias')..createSync(path);
        expect((await run(link.path)).exitCode, 64);
        link.deleteSync();
      }
      expect(sidecar.readAsStringSync(), sidecarBytes);
    },
  );
  test(
    'v2 validates seeded split membership rather than accepting declarations',
    () async {
      final report = fitCalibration(
        dataset(await capture('one', modelHash)),
      ).report;
      final changed = copy(report);
      final split = changed['split']! as Map;
      final fitting = split['fitting']! as List;
      final validation = split['validation']! as List;
      final old = fitting.first;
      fitting[0] = validation.first;
      validation[0] = old;
      expect(() => checkRegression(changed, changed), throwsFormatException);
    },
  );

  test(
    'CLI recaptures refits and compares logical upgrades including redaction',
    () async {
      final dir = Directory.systemTemp.createTempSync('upgrade-cli-');
      addTearDown(() => dir.deleteSync(recursive: true));
      Future<ProcessResult> cli(List<String> args) => Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/edge_one_calibrate.dart', ...args],
      );
      for (final hidden in [false, true]) {
        for (final version in [1, 2]) {
          final hash = (version == 1 ? 'a' : 'b') * 64;
          final model = 'version-$version';
          final clear = await capture(model, hash);
          final rows = hidden
              ? await capture(model, hash, redact: redactState)
              : clear;
          final input = File('${dir.path}/$version.jsonl')
            ..writeAsStringSync(jsonl(rows));
          final sidecar = File('${dir.path}/$version-sidecar.json')
            ..writeAsStringSync(
              jsonEncode(
                CalibrationIdentitySidecar.fromRequests(
                  originals(clear),
                ).toJson(),
              ),
            );
          final result = await cli([
            'fit',
            '--input',
            input.path,
            '--identity-sidecar',
            sidecar.path,
            if (hidden) '--trust-identity-sidecar',
            '--model-sha256',
            hash,
            '--output',
            '${dir.path}/$version-profile.json',
            '--report',
            '${dir.path}/$version-report.json',
          ]);
          expect(result.exitCode, 0, reason: '${result.stderr}');
        }
        final result = await cli([
          'check',
          '--baseline',
          '${dir.path}/1-report.json',
          '--report',
          '${dir.path}/2-report.json',
          '--max-accuracy-drop',
          '0',
          '--max-coverage-drift',
          '0',
          '--max-error-increase',
          '0',
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
    },
  );
  test('legacy cannot opt into identity trust without sidecar', () async {
    final rows = await capture('one', modelHash);
    expect(
      () => CalibrationDataset.parse(
        jsonl(rows),
        modelSha256: modelHash,
        trustIdentitySidecar: true,
      ),
      throwsFormatException,
    );
    expect(
      () => CalibrationDataset.parse(
        jsonl(rows),
        modelSha256: modelHash,
        originalRequests: {},
      ),
      throwsFormatException,
    );
  });

  test(
    'v2 provenance rejects missing extra duplicate and conflicting pairs',
    () async {
      final report = fitCalibration(
        dataset(await capture('one', modelHash)),
      ).report;
      final provenance = report['provenance']! as List;
      for (final entries in [
        provenance.skip(1).toList(),
        [...provenance, provenance.first],
        [
          ...provenance,
          {'request_sha256': '0' * 64, 'comparison_sha256': '1' * 64},
        ],
        [
          {
            ...provenance.first as Map<String, Object?>,
            'comparison_sha256': '1' * 64,
          },
          ...provenance.skip(1),
        ],
        [
          {
            ...provenance.first as Map<String, Object?>,
            'request_sha256': 'bad',
          },
          ...provenance.skip(1),
        ],
      ]) {
        final bad = {...report, 'provenance': entries};
        expect(() => checkRegression(bad, bad), throwsFormatException);
      }
    },
  );
  test(
    'v2 rejects contradictory shared raw provenance across reports',
    () async {
      final baseline = fitCalibration(
        dataset(await capture('one', modelHash)),
      ).report;
      final candidate = copy(baseline);
      final pairs = candidate['provenance']! as List;
      final first = pairs[0]['request_sha256'];
      pairs[0]['request_sha256'] = pairs[1]['request_sha256'];
      pairs[1]['request_sha256'] = first;
      // Each report remains structurally valid; only the shared raw associations
      // contradict each other. Report-local validation cannot detect this.
      expect(checkRegression(candidate, candidate), isEmpty);
      expect(() => checkRegression(baseline, candidate), throwsFormatException);
      expect(() => checkRegression(candidate, baseline), throwsFormatException);
    },
  );

  test(
    'v2 label insertion order preserves dataset identity and fitted reports',
    () async {
      final rows = await capture('one', modelHash);
      final sidecar = CalibrationIdentitySidecar.fromRequests(originals(rows));
      final reordered = rows.map(copy).toList();
      for (final row in reordered) {
        final labels = row['labels']! as Map<String, Object?>;
        row['labels'] = {
          for (final key in labels.keys.toList().reversed) key: labels[key],
        };
      }
      final before = dataset(rows, sidecar: sidecar);
      final after = dataset(reordered, sidecar: sidecar);
      expect(after.sha256, before.sha256);
      final baseline = fitCalibration(before);
      final candidate = fitCalibration(after);
      expect(candidate.profile.toJson(), baseline.profile.toJson());
      expect(candidate.report, baseline.report);
      expect(checkRegression(baseline.report, candidate.report), isEmpty);
    },
  );
}
