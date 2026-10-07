import 'package:edge_one/edge_one.dart';

import 'dataset.dart';
import 'identity.dart';

/// Compares held-out metrics on the same data and deterministic split.
///
/// Tolerances are absolute fractions, not percentages. Coverage drift is
/// two-sided; accuracy loss and accepted error increase are one-sided.
/// Different model hashes are allowed, so an upgrade can be evaluated.
List<String> checkRegression(
  Object? baseline,
  Object? candidate, {
  double maxAccuracyDrop = .01,
  double maxCoverageDrift = .02,
  double maxErrorIncrease = .01,
}) {
  for (final value in [maxAccuracyDrop, maxCoverageDrift, maxErrorIncrease]) {
    if (!value.isFinite || value < 0 || value > 1) {
      throw ArgumentError(
        'regression tolerances must be finite fractions in [0, 1]',
      );
    }
  }
  final before = _report(baseline);
  final after = _report(candidate);
  for (final key in [
    'version',
    'identity_scheme',
    'split_scheme',
    'dataset_sha256',
    'seed',
    'split',
    'target_error',
  ]) {
    if (canonicalJson(before[key]) != canonicalJson(after[key])) {
      throw FormatException('incompatible reports: $key differs');
    }
  }
  if (before['version'] == 2) {
    final associations = <String, Object?>{
      for (final pair in before['provenance']! as List)
        _map(pair)['request_sha256']! as String: _map(
          pair,
        )['comparison_sha256'],
    };
    for (final value in after['provenance']! as List) {
      final pair = _map(value);
      final raw = pair['request_sha256']! as String;
      if (associations.containsKey(raw) &&
          associations[raw] != pair['comparison_sha256']) {
        throw const FormatException(
          'incompatible reports: shared raw request has conflicting comparison identity',
        );
      }
    }
  }
  final beforeQuestions = _map(before['questions']);
  final afterQuestions = _map(after['questions']);
  if (beforeQuestions.length != afterQuestions.length ||
      !beforeQuestions.keys.every(afterQuestions.containsKey)) {
    throw const FormatException('incompatible reports: questions differ');
  }
  final failures = <String>[];
  for (final key in beforeQuestions.keys) {
    final a = _map(beforeQuestions[key]);
    final b = _map(afterQuestions[key]);
    for (final field in ['type', 'fit_count', 'validation_count']) {
      if (a[field] != b[field])
        throw FormatException('incompatible reports: $key $field differs');
    }
    if (_number(a['validation_accuracy']) - _number(b['validation_accuracy']) >
        maxAccuracyDrop + 1e-12) {
      failures.add(
        '$key: validation accuracy fell by more than $maxAccuracyDrop',
      );
    }
    final beforeTargets = _targets(a['targets']);
    final afterTargets = _targets(b['targets']);
    if (beforeTargets.length != afterTargets.length ||
        !beforeTargets.keys.every(afterTargets.containsKey)) {
      throw FormatException('incompatible reports: $key targets differ');
    }
    for (final target in beforeTargets.keys) {
      final old = _map(beforeTargets[target]!['validation']);
      final current = _map(afterTargets[target]!['validation']);
      if ((_number(current['coverage']) - _number(old['coverage'])).abs() >
          maxCoverageDrift + 1e-12) {
        failures.add(
          '$key @ $target: validation coverage drift exceeds $maxCoverageDrift',
        );
      }
      final oldError = old['error_rate'];
      final newError = current['error_rate'];
      if (oldError == null && newError != null) {
        failures.add(
          '$key @ $target: no accepted baseline for error comparison',
        );
      } else if (oldError != null && newError == null) {
        failures.add(
          '$key @ $target: no accepted candidate for error comparison',
        );
      } else if (oldError != null &&
          newError != null &&
          _number(newError) - _number(oldError) > maxErrorIncrease + 1e-12) {
        failures.add(
          '$key @ $target: validation error increase exceeds $maxErrorIncrease',
        );
      }
    }
  }
  return List.unmodifiable(failures);
}

Map<String, Object?> _report(Object? json) {
  final version = _map(json)['version'];
  final report = _map(json, {
    'version',
    'model_sha256',
    'target_error',
    'dataset_sha256',
    'seed',
    'split',
    'questions',
    if (version == 2) ...{'identity_scheme', 'split_scheme', 'provenance'},
  });
  if ((version != 1 && version != 2) || report['seed'] is! int)
    throw const FormatException('invalid report version or seed');
  checkHash(report['model_sha256'], 'model_sha256');
  checkHash(report['dataset_sha256'], 'dataset_sha256');
  final selectedTarget = _fraction(report['target_error']);
  final split = _map(report['split'], {'fitting', 'validation'});
  final fitting = _digests(split['fitting']);
  final validation = _digests(split['validation']);
  if (version == 2) {
    if (report['identity_scheme'] != comparisonIdentityScheme ||
        report['split_scheme'] != comparisonSplitScheme) {
      throw const FormatException(
        'unsupported report identity or split scheme',
      );
    }
    final provenance = CalibrationIdentitySidecar.parse({
      'version': 1,
      'identity_scheme': report['identity_scheme'],
      'associations': report['provenance'],
    });
    final members = {...fitting, ...validation};
    if (members.length != provenance.associations.length ||
        !provenance.associations.values.every(members.contains)) {
      throw const FormatException('provenance must cover exactly the split');
    }
    final seed = report['seed']! as int;
    final ranked = members.toList()
      ..sort(
        (a, b) => comparisonSplitRank(
          seed,
          a,
        ).compareTo(comparisonSplitRank(seed, b)),
      );
    final middle = ranked.length ~/ 2;
    if (canonicalJson(split['fitting']) !=
            canonicalJson(ranked.take(middle).toList()) ||
        canonicalJson(split['validation']) !=
            canonicalJson(ranked.skip(middle).toList())) {
      throw const FormatException(
        'split disagrees with declared seed and comparison scheme',
      );
    }
  }
  if (fitting.intersection(validation).isNotEmpty)
    throw const FormatException('report split overlaps');
  final questions = _map(report['questions']);
  if (questions.isEmpty) throw const FormatException('report has no questions');
  for (final entry in questions.entries) {
    final question = _map(entry.value, {
      'type',
      'temperature',
      'fit_count',
      'validation_count',
      'validation_accuracy',
      'fit_nll_before',
      'fit_nll_after',
      'targets',
    });
    final fitCount = _count(question['fit_count'], positive: true);
    final validationCount = _count(
      question['validation_count'],
      positive: true,
    );
    if (fitCount > fitting.length || validationCount > validation.length)
      throw const FormatException('question count exceeds split size');
    final impliedCorrect =
        _fraction(question['validation_accuracy']) * validationCount;
    final totalCorrect = impliedCorrect.round();
    if ((impliedCorrect - totalCorrect).abs() > 1e-9) {
      throw const FormatException(
        'validation accuracy does not describe an integer correct count',
      );
    }
    for (final key in ['fit_nll_before', 'fit_nll_after']) {
      if (_number(question[key]) < 0)
        throw const FormatException('NLL must not be negative');
    }
    final targets = _targets(question['targets']);
    if (!targets.containsKey(selectedTarget)) {
      throw const FormatException(
        'report is missing the selected target_error',
      );
    }
    if (!targets.keys.toSet().containsAll([.01, .05, .1]))
      throw const FormatException('report is missing default targets');
    for (final entry in targets.entries) {
      final target = entry.value;
      QuestionCalibration.fromJson({
        'type': question['type'],
        'temperature': question['temperature'],
        'threshold': target['threshold'],
      });
      final fit = _metrics(target['fitting'], fitCount);
      final heldOut = _metrics(target['validation'], validationCount);
      final acceptedCorrect =
          (heldOut['accepted'] as int) - (heldOut['errors'] as int);
      if (acceptedCorrect > totalCorrect ||
          (heldOut['errors'] as int) > validationCount - totalCorrect) {
        throw const FormatException(
          'accepted validation outcomes exceed total correct/errors',
        );
      }
      if (target['threshold'] == null &&
          (fit['accepted'] != 0 || heldOut['accepted'] != 0)) {
        throw const FormatException('null threshold must reject all samples');
      }
      if (target['threshold'] == 0 &&
          (fit['accepted'] != fitCount ||
              heldOut['accepted'] != validationCount)) {
        throw const FormatException('zero threshold must accept all samples');
      }
      if (target['threshold'] != null && fit['accepted'] == 0)
        throw const FormatException('non-null threshold needs fitting support');
      if (fit['error_rate'] != null &&
          _number(fit['error_rate']) > entry.key + 1e-12) {
        throw const FormatException('fitting error exceeds its target');
      }
    }
  }
  return report;
}

Map<double, Map<String, Object?>> _targets(Object? value) {
  if (value is! List || value.isEmpty)
    throw const FormatException('targets must be a nonempty list');
  final result = <double, Map<String, Object?>>{};
  for (final item in value) {
    final target = _map(item, {
      'target_error',
      'threshold',
      'fitting',
      'validation',
    });
    final rate = _fraction(target['target_error']);
    if (result.containsKey(rate))
      throw const FormatException('duplicate target_error');
    result[rate] = target;
  }
  return result;
}

Map<String, Object?> _metrics(Object? value, int expectedCount) {
  final metrics = _map(value, {
    'count',
    'accepted',
    'errors',
    'coverage',
    'error_rate',
  });
  final count = _count(metrics['count'], positive: true);
  final accepted = _count(metrics['accepted']);
  final errors = _count(metrics['errors']);
  if (count != expectedCount || accepted > count || errors > accepted)
    throw const FormatException('invalid metric counts');
  if ((_fraction(metrics['coverage']) - accepted / count).abs() > 1e-12)
    throw const FormatException('coverage disagrees with counts');
  if (accepted == 0) {
    if (metrics['error_rate'] != null)
      throw const FormatException('empty acceptance needs null error_rate');
  } else if ((_fraction(metrics['error_rate']) - errors / accepted).abs() >
      1e-12) {
    throw const FormatException('error_rate disagrees with counts');
  }
  return metrics;
}

Set<String> _digests(Object? value) {
  if (value is! List || value.isEmpty)
    throw const FormatException('split must be a nonempty list');
  final result = <String>{};
  for (final digest in value) {
    if (!result.add(checkHash(digest, 'split digest')))
      throw const FormatException('duplicate split digest');
  }
  return result;
}

Map<String, Object?> _map(Object? value, [Set<String>? fields]) {
  if (value is! Map<String, Object?> ||
      (fields != null &&
          (value.length != fields.length ||
              !fields.every(value.containsKey)))) {
    throw const FormatException('invalid report object fields');
  }
  return value;
}

int _count(Object? value, {bool positive = false}) {
  if (value is! int || value < (positive ? 1 : 0))
    throw const FormatException('invalid report count');
  return value;
}

double _number(Object? value) {
  if (value is! num || !value.isFinite)
    throw const FormatException('expected a finite report number');
  return value.toDouble();
}

double _fraction(Object? value) {
  final number = _number(value);
  if (number < 0 || number > 1)
    throw const FormatException('expected report fraction in [0, 1]');
  return number;
}
