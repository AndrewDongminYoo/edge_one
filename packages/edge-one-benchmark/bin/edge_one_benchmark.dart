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
    final args = parser.parse(arguments.skip(1));
    if (args.rest.isNotEmpty)
      throw const FormatException('unexpected positional arguments');
    if (!args.wasParsed('suite'))
      throw const FormatException('missing --suite');
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
    final report = benchmarkReport(bundle, await replayBenchmark(bundle));
    final serialized =
        '${const JsonEncoder.withIndent('  ').convert(report)}\n';
    stdout.add(utf8.encode(serialized));
    await stdout.flush();
  } on FormatException catch (error) {
    stderr.writeln('benchmark: ${error.message}');
    exitCode = 64;
  } on FileSystemException catch (error) {
    stderr.writeln('benchmark: ${error.message}: ${error.path}');
    exitCode = 66;
  }
}
