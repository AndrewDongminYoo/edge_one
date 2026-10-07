import 'package:edge_one/edge_one.dart';
import 'package:test/test.dart';

void main() {
  final hash = 'a' * 64;
  Map<String, Object?> artifact() => {
    'version': 1,
    'model_sha256': hash,
    'target_error': 0.05,
    'confidence': 'normalized_max_probability',
    'questions': {
      'topic': {'type': 'choice', 'temperature': 2, 'threshold': 0.8},
    },
  };

  test('artifact round trips and only returns thresholds for its model', () {
    final profile = CalibrationProfile.fromJson(artifact());
    expect(profile.toJson(), artifact());
    expect(profile.forQuestion('topic', modelSha256: hash)!.temperature, 2);
    expect(profile.forQuestion('topic', modelSha256: 'b' * 64), isNull);
    expect(profile.forQuestion('missing', modelSha256: hash), isNull);
  });

  test('threshold equality accepts and null rejects confidence one', () {
    final gate = QuestionCalibration(
      type: 'choice',
      temperature: 1,
      threshold: 0.8,
    );
    expect(gate.accepts(0.8), isTrue);
    expect(gate.accepts(0.799), isFalse);
    expect(
      QuestionCalibration(
        type: 'noul',
        temperature: 1,
        threshold: null,
      ).accepts(1),
      isFalse,
    );
    expect(() => gate.accepts(double.nan), throwsArgumentError);
  });

  test('strict artifact validation rejects malformed fields', () {
    for (final mutation in <void Function(Map<String, Object?>)>[
      (j) => j['version'] = 2,
      (j) => j['model_sha256'] = 'bad',
      (j) => j['model_sha256'] = '$hash\n',
      (j) => j['target_error'] = double.nan,
      (j) => j['target_error'] = -0.1,
      (j) => j['confidence'] = 'wire',
      (j) => j['extra'] = true,
      (j) => j.remove('confidence'),
      (j) => j['questions'] = {},
      for (final field in ['type', 'temperature', 'threshold'])
        (j) => ((j['questions'] as Map)['topic'] as Map).remove(field),
      for (final value in [0, -1, double.infinity, double.nan, '1'])
        (j) => ((j['questions'] as Map)['topic'] as Map)['temperature'] = value,
      for (final value in [-1, 1.1, double.nan, '0.8'])
        (j) => ((j['questions'] as Map)['topic'] as Map)['threshold'] = value,
      (j) => ((j['questions'] as Map)['topic'] as Map)['type'] = 'unknown',
      (j) => ((j['questions'] as Map)['topic'] as Map)['extra'] = 0,
    ]) {
      final json = artifact();
      mutation(json);
      expect(() => CalibrationProfile.fromJson(json), throwsFormatException);
    }
  });

  test(
    'relative temperature scales probabilities and preserves zero support',
    () {
      expect(calibrateProbabilities([0.8, 0.2], 2), closeList([2 / 3, 1 / 3]));
      expect(calibrateProbabilities([0, 1], 20), [0, 1]);
      expect(
        calibrateProbabilities([0.4, 0.4, 0.2], 1),
        closeList([0.4, 0.4, 0.2]),
      );
      expect(distributionConfidence([0.5, 0.5]), 0);
      expect(distributionConfidence([0.8, 0.2]), closeTo(0.6, 1e-12));
      expect(distributionConfidence([1]), 1);
    },
  );

  test('invalid distributions and temperatures fail explicitly', () {
    for (final values in <List<num>>[
      [],
      [0, 0],
      [-1, 2],
      [double.nan, 1],
      [0.2, 0.2],
    ]) {
      expect(() => calibrateProbabilities(values, 1), throwsArgumentError);
      expect(() => distributionConfidence(values), throwsArgumentError);
    }
    for (final t in [0.0, -1.0, double.infinity, double.nan]) {
      expect(() => calibrateProbabilities([0.8, 0.2], t), throwsArgumentError);
    }
  });
}

Matcher closeList(List<double> values) =>
    orderedEquals([for (final value in values) closeTo(value, 1e-12)]);
