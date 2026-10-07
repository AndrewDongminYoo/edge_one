import 'dart:math' as math;

import 'contract_json.dart';

/// A model-bound version 1 offline calibration artifact.
///
/// A temperature is relative to the probabilities supplied by the backend,
/// including any temperature already applied by that backend.
final class CalibrationProfile {
  CalibrationProfile({
    required this.modelSha256,
    required this.targetError,
    required Map<String, QuestionCalibration> questions,
  }) : questions = Map.unmodifiable(questions) {
    if (modelSha256.length != 64 || !_hash.hasMatch(modelSha256)) {
      throw ArgumentError.value(modelSha256, 'modelSha256');
    }
    _probability(targetError, 'targetError');
    if (questions.isEmpty) throw ArgumentError('questions must not be empty');
  }

  factory CalibrationProfile.fromJson(Object? json) {
    try {
      final map = _object(json, {
        'version',
        'model_sha256',
        'target_error',
        'confidence',
        'questions',
      });
      if (map['version'] != 1 ||
          map['confidence'] != 'normalized_max_probability') {
        throw const FormatException('unsupported calibration format');
      }
      final hash = map['model_sha256'];
      final questions = map['questions'];
      if (hash is! String || questions is! Map<String, Object?>) {
        throw const FormatException('invalid model_sha256 or questions');
      }
      return CalibrationProfile(
        modelSha256: hash,
        targetError: _number(map['target_error']),
        questions: {
          for (final entry in questions.entries)
            entry.key: QuestionCalibration.fromJson(entry.value),
        },
      );
    } on ArgumentError catch (error) {
      throw FormatException('invalid calibration: ${error.message}');
    }
  }

  final String modelSha256;
  final double targetError;
  final Map<String, QuestionCalibration> questions;

  /// Returns no calibration if the model differs or the question is unknown.
  ///
  /// Callers choose their conservative fallback and warning policy. Never reuse
  /// [questions] directly for a different model.
  QuestionCalibration? forQuestion(String key, {required String modelSha256}) =>
      modelSha256 == this.modelSha256 ? questions[key] : null;

  Map<String, Object?> toJson() => {
    'version': 1,
    'model_sha256': modelSha256,
    'target_error': targetError,
    'confidence': 'normalized_max_probability',
    'questions': {
      for (final entry in questions.entries) entry.key: entry.value.toJson(),
    },
  };
}

/// A confidence gate for one stable question definition.
final class QuestionCalibration {
  QuestionCalibration({
    required this.type,
    required this.temperature,
    required this.threshold,
  }) {
    if (!const {'choice', 'noul', 'score'}.contains(type)) {
      throw ArgumentError.value(type, 'type');
    }
    _temperature(temperature);
    if (threshold != null) _probability(threshold!, 'threshold');
  }

  factory QuestionCalibration.fromJson(Object? json) {
    try {
      final map = _object(json, {'type', 'temperature', 'threshold'});
      final type = map['type'];
      if (type is! String) throw const FormatException('type must be a string');
      return QuestionCalibration(
        type: type,
        temperature: _number(map['temperature']),
        threshold: map['threshold'] == null ? null : _number(map['threshold']),
      );
    } on ArgumentError catch (error) {
      throw FormatException('invalid question calibration: ${error.message}');
    }
  }

  final String type;
  final double temperature;

  /// Inclusive acceptance threshold; null rejects every answer, even certainty.
  final double? threshold;

  bool accepts(double confidence) {
    _probability(confidence, 'confidence');
    return threshold != null && confidence >= threshold!;
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'temperature': temperature,
    'threshold': threshold,
  };
}

/// Applies `softmax(log(p) / temperature)` while preserving exact zero support.
///
/// Rounded System One probability totals within the wire codec's tolerance are
/// normalized. Values must be finite probabilities with a nonzero total.
List<double> calibrateProbabilities(
  Iterable<num> probabilities,
  double temperature,
) {
  _temperature(temperature);
  final values = _distribution(probabilities);
  final maximum = values.reduce(math.max);
  final logMaximum = math.log(maximum);
  final weights = [
    for (final p in values)
      p == 0 ? 0.0 : math.exp((math.log(p) - logMaximum) / temperature),
  ];
  final total = weights.reduce((a, b) => a + b);
  return List.unmodifiable([for (final weight in weights) weight / total]);
}

/// Normalized maximum probability for routing, after temperature scaling.
///
/// Noul callers supply `[1 - noul, noul]`; this is routing confidence, not an
/// additional field in the Noul wire answer. A one-category distribution is 1.
double distributionConfidence(Iterable<num> probabilities) {
  final values = _distribution(probabilities);
  if (values.length == 1) return 1;
  final total = values.reduce((a, b) => a + b);
  return ((values.length * values.reduce(math.max) / total - 1) /
          (values.length - 1))
      .clamp(0.0, 1.0);
}

final _hash = RegExp(r'^[0-9a-f]{64}$');

Map<String, Object?> _object(Object? value, Set<String> fields) {
  if (value is! Map<String, Object?> ||
      value.length != fields.length ||
      !fields.every(value.containsKey)) {
    throw FormatException('expected exactly ${fields.join(', ')}');
  }
  return value;
}

double _number(Object? value) {
  if (value is! num || !value.isFinite) {
    throw const FormatException('expected a finite number');
  }
  return value.toDouble();
}

void _temperature(double value) {
  if (!value.isFinite || value <= 0) {
    throw ArgumentError.value(
      value,
      'temperature',
      'must be finite and positive',
    );
  }
}

void _probability(double value, String name) {
  if (!value.isFinite || value < 0 || value > 1) {
    throw ArgumentError.value(value, name, 'must be finite and in [0, 1]');
  }
}

List<double> _distribution(Iterable<num> probabilities) {
  final values = probabilities.map((p) => p.toDouble()).toList();
  if (values.isEmpty) throw ArgumentError('probabilities must not be empty');
  for (final p in values) {
    _probability(p, 'probability');
  }
  final total = values.reduce((a, b) => a + b);
  if (total <= 0 ||
      (total - 1).abs() > SystemOneJson.probabilitySumTolerance + 1e-12) {
    throw ArgumentError('probabilities must sum to one');
  }
  return values;
}
