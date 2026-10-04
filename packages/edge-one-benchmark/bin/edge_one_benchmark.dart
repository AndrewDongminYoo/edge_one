import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:edge_one_benchmark/edge_one_benchmark.dart';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.isEmpty || !{'validate', 'report'}.contains(arguments.first))
      throw const FormatException('use validate or report');
    final command = arguments.first;
    final parser = ArgParser()..addOption('suite', mandatory: true);
    if (command == 'report') parser.addOption('output', mandatory: true);
    final args = parser.parse(arguments.skip(1));
    if (args.rest.isNotEmpty)
      throw const FormatException('unexpected positional arguments');
    final suite = File(args['suite'] as String);
    final files = {
      'suite.json': suite.readAsStringSync(),
      for (final name in fixtureFiles)
        name: File('${suite.parent.path}/$name').readAsStringSync(),
    };
    final bundle = parseBenchmarkBundle(files);
    if (command == 'validate') {
      stdout.writeln(
        'Valid synthetic suite: ${bundle.cases.length} cases, ${bundle.runs.length} runs.',
      );
      return;
    }
    final output = File(args['output'] as String);
    String resolved(File file) => file.existsSync()
        ? file.resolveSymbolicLinksSync()
        : '${file.parent.resolveSymbolicLinksSync()}/${file.uri.pathSegments.last}';
    final protected = {
      resolved(suite),
      for (final name in {...fixtureFiles, 'expected-report.json'})
        resolved(File('${suite.parent.path}/$name')),
    };
    if (protected.contains(resolved(output)) ||
        (output.existsSync() &&
            protected.any(
              (path) =>
                  File(path).existsSync() &&
                  FileSystemEntity.identicalSync(output.path, path),
            )))
      throw const FormatException(
        'output must not overwrite fixture inputs or reviewed baseline',
      );
    final report = benchmarkReport(bundle, await replayBenchmark(bundle));
    final staging = output.parent.createTempSync('.edge-one-benchmark-');
    try {
      final staged = File('${staging.path}/report.json');
      staged.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
      staged.renameSync(output.path);
    } finally {
      staging.deleteSync(recursive: true);
    }
    stdout.writeln('Wrote synthetic fixture report to ${output.path}.');
  } on FormatException catch (error) {
    stderr.writeln('benchmark: ${error.message}');
    exitCode = 64;
  } on FileSystemException catch (error) {
    stderr.writeln('benchmark: ${error.message}: ${error.path}');
    exitCode = 66;
  }
}
