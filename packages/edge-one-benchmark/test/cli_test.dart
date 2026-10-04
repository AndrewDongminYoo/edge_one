import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  late Directory output;
  setUp(() => output = Directory.systemTemp.createTempSync('benchmark-cli-'));
  tearDown(() => output.deleteSync(recursive: true));
  Future<ProcessResult> run(List<String> args) => Process.run(
    Platform.resolvedExecutable,
    ['--suppress-analytics', 'run', 'bin/edge_one_benchmark.dart', ...args],
  );
  const suite = 'test/fixtures/v1/suite.json';
  test(
    'validate and report reproduce reviewed baseline without changing inputs',
    () async {
      final expected = File(
        'test/fixtures/v1/expected-report.json',
      ).readAsStringSync();
      final validation = await run(['validate', '--suite', suite]);
      expect(validation.exitCode, 0, reason: '${validation.stderr}');
      for (var i = 0; i < 2; i++) {
        final target = '${output.path}/report-$i.json';
        final result = await run([
          'report',
          '--suite',
          suite,
          '--output',
          target,
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          jsonDecode(File(target).readAsStringSync()),
          jsonDecode(expected),
        );
      }
      expect(
        File('test/fixtures/v1/expected-report.json').readAsStringSync(),
        expected,
      );
    },
  );
  test('missing files and live or download options fail explicitly', () async {
    for (final args in [
      ['validate', '--suite', '${output.path}/absent.json'],
      [
        'report',
        '--suite',
        suite,
        '--output',
        '${output.path}/report.json',
        '--live',
      ],
      ['download', '--suite', suite],
      ['report', '--suite', suite],
    ]) {
      expect((await run(args)).exitCode, isNot(0));
    }
  });
  test(
    'report output cannot overwrite a fixture input or reviewed baseline',
    () async {
      for (final target in [
        suite,
        'test/fixtures/v1/expected-report.json',
        'test/fixtures/v1/requests.jsonl',
      ]) {
        final result = await run([
          'report',
          '--suite',
          suite,
          '--output',
          target,
        ]);
        expect(result.exitCode, isNot(0));
      }
    },
  );
  test('hardlinked output cannot overwrite fixture bytes', () async {
    final scratch = Directory('${output.path}/suite')..createSync();
    for (final file in Directory(
      'test/fixtures/v1',
    ).listSync().whereType<File>()) {
      file.copySync('${scratch.path}/${file.uri.pathSegments.last}');
    }
    final protected = File('${scratch.path}/requests.jsonl');
    final before = protected.readAsBytesSync();
    final alias = '${output.path}/alias.json';
    final link = await Process.run('ln', [protected.path, alias]);
    expect(link.exitCode, 0);
    final result = await run([
      'report',
      '--suite',
      '${scratch.path}/suite.json',
      '--output',
      alias,
    ]);
    expect(result.exitCode, isNot(0));
    expect(protected.readAsBytesSync(), before);
  }, skip: Platform.isWindows ? 'Linux hardlink regression' : false);
}
