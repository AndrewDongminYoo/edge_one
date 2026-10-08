import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  late Directory scratch;
  setUp(() => scratch = Directory.systemTemp.createTempSync('benchmark-cli-'));
  tearDown(() => scratch.deleteSync(recursive: true));
  Future<ProcessResult> run(List<String> args, {bool rawOutput = false}) =>
      Process.run(Platform.resolvedExecutable, [
        '--suppress-analytics',
        'run',
        'bin/edge_one_benchmark.dart',
        ...args,
      ], stdoutEncoding: rawOutput ? null : utf8);
  const suite = 'test/fixtures/v1/suite.json';
  test(
    'validate keeps status output; report emits only exact JSON without changing inputs',
    () async {
      final inputs = {
        for (final file in Directory(
          'test/fixtures/v1',
        ).listSync().whereType<File>())
          file.path: file.readAsStringSync(),
      };
      final expected = inputs['test/fixtures/v1/expected-report.json'];
      final validation = await run(['validate', '--suite', suite]);
      expect(validation.exitCode, 0, reason: '${validation.stderr}');
      expect(validation.stdout, 'Valid synthetic suite: 11 cases, 4 runs.\n');
      expect(validation.stderr, isEmpty);
      for (var i = 0; i < 2; i++) {
        final result = await run(['report', '--suite', suite], rawOutput: true);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout, utf8.encode(expected!));
        expect(result.stderr, isEmpty);
      }
      for (final entry in inputs.entries) {
        expect(File(entry.key).readAsStringSync(), entry.value);
      }
    },
  );
  test('missing inputs and invalid options leave stdout empty', () async {
    for (final file in Directory(
      'test/fixtures/v1',
    ).listSync().whereType<File>()) {
      file.copySync('${scratch.path}/${file.uri.pathSegments.last}');
    }
    File('${scratch.path}/suite.json').writeAsStringSync('{');
    for (final args in [
      ['validate', '--suite', '${scratch.path}/absent.json'],
      ['report', '--suite', '${scratch.path}/absent.json'],
      ['report', '--suite', '${scratch.path}/suite.json'],
      ['report', '--suite', suite, '--live'],
      ['download', '--suite', suite],
      ['report'],
    ]) {
      final result = await run(args);
      expect(result.exitCode, isNot(0));
      expect(result.stdout, isEmpty);
      expect(result.stderr, startsWith('benchmark: '));
    }
  });
  test(
    'legacy output option is rejected without creating a destination',
    () async {
      final target = File('${scratch.path}/report.json');
      final result = await run([
        'report',
        '--suite',
        suite,
        '--output',
        target.path,
      ]);
      expect(result.exitCode, 64);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('output'));
      expect(target.existsSync(), isFalse);
    },
  );
  test(
    'legacy output rejection precedes fixture reads and preserves existing bytes',
    () async {
      final target = File('${scratch.path}/existing.json')
        ..writeAsStringSync('sentinel\n');
      final result = await run([
        'report',
        '--suite',
        '${scratch.path}/absent.json',
        '--output',
        target.path,
      ]);
      expect(result.exitCode, 64);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('output'));
      expect(target.readAsStringSync(), 'sentinel\n');
    },
  );
}
