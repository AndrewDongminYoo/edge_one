import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'redacted_support.dart';
import 'support.dart';

void main() {
  late Directory temporary;
  late File input;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync(
      'edge-one-calibration-test-',
    );
    input = File('${temporary.path}/input.jsonl')
      ..writeAsStringSync(jsonl(fixture()));
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  Future<ProcessResult> run(List<String> args) => Process.run(
    Platform.resolvedExecutable,
    ['--suppress-analytics', 'run', 'bin/edge_one_calibrate.dart', ...args],
  );
  List<String> fitArgs() => [
    'fit',
    '--input',
    input.path,
    '--model-sha256',
    modelHash,
    '--output',
    '${temporary.path}/thresholds.json',
    '--report',
    '${temporary.path}/report.json',
  ];

  test(
    'fit writes a model-bound artifact and held-out target report without inference',
    () async {
      final result = await run(fitArgs());
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final artifact =
          jsonDecode(
                File('${temporary.path}/thresholds.json').readAsStringSync(),
              )
              as Map;
      final report =
          jsonDecode(File('${temporary.path}/report.json').readAsStringSync())
              as Map;
      expect(artifact['model_sha256'], modelHash);
      expect(
        (artifact['questions'] as Map).keys,
        containsAll(['topic', 'flag', 'level']),
      );
      expect((report['split'] as Map)['fitting'], hasLength(60));
      expect(result.stdout, contains('validation'));
      final check = await run([
        'check',
        '--baseline',
        '${temporary.path}/report.json',
        '--report',
        '${temporary.path}/report.json',
      ]);
      expect(check.exitCode, 0, reason: '${check.stderr}');
    },
  );

  test(
    'check returns a failing exit code on real accuracy and automation regression',
    () async {
      final fit = await run(fitArgs());
      expect(fit.exitCode, 0, reason: '${fit.stderr}');
      final reportFile = File('${temporary.path}/report.json');
      final changed = jsonDecode(reportFile.readAsStringSync()) as Map;
      final question = (changed['questions'] as Map)['topic'] as Map;
      question['validation_accuracy'] = 0.0;
      for (final target in question['targets'] as List) {
        final metrics = (target as Map)['validation'] as Map;
        metrics['accepted'] = 0;
        metrics['errors'] = 0;
        metrics['coverage'] = 0.0;
        metrics['error_rate'] = null;
      }
      final candidate = File('${temporary.path}/changed.json')
        ..writeAsStringSync(jsonEncode(changed));
      final checked = await run([
        'check',
        '--baseline',
        reportFile.path,
        '--report',
        candidate.path,
      ]);
      expect(
        checked.exitCode,
        1,
        reason: '${checked.stdout}\n${checked.stderr}',
      );
      expect(checked.stderr, contains('accuracy'));
      expect(checked.stderr, contains('coverage'));
    },
  );

  test('bad input and model mismatch leave output absent', () async {
    final mismatch = await run([...fitArgs(), '--model-sha256', 'b' * 64]);
    expect(mismatch.exitCode, 65);
    expect(mismatch.stderr, contains('model_sha256'));
    input.writeAsStringSync('{bad json');
    final malformed = await run(fitArgs());
    expect(malformed.exitCode, 65);
    expect(malformed.stderr, contains('line 1'));
    expect(File('${temporary.path}/thresholds.json').existsSync(), isFalse);
  });

  for (final existingArtifact in [false, true]) {
    for (final directoryReport in [false, true]) {
      test(
        'report ${directoryReport ? 'directory' : 'missing parent'} preserves '
        '${existingArtifact ? 'existing' : 'absent'} artifact',
        () async {
          final artifact = File('${temporary.path}/thresholds.json');
          if (existingArtifact) artifact.writeAsStringSync('old artifact');
          final report = directoryReport
              ? '${temporary.path}/report.json'
              : '${temporary.path}/missing/report.json';
          if (directoryReport) Directory(report).createSync();
          final result = await run([...fitArgs(), '--report', report]);
          expect(result.exitCode, 74, reason: '${result.stderr}');
          expect(result.stderr, contains('File error:'));
          expect(result.stdout, isNot(contains('Wrote')));
          expect(artifact.existsSync(), existingArtifact);
          if (existingArtifact)
            expect(artifact.readAsStringSync(), 'old artifact');
          if (directoryReport) expect(Directory(report).existsSync(), isTrue);
          expect(
            temporary.listSync().where(
              (entry) => entry.path.contains('.edge-one-calibrate-'),
            ),
            isEmpty,
          );
        },
      );
    }
  }

  for (final reportIsParent in [false, true]) {
    test('directory link destination cannot replace the other output parent '
        '(report: $reportIsParent)', () async {
      final physical = Directory('${temporary.path}/physical')..createSync();
      final old = File('${physical.path}/old.json')
        ..writeAsStringSync('prior output');
      final parent = Link('${temporary.path}/outputs')..createSync('physical');
      final child = '${parent.path}/old.json';
      final result = await run([
        ...fitArgs(),
        '--output',
        reportIsParent ? child : parent.path,
        '--report',
        reportIsParent ? parent.path : child,
      ]);
      expect(result.exitCode, 74, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, isNot(contains('Wrote')));
      expect(parent.targetSync(), 'physical');
      expect(old.readAsStringSync(), 'prior output');
      expect(File(child).readAsStringSync(), 'prior output');
      expect(
        temporary
            .listSync(recursive: true, followLinks: false)
            .where((entry) => entry.path.contains('.edge-one-calibrate-')),
        isEmpty,
      );
    });
  }

  test('custom-redacted cached input requires the CLI opt-in flag', () async {
    input.writeAsStringSync(jsonl(await customRedactedRecords()));
    final strict = await run(fitArgs());
    expect(strict.exitCode, 65, reason: '${strict.stderr}');
    expect(strict.stderr, contains('raw request digest mismatch'));
    expect(File('${temporary.path}/thresholds.json').existsSync(), isFalse);
    final optedIn = await run([...fitArgs(), '--redacted-requests']);
    expect(optedIn.exitCode, 0, reason: '${optedIn.stderr}');
    final report =
        jsonDecode(File('${temporary.path}/report.json').readAsStringSync())
            as Map;
    expect((report['split'] as Map)['fitting'], hasLength(4));
    expect((report['split'] as Map)['validation'], hasLength(4));
  });

  test(
    'fit help explains whole-input scope and trusted original digests',
    () async {
      final help = await run(['fit', '--help']);
      expect(help.exitCode, 0);
      final text = (help.stdout as String).replaceAll(RegExp(r'\s+'), ' ');
      expect(text, contains('--redacted-requests'));
      expect(text, contains('whole input'));
      expect(text, contains('trusted original request_sha256'));
      expect(text, contains('--trust-identity-sidecar'));
      expect(text, contains('stable question definitions'));
    },
  );

  test(
    'invalid flags and paths return actionable errors without clobbering input',
    () async {
      final help = await run(['--help']);
      expect(help.exitCode, 0);
      expect(help.stdout, contains('fit'));
      expect((await run(['fit'])).exitCode, 64);
      expect((await run([...fitArgs(), '--seed', 'NaN'])).exitCode, 64);
      expect((await run([...fitArgs(), '--target-error', 'NaN'])).exitCode, 64);
      final original = input.readAsStringSync();
      expect((await run([...fitArgs(), '--output', input.path])).exitCode, 64);
      expect(input.readAsStringSync(), original);
      expect(
        (await run([
          ...fitArgs(),
          '--report',
          '${temporary.path}/thresholds.json',
        ])).exitCode,
        64,
      );
      expect(
        (await run([
          ...fitArgs(),
          '--input',
          '${temporary.path}/absent',
        ])).exitCode,
        74,
      );
    },
  );
}
