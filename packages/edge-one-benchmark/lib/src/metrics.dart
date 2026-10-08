import 'dart:math' as math;
import 'package:edge_one/edge_one.dart';

/// A categorical view of a raw answer; zero probability at truth is valid.
final class CategoricalObservation {
  CategoricalObservation._(
    this.probabilities,
    this.gateProbabilities,
    this.truth,
    this.predicted,
  );
  factory CategoricalObservation.fromAnswer(
    SystemOneAnswer answer,
    Object? label,
  ) {
    final gateProbabilities = switch (answer) {
      NoulAnswer(:final noul) => [1 - noul.toDouble(), noul.toDouble()],
      ChoiceAnswer(:final probabilities) =>
        probabilities.values.map((p) => p.toDouble()).toList(),
      ScoreAnswer(:final probabilities) =>
        probabilities.values.map((p) => p.toDouble()).toList(),
    };
    final List<double> probabilities;
    final int truth, predicted;
    switch (answer) {
      case NoulAnswer(:final noul):
        probabilities = [1 - noul.toDouble(), noul.toDouble()];
        truth = label is bool ? (label ? 1 : 0) : -1;
        predicted = noul >= .5 ? 1 : 0;
      case ChoiceAnswer():
        final keys = answer.probabilities.keys.toList()..sort();
        probabilities = [
          for (final key in keys) answer.probabilities[key]!.toDouble(),
        ];
        truth = label is String ? keys.indexOf(label) : -1;
        predicted = keys.indexOf(answer.choice);
        if (predicted < 0 ||
            probabilities.any((p) => p > probabilities[predicted])) {
          throw const FormatException('choice must have maximum probability');
        }
      case ScoreAnswer():
        final keys = answer.probabilities.keys.toList()..sort();
        if (keys.length != answer.legend.length ||
            !keys.every(answer.legend.containsKey)) {
          throw const FormatException('score legend must match probabilities');
        }
        probabilities = [
          for (final key in keys) answer.probabilities[key]!.toDouble(),
        ];
        truth = label is String ? keys.indexOf(label) : -1;
        predicted = probabilities.indexOf(probabilities.reduce(math.max));
    }
    if (truth < 0) throw const FormatException('label missing from answer');
    distributionConfidence(
      probabilities,
    ); // validates range and codec sum tolerance
    final total = probabilities.reduce((a, b) => a + b);
    return CategoricalObservation._(
      List.unmodifiable(
        (total - 1).abs() <= 1e-12
            ? probabilities
            : probabilities.map((p) => p / total),
      ),
      List.unmodifiable(gateProbabilities),
      truth,
      predicted,
    );
  }
  final List<double> probabilities;
  final List<double> gateProbabilities;
  final int truth, predicted;
  bool get correct => truth == predicted;
  double get confidence => probabilities.reduce(math.max);
  double get brier => [
    for (var i = 0; i < probabilities.length; i++)
      math.pow(probabilities[i] - (i == truth ? 1 : 0), 2),
  ].fold(0.0, (a, b) => a + b);
}

Map<String, Object?> categoricalMetrics(List<CategoricalObservation> samples) {
  final bins = List.generate(10, (_) => <CategoricalObservation>[]);
  for (final sample in samples) {
    bins[math.min(9, (sample.confidence * 10).floor())].add(sample);
  }
  final n = samples.length;
  double? average(Iterable<double> values) =>
      n == 0 ? null : values.fold(0.0, (a, b) => a + b) / n;
  return {
    'answered': n,
    'correct': samples.where((s) => s.correct).length,
    'accuracy': n == 0 ? null : samples.where((s) => s.correct).length / n,
    'ece10': n == 0
        ? null
        : bins.fold(
                0.0,
                (sum, bin) =>
                    sum +
                    (bin.where((s) => s.correct).length -
                            bin.fold(0.0, (a, s) => a + s.confidence))
                        .abs(),
              ) /
              n,
    'brier': average(samples.map((s) => s.brier)),
    'mean_max_probability': average(samples.map((s) => s.confidence)),
    'mean_routing_confidence': average(
      samples.map((s) => distributionConfidence(s.probabilities)),
    ),
    'bins': [
      for (var i = 0; i < 10; i++)
        {
          'index': i,
          'count': bins[i].length,
          'accuracy': bins[i].isEmpty
              ? null
              : bins[i].where((s) => s.correct).length / bins[i].length,
          'mean_confidence': bins[i].isEmpty
              ? null
              : bins[i].fold(0.0, (a, s) => a + s.confidence) / bins[i].length,
        },
    ],
  };
}

Map<String, Object?> gateMetrics(
  List<CategoricalObservation> samples, {
  required int attempted,
  required QuestionCalibration gate,
  required double targetError,
}) {
  if (attempted < samples.length)
    throw ArgumentError('attempted is less than answered');
  final accepted = samples
      .where(
        (s) => gate.accepts(
          distributionConfidence(
            calibrateProbabilities(s.gateProbabilities, gate.temperature),
          ),
        ),
      )
      .toList();
  final errors = accepted.where((s) => !s.correct).length;
  return {
    'target_error': targetError,
    'temperature': gate.temperature,
    'threshold': gate.threshold,
    'accepted': accepted.length,
    'accepted_errors': errors,
    'coverage': attempted == 0 ? null : accepted.length / attempted,
    'observed_error': accepted.isEmpty ? null : errors / accepted.length,
    'exceeds_target': accepted.isEmpty
        ? null
        : errors / accepted.length > targetError,
  };
}

Map<String, Object?> latencyMetrics(List<int?> samples) {
  final measured = samples.whereType<int>().toList()..sort();
  if (measured.any((value) => value < 0))
    throw ArgumentError('negative duration');
  int? rank(double q) =>
      measured.isEmpty ? null : measured[(q * measured.length).ceil() - 1];
  return {
    'samples': measured.length,
    'unmeasured': samples.length - measured.length,
    'p50_us': rank(.5),
    'p95_us': rank(.95),
  };
}
