import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart' show RecordingBackend;
import 'package:edge_one_calibrate/edge_one_calibrate.dart';
import 'package:edge_one_calibrate/src/output_pair.dart';

void main(List<String> arguments) {
  final parser = ArgParser()..addFlag('help', abbr: 'h', negatable: false);
  final fit = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addOption('input', help: 'Labeled cached System One JSONL.')
    ..addFlag(
      'redacted-requests',
      negatable: false,
      help:
          'Treat the whole input as redacted; use trusted original request_sha256 values. '
          'Producers must deduplicate requests before redaction.',
    )
    ..addOption(
      'identity-sidecar',
      help: 'Versioned comparison identity sidecar JSON.',
    )
    ..addOption(
      'original-requests',
      help: 'Local JSON array of original requests; never persisted.',
    )
    ..addFlag(
      'trust-identity-sidecar',
      negatable: false,
      help: 'Explicitly trust producer digests for hidden originals.',
    )
    ..addOption('model-sha256', help: 'Expected lowercase model SHA-256.')
    ..addOption('output', defaultsTo: 'thresholds.json')
    ..addOption('report', defaultsTo: 'calibration-report.json')
    ..addOption('seed', defaultsTo: '0')
    ..addOption('target-error', defaultsTo: '0.05');
  final check = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addOption('baseline')
    ..addOption('report')
    ..addOption('max-accuracy-drop', defaultsTo: '0.01')
    ..addOption('max-coverage-drift', defaultsTo: '0.02')
    ..addOption('max-error-increase', defaultsTo: '0.01');
  parser.addCommand('fit', fit);
  parser.addCommand('check', check);
  try {
    final args = parser.parse(arguments);
    final command = args.command;
    if (args.flag('help') || (command?.flag('help') ?? false)) {
      stdout.writeln(
        'Offline calibration: edge-one-calibrate <fit|check> [options]',
      );
      stdout.writeln(
        command == null
            ? parser.usage
            : command.name == 'fit'
            ? fit.usage
            : check.usage,
      );
      return;
    }
    if (args.rest.isNotEmpty || command == null || command.rest.isNotEmpty) {
      throw ArgumentError('use fit or check; see --help');
    }
    if (command.name == 'fit') {
      final input = _required(command, 'input');
      final hash = _required(command, 'model-sha256');
      final output = _required(command, 'output');
      final report = _required(command, 'report');
      final seed = int.tryParse(_required(command, 'seed'));
      if (seed == null) throw ArgumentError('--seed must be an integer');
      final target = _rate(command, 'target-error');
      final sidecarPath = command.option('identity-sidecar');
      final originalsPath = command.option('original-requests');
      final allPaths = [input, output, report, ?sidecarPath, ?originalsPath];
      if (allPaths.map(_canonicalPath).toSet().length != allPaths.length) {
        throw ArgumentError(
          'input, sidecar, originals, output and report paths must differ',
        );
      }
      final sidecar = sidecarPath == null
          ? null
          : CalibrationIdentitySidecar.parse(
              jsonDecode(File(sidecarPath).readAsStringSync()),
            );
      Map<String, SystemOneRequest>? originals;
      if (originalsPath != null) {
        final values = jsonDecode(File(originalsPath).readAsStringSync());
        if (values is! List)
          throw const FormatException('original requests must be a JSON array');
        originals = {};
        for (final value in values) {
          final request = SystemOneJson.decodeRequest(value);
          final digest = RecordingBackend.requestSha256(request);
          if (originals.containsKey(digest))
            throw const FormatException('duplicate original request');
          originals[digest] = request;
        }
      }
      final dataset = CalibrationDataset.parse(
        File(input).readAsStringSync(),
        modelSha256: hash,
        redactedRequests: command.flag('redacted-requests'),
        identitySidecar: sidecar,
        originalRequests: originals,
        trustIdentitySidecar: command.flag('trust-identity-sidecar'),
      );
      final result = fitCalibration(dataset, seed: seed, targetError: target);
      final warnings = writeCalibrationOutputs(
        artifactPath: output,
        artifact: result.profile.toJson(),
        reportPath: report,
        report: result.report,
      );
      for (final warning in warnings) {
        stderr.writeln('Warning: $warning');
      }
      stdout.writeln(
        'Wrote $output and $report. Held-out validation coverage:',
      );
      final questions = result.report['questions'] as Map;
      for (final key in questions.keys) {
        for (final target in (questions[key] as Map)['targets'] as List) {
          final metrics = (target as Map)['validation'] as Map;
          final error = metrics['error_rate'];
          stdout.writeln(
            '$key @ ${((target['target_error'] as num) * 100).toStringAsFixed(0)}% target: '
            '${((metrics['coverage'] as num) * 100).toStringAsFixed(1)}% coverage; '
            '${error == null ? 'n/a' : '${((error as num) * 100).toStringAsFixed(1)}%'} error '
            '(${metrics['accepted']}/${metrics['count']} accepted)',
          );
        }
      }
    } else {
      final accuracy = _rate(command, 'max-accuracy-drop');
      final coverage = _rate(command, 'max-coverage-drift');
      final error = _rate(command, 'max-error-increase');
      final baseline = jsonDecode(
        File(_required(command, 'baseline')).readAsStringSync(),
      );
      final candidate = jsonDecode(
        File(_required(command, 'report')).readAsStringSync(),
      );
      final failures = checkRegression(
        baseline,
        candidate,
        maxAccuracyDrop: accuracy,
        maxCoverageDrift: coverage,
        maxErrorIncrease: error,
      );
      if (failures.isEmpty) {
        stdout.writeln('Calibration regression gate passed.');
      } else {
        stderr.writeln(failures.join('\n'));
        exitCode = 1;
      }
    }
  } on ArgParserException catch (error) {
    stderr.writeln('Usage: ${error.message}');
    exitCode = 64;
  } on ArgumentError catch (error) {
    stderr.writeln('Usage: ${error.message}');
    exitCode = 64;
  } on FormatException catch (error) {
    stderr.writeln('Invalid calibration data: ${error.message}');
    exitCode = 65;
  } on FileSystemException catch (error) {
    stderr.writeln('File error: ${error.message}: ${error.path}');
    exitCode = 74;
  }
}

String _required(ArgResults args, String name) {
  final value = args.option(name);
  if (value == null || value.isEmpty)
    throw ArgumentError('--$name is required');
  return value;
}

double _rate(ArgResults args, String name) {
  final value = double.tryParse(_required(args, name));
  if (value == null || !value.isFinite || value < 0 || value > 1)
    throw ArgumentError('--$name must be a finite fraction in [0, 1]');
  return value;
}

String _canonicalPath(String path) {
  final file = File(path).absolute;
  if (file.existsSync()) return file.resolveSymbolicLinksSync();
  final parent = file.parent;
  if (parent.existsSync())
    return '${parent.resolveSymbolicLinksSync()}/${file.uri.pathSegments.last}';
  return file.uri.normalizePath().toFilePath();
}
