import 'package:edge_one_calibrate/edge_one_calibrate.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  CalibrationDataset dataset(List<Map<String, Object?>> rows) =>
      CalibrationDataset.parse(jsonl(rows), modelSha256: modelHash);

  test(
    'split is deterministic, balanced, disjoint and independent of line order',
    () {
      final rows = fixture();
      final a = splitDataset(dataset(rows), seed: 42);
      final b = splitDataset(dataset(rows.reversed.toList()), seed: 42);
      final fit = a.fitting.map((r) => r.requestSha256).toSet();
      final validation = a.validation.map((r) => r.requestSha256).toSet();
      expect(fit.length, 60);
      expect(validation.length, 60);
      expect(fit.intersection(validation), isEmpty);
      expect(fit.union(validation).length, rows.length);
      expect(
        a.fitting.map((r) => r.requestSha256),
        b.fitting.map((r) => r.requestSha256),
      );
      expect(a.fitting.every((r) => r.samples.length == 3), isTrue);
      expect(
        fitCalibration(dataset(rows), seed: 42).report,
        fitCalibration(dataset(rows.reversed.toList()), seed: 42).report,
      );
    },
  );

  test('validation labels cannot affect fitted temperatures or thresholds', () {
    final rows = fixture();
    final original = fitCalibration(dataset(rows));
    final split = splitDataset(dataset(rows));
    final validation = split.validation.map((r) => r.requestSha256).toSet();
    for (final row in rows) {
      if (validation.contains(row['request_sha256'])) {
        row['labels'] = {'topic': 'b', 'flag': false, 'level': 'low'};
      }
    }
    final changed = fitCalibration(dataset(rows));
    expect(changed.profile.toJson(), original.profile.toJson());
    expect(changed.report, isNot(original.report));
  });

  test('temperature fitting reduces NLL using fitting records only', () {
    final rows = [
      for (var i = 0; i < 80; i++) record(i, p: .9, correct: i % 4 != 0),
    ];
    final result = fitCalibration(dataset(rows));
    final topic = (result.report['questions'] as Map)['topic'] as Map;
    expect(topic['fit_nll_after'], lessThan(topic['fit_nll_before'] as num));
    expect(result.profile.questions['topic']!.temperature, greaterThan(1));
    expect((topic['targets'] as List).map((v) => (v as Map)['target_error']), [
      .01,
      .05,
      .1,
    ]);
  });

  test('threshold never accepts only part of a confidence tie', () {
    expect(
      selectThreshold([
        Prediction(.9, true),
        Prediction(.9, false),
        Prediction(.8, true),
      ], .1),
      isNull,
    );
    expect(
      selectThreshold([
        Prediction(.9, true),
        Prediction(.8, true),
        Prediction(.8, false),
      ], .1),
      .9,
    );
    expect(selectThreshold([Prediction(1, false)], .1), isNull);
    expect(selectThreshold([Prediction(.5, true)], .01), .5);
  });

  test(
    'threshold search can recover after an invalid higher-confidence prefix',
    () {
      expect(
        selectThreshold([
          Prediction(.99, false),
          for (var i = 0; i < 19; i++) Prediction(.8, true),
        ], .05),
        .8,
      );
    },
  );

  test(
    'duplicate original digest and canonical duplicate requests are rejected',
    () {
      final a = record(1);
      expect(() => dataset([a, a]), throwsFormatException);
      final duplicate = record(2)..['request'] = a['request'];
      expect(() => dataset([a, duplicate]), throwsFormatException);
      final redactedA = record(1);
      final redactedB = record(2);
      (redactedA['request'] as Map)['state'] = '[redacted]';
      (redactedB['request'] as Map)['state'] = '[redacted]';
      expect(dataset([redactedA, redactedB]).records.length, 2);
    },
  );

  test(
    'invalid cache, labels, hash and drifting question definitions are rejected',
    () {
      for (final mutate in <void Function(Map<String, Object?>)>[
        (j) => j['model_sha256'] = 'b' * 64,
        (j) => j['request_sha256'] = 'invalid',
        (j) => j['version'] = 2,
        (j) => j['extra'] = 1,
        (j) => j['labels'] = {},
        (j) => (j['labels'] as Map)['flag'] = 'true',
        (j) => (j['labels'] as Map)['topic'] = 'absent',
        (j) => (j['labels'] as Map)['level'] = 1,
        (j) => (j['response'] as Map)['answers'] = {},
        (j) => (j['response'] as Map)['model'] = 'other',
        (j) =>
            (((j['request'] as Map)['questions'] as Map)['topic']
                    as Map)['instructions'] =
                'Changed',
        (j) =>
            (((j['response'] as Map)['answers'] as Map)['topic']
                    as Map)['choice'] =
                'b',
      ]) {
        final row = record(2);
        mutate(row);
        expect(() => dataset([record(1), row]), throwsFormatException);
      }
      expect(() => dataset([]), throwsFormatException);
      expect(() => fitCalibration(dataset([record(1)])), throwsFormatException);
      expect(
        () => dataset([record(1, p: 1, correct: false)]),
        throwsFormatException,
      );
    },
  );

  test('each question must have observations in both partitions', () {
    final rows = [record(1), record(2)];
    (rows.last['request'] as Map)['questions'] = {
      'topic': ((rows.last['request'] as Map)['questions'] as Map)['topic'],
    };
    (rows.last['response'] as Map)['answers'] = {
      'topic': ((rows.last['response'] as Map)['answers'] as Map)['topic'],
    };
    rows.last['labels'] = {'topic': 'a'};
    expect(() => fitCalibration(dataset(rows)), throwsFormatException);
  });

  test('Score legend keys and meanings cannot change within a dataset', () {
    for (final legend in [
      {'low': 'high', 'high': 'low'},
      {'low': 'low', 'high': 'changed'},
    ]) {
      final rows = [record(1), record(2)];
      (((rows.last['response'] as Map)['answers'] as Map)['level']
              as Map)['legend'] =
          legend;
      expect(() => dataset(rows), throwsFormatException);
    }
  });

  test('Score legend semantic changes invalidate cross-report comparison', () {
    final original = fitCalibration(dataset(fixture()));
    final changed = fixture();
    for (final row in changed) {
      (((row['response'] as Map)['answers'] as Map)['level'] as Map)['legend'] =
          {'low': 'high', 'high': 'low'};
    }
    final changedRun = fitCalibration(dataset(changed));
    expect(
      changedRun.report['dataset_sha256'],
      isNot(original.report['dataset_sha256']),
    );
    expect(
      () => checkRegression(original.report, changedRun.report),
      throwsFormatException,
    );
  });
}
