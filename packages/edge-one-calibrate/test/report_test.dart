import 'package:edge_one_calibrate/edge_one_calibrate.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  Map<String, Object?> report() => fitCalibration(
    CalibrationDataset.parse(jsonl(fixture()), modelSha256: modelHash),
  ).report;

  test(
    'identical metrics pass, including comparison to another model hash',
    () {
      final baseline = report();
      final candidate = copy(baseline)..['model_sha256'] = 'b' * 64;
      expect(checkRegression(baseline, candidate), isEmpty);
    },
  );

  test('accuracy decrease fails the configured absolute tolerance', () {
    final baseline = report();
    final candidate = copy(baseline);
    final question = (candidate['questions'] as Map)['topic'] as Map;
    question['validation_accuracy'] = 0.75;
    expect(
      checkRegression(baseline, candidate, maxAccuracyDrop: .01),
      contains(contains('accuracy')),
    );
  });

  test(
    'automation drift in either direction and accepted error growth fail',
    () {
      final baseline = report();
      final candidate = copy(baseline);
      final question = (candidate['questions'] as Map)['topic'] as Map;
      final target = (question['targets'] as List).first as Map;
      final metrics = target['validation'] as Map;
      metrics['accepted'] = 10;
      metrics['errors'] = 2;
      metrics['coverage'] = 10 / (metrics['count'] as int);
      metrics['error_rate'] = .2;
      final errors = checkRegression(
        baseline,
        candidate,
        maxCoverageDrift: .01,
        maxErrorIncrease: .01,
      );
      expect(errors, contains(contains('coverage')));
      expect(errors, contains(contains('error')));
      expect(
        checkRegression(candidate, baseline, maxCoverageDrift: .01),
        contains(contains('coverage')),
      );
    },
  );

  test('zero accepted samples do not masquerade as perfect error', () {
    final baseline = report();
    final candidate = copy(baseline);
    final question = (candidate['questions'] as Map)['topic'] as Map;
    for (final value in question['targets'] as List) {
      final metrics = (value as Map)['validation'] as Map;
      metrics['accepted'] = 0;
      metrics['errors'] = 0;
      metrics['coverage'] = 0.0;
      metrics['error_rate'] = null;
    }
    expect(
      checkRegression(baseline, candidate),
      contains(contains('coverage')),
    );
    final newlyAccepted = checkRegression(
      candidate,
      baseline,
      maxCoverageDrift: 1,
    );
    expect(newlyAccepted, contains(contains('no accepted baseline')));
  });

  test('losing all accepted samples fails within the coverage allowance', () {
    final baseline = report();
    final question = (baseline['questions'] as Map)['topic'] as Map;
    for (final target in question['targets'] as List) {
      final metrics = (target as Map)['validation'] as Map;
      metrics['accepted'] = 1;
      metrics['errors'] = 0;
      metrics['coverage'] = 1 / (metrics['count'] as int);
      metrics['error_rate'] = 0.0;
    }
    final candidate = copy(baseline);
    final changed = (candidate['questions'] as Map)['topic'] as Map;
    for (final target in changed['targets'] as List) {
      final metrics = (target as Map)['validation'] as Map;
      metrics['accepted'] = 0;
      metrics['coverage'] = 0.0;
      metrics['error_rate'] = null;
    }
    final failures = checkRegression(baseline, candidate);
    expect(failures, hasLength(3));
    expect(failures, everyElement(contains('no accepted candidate')));
    expect(failures, isNot(contains(contains('coverage'))));
  });

  test(
    'unchanged empty accepted sets remain comparable with unknown error',
    () {
      final baseline = report();
      final question = (baseline['questions'] as Map)['topic'] as Map;
      for (final target in question['targets'] as List) {
        final metrics = (target as Map)['validation'] as Map;
        metrics['accepted'] = 0;
        metrics['errors'] = 0;
        metrics['coverage'] = 0.0;
        metrics['error_rate'] = null;
      }
      expect(checkRegression(baseline, copy(baseline)), isEmpty);
    },
  );

  test(
    'incompatible data, split, question or target identity fails closed',
    () {
      final baseline = report();
      for (final mutate in <void Function(Map<String, Object?>)>[
        (j) => j['dataset_sha256'] = 'b' * 64,
        (j) => j['seed'] = 99,
        (j) =>
            (j['split'] as Map)['fitting'] = (j['split'] as Map)['validation'],
        (j) => (j['questions'] as Map).remove('topic'),
        (j) => ((j['questions'] as Map)['topic'] as Map)['type'] = 'score',
        (j) => (((j['questions'] as Map)['topic'] as Map)['targets'] as List)
            .removeLast(),
      ]) {
        final candidate = copy(baseline);
        mutate(candidate);
        expect(
          () => checkRegression(baseline, candidate),
          throwsFormatException,
        );
      }
    },
  );

  test('malformed metrics, reports and tolerance values fail closed', () {
    final baseline = report();
    for (final mutate in <void Function(Map<String, Object?>)>[
      (j) => j['questions'] = {},
      (j) => j['version'] = 3,
      (j) => j['model_sha256'] = 'not a hash',
      (j) => ((j['questions'] as Map)['topic'] as Map)['validation_accuracy'] =
          double.nan,
      (j) => ((j['questions'] as Map)['topic'] as Map)['validation_count'] = 0,
      (j) =>
          (((((j['questions'] as Map)['topic'] as Map)['targets'] as List).first
                      as Map)['validation']
                  as Map)['coverage'] =
              0.123,
      (j) =>
          (((((j['questions'] as Map)['topic'] as Map)['targets'] as List).first
                      as Map)['validation']
                  as Map)['error_rate'] =
              null,
    ]) {
      final candidate = copy(baseline);
      mutate(candidate);
      expect(() => checkRegression(baseline, candidate), throwsFormatException);
    }
    expect(
      () => checkRegression(baseline, baseline, maxAccuracyDrop: -1),
      throwsArgumentError,
    );
    expect(
      () => checkRegression(baseline, baseline, maxCoverageDrift: double.nan),
      throwsArgumentError,
    );
  });

  test('impossible validation accuracy and accepted subsets are rejected', () {
    final baseline = report();
    for (final mutate in <void Function(Map<String, Object?>)>[
      (question) => question['validation_accuracy'] = .999999,
      (question) => question['validation_accuracy'] = .5,
      (question) {
        final target = (question['targets'] as List).first as Map;
        final metrics = target['validation'] as Map;
        metrics['errors'] = 11;
        metrics['error_rate'] = 11 / (metrics['accepted'] as int);
      },
    ]) {
      final candidate = copy(baseline);
      mutate((candidate['questions'] as Map)['topic'] as Map<String, Object?>);
      expect(() => checkRegression(baseline, candidate), throwsFormatException);
    }
  });

  test('zero threshold requires full fitting and validation acceptance', () {
    final baseline = report();
    final candidate = copy(baseline);
    for (final target
        in ((candidate['questions'] as Map)['topic'] as Map)['targets']
            as List) {
      (target as Map)['threshold'] = 0;
    }
    expect(() => checkRegression(baseline, candidate), throwsFormatException);
  });

  test(
    'selected deployment target changes fail even with the same report rows',
    () {
      final rows = [for (var i = 0; i < 120; i++) record(i)];
      CalibrationDataset parse() =>
          CalibrationDataset.parse(jsonl(rows), modelSha256: modelHash);
      final errors = splitDataset(
        parse(),
      ).fitting.take(3).map((r) => r.requestSha256).toSet();
      for (final row in rows) {
        if (errors.contains(row['request_sha256'])) {
          row['labels'] = {'topic': 'b', 'flag': false, 'level': 'low'};
        }
      }
      final baseline = fitCalibration(parse(), targetError: .01);
      final candidate = fitCalibration(parse(), targetError: .1);
      expect(baseline.profile.questions['topic']!.threshold, isNull);
      expect(candidate.profile.questions['topic']!.threshold, isNotNull);
      expect(
        () => checkRegression(baseline.report, candidate.report),
        throwsFormatException,
      );
    },
  );
}
