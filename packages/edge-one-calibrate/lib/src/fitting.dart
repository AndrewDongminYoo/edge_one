import 'dart:math' as math;

import 'package:edge_one/edge_one.dart';

import 'dataset.dart';
import 'identity.dart';

final class DatasetSplit {
  DatasetSplit._(this.fitting, this.validation);
  final List<CalibrationRecord> fitting;
  final List<CalibrationRecord> validation;
}

DatasetSplit splitDataset(CalibrationDataset dataset, {int seed = 0}) {
  if (dataset.records.length < 2)
    throw const FormatException(
      'at least two independent requests are required',
    );
  final ranked = [
    for (final record in dataset.records)
      (comparisonSplitRank(seed, record.splitSha256), record),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final middle = ranked.length ~/ 2;
  return DatasetSplit._(
    List.unmodifiable(ranked.take(middle).map((r) => r.$2)),
    List.unmodifiable(ranked.skip(middle).map((r) => r.$2)),
  );
}

final class CalibrationRun {
  CalibrationRun._(this.profile, this.report);
  final CalibrationProfile profile;
  final Map<String, Object?> report;
}

/// Fits temperature and thresholds using only the fitting half, then evaluates
/// each fixed gate on the held-out validation half.
CalibrationRun fitCalibration(
  CalibrationDataset dataset, {
  int seed = 0,
  double targetError = .05,
}) {
  _rate(targetError);
  final split = splitDataset(dataset, seed: seed);
  final keys = {
    for (final record in dataset.records) ...record.samples.keys,
  }.toList()..sort();
  final targets = {.01, .05, .1, targetError}.toList()..sort();
  final gates = <String, QuestionCalibration>{};
  final questions = <String, Object?>{};
  for (final key in keys) {
    final fitting = [
      for (final record in split.fitting)
        if (record.samples[key] case final sample?) sample,
    ];
    final validation = [
      for (final record in split.validation)
        if (record.samples[key] case final sample?) sample,
    ];
    if (fitting.isEmpty || validation.isEmpty) {
      throw FormatException(
        'question "$key" needs observations in both fitting and validation partitions',
      );
    }
    final temperature = _fitTemperature(fitting);
    final fitPredictions = _predictions(fitting, temperature);
    final validationPredictions = _predictions(validation, temperature);
    final thresholds = {
      for (final target in targets)
        target: selectThreshold(fitPredictions, target),
    };
    gates[key] = QuestionCalibration(
      type: fitting.first.type,
      temperature: temperature,
      threshold: thresholds[targetError],
    );
    questions[key] = {
      'type': fitting.first.type,
      'temperature': temperature,
      'fit_count': fitting.length,
      'validation_count': validation.length,
      'validation_accuracy':
          validation.where((s) => s.correct).length / validation.length,
      'fit_nll_before': _nll(fitting, 1),
      'fit_nll_after': _nll(fitting, temperature),
      'targets': [
        for (final target in targets)
          {
            'target_error': target,
            'threshold': thresholds[target],
            'fitting': _metrics(fitPredictions, thresholds[target]),
            'validation': _metrics(validationPredictions, thresholds[target]),
          },
      ],
    };
  }
  return CalibrationRun._(
    CalibrationProfile(
      modelSha256: dataset.modelSha256,
      targetError: targetError,
      questions: gates,
    ),
    {
      'version': dataset.identitySidecar == null ? 1 : 2,
      if (dataset.identitySidecar != null) ...{
        'identity_scheme': comparisonIdentityScheme,
        'split_scheme': comparisonSplitScheme,
        'provenance': dataset.identitySidecar!.toJson()['associations'],
      },
      'model_sha256': dataset.modelSha256,
      'target_error': targetError,
      'dataset_sha256': dataset.sha256,
      'seed': seed,
      'split': {
        'fitting': [for (final record in split.fitting) record.splitSha256],
        'validation': [
          for (final record in split.validation) record.splitSha256,
        ],
      },
      'questions': questions,
    },
  );
}

final class Prediction {
  Prediction(this.confidence, this.correct) {
    _rate(confidence);
  }
  final double confidence;
  final bool correct;
}

/// Maximizes accepted observations among complete confidence tie groups.
/// Null is the only safe gate when no nonempty prefix meets the target.
double? selectThreshold(List<Prediction> predictions, double targetError) {
  _rate(targetError);
  final sorted = [...predictions]
    ..sort((a, b) => b.confidence.compareTo(a.confidence));
  var errors = 0;
  double? best;
  for (var i = 0; i < sorted.length; i++) {
    if (!sorted[i].correct) errors++;
    if (i + 1 < sorted.length &&
        sorted[i + 1].confidence == sorted[i].confidence)
      continue;
    if (errors / (i + 1) <= targetError + 1e-12) best = sorted[i].confidence;
  }
  return best;
}

List<Prediction> _predictions(
  List<CalibrationSample> samples,
  double temperature,
) => [
  for (final sample in samples)
    Prediction(
      distributionConfidence(
        calibrateProbabilities(sample.probabilities, temperature),
      ),
      sample.correct,
    ),
];

Map<String, Object?> _metrics(List<Prediction> samples, double? threshold) {
  final accepted = [
    if (threshold != null)
      for (final sample in samples)
        if (sample.confidence >= threshold) sample,
  ];
  final errors = accepted.where((s) => !s.correct).length;
  return {
    'count': samples.length,
    'accepted': accepted.length,
    'errors': errors,
    'coverage': accepted.length / samples.length,
    'error_rate': accepted.isEmpty ? null : errors / accepted.length,
  };
}

double _fitTemperature(List<CalibrationSample> samples) {
  // NLL is convex in inverse temperature. Its derivative is monotonic, so
  // bisection covers boundary optima without a stochastic optimizer.
  var low = .05;
  var high = 20.0;
  for (var i = 0; i < 80; i++) {
    final beta = (low + high) / 2;
    var derivative = 0.0;
    for (final sample in samples) {
      final calibrated = calibrateProbabilities(sample.probabilities, 1 / beta);
      for (var j = 0; j < calibrated.length; j++) {
        if (sample.probabilities[j] > 0)
          derivative += calibrated[j] * math.log(sample.probabilities[j]);
      }
      derivative -= math.log(sample.probabilities[sample.labelIndex]);
    }
    if (derivative > 0) {
      high = beta;
    } else {
      low = beta;
    }
  }
  final fitted = 1 / ((low + high) / 2);
  return _nll(samples, fitted) < _nll(samples, 1) ? fitted : 1;
}

double _nll(List<CalibrationSample> samples, double temperature) {
  var loss = 0.0;
  for (final sample in samples) {
    final logs = [
      for (final p in sample.probabilities)
        p == 0 ? double.negativeInfinity : math.log(p),
    ];
    final maximum = logs.reduce(math.max);
    final total = logs.fold<double>(
      0,
      (sum, value) => sum + math.exp((value - maximum) / temperature),
    );
    loss += (maximum - logs[sample.labelIndex]) / temperature + math.log(total);
  }
  return loss / samples.length;
}

void _rate(double value) {
  if (!value.isFinite || value < 0 || value > 1)
    throw ArgumentError('expected a finite rate in [0, 1]');
}
