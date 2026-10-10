import 'dart:convert';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one_calibrate/edge_one_calibrate.dart';
import 'support/bundle.dart';
import 'package:edge_one_benchmark/edge_one_benchmark.dart';
import 'package:test/test.dart';

void main() {
  test(
    'hand checked metrics use maximum probability and both binary classes',
    () {
      final samples = [
        for (final pair in [
          (0.9, true),
          (0.7, false),
          (0.6, true),
          (0.8, true),
        ])
          CategoricalObservation.fromAnswer(NoulAnswer(noul: pair.$1), pair.$2),
      ];
      final result = categoricalMetrics(samples);
      expect(result['accuracy'], .75);
      expect(result['ece10'], closeTo(.35, 1e-12));
      expect(result['brier'], closeTo(.35, 1e-12));
      expect(result['mean_max_probability'], closeTo(.75, 1e-12));
      expect(result['mean_routing_confidence'], closeTo(.5, 1e-12));
    },
  );

  test(
    'multiclass exact bin boundary stays in bin six without log rounding',
    () {
      final result = categoricalMetrics([
        CategoricalObservation.fromAnswer(
          const ChoiceAnswer(
            confidence: .4,
            choice: 'a',
            probabilities: {'a': .6, 'b': .2, 'c': .2},
          ),
          'a',
        ),
        CategoricalObservation.fromAnswer(
          const ChoiceAnswer(
            confidence: .325,
            choice: 'a',
            probabilities: {'a': .55, 'b': .225, 'c': .225},
          ),
          'b',
        ),
      ]);
      expect(result['ece10'], closeTo(.475, 1e-12));
      expect((result['bins'] as List)[6], containsPair('count', 1));
      expect((result['bins'] as List)[5], containsPair('count', 1));
    },
  );
  test(
    'floating summation noise preserves raw boundaries but rounded totals normalize',
    () {
      final result = categoricalMetrics([
        CategoricalObservation.fromAnswer(
          const ChoiceAnswer(
            confidence: .75,
            choice: 'a',
            probabilities: {'a': .8, 'b': .05, 'c': .05, 'd': .05, 'e': .05},
          ),
          'a',
        ),
        CategoricalObservation.fromAnswer(
          const ChoiceAnswer(
            confidence: .6875,
            choice: 'a',
            probabilities: {
              'a': .75,
              'b': .0625,
              'c': .0625,
              'd': .0625,
              'e': .0625,
            },
          ),
          'b',
        ),
      ]);
      expect(result['ece10'], closeTo(.475, 1e-12));
      expect((result['bins'] as List)[8], containsPair('count', 1));
      final rounded = CategoricalObservation.fromAnswer(
        const ChoiceAnswer(
          confidence: .2,
          choice: 'a',
          probabilities: {'a': .6, 'b': .39},
        ),
        'a',
      );
      expect(rounded.confidence, closeTo(.6 / .99, 1e-12));
      final below = CategoricalObservation.fromAnswer(
        const NoulAnswer(noul: .79999999999999),
        true,
      );
      expect(
        (categoricalMetrics([below])['bins'] as List)[7],
        containsPair('count', 1),
      );
    },
  );
  test(
    'fitted inclusive gate uses original wire probabilities and their order',
    () {
      const probabilities = {'b': .47519999999999996, 'a': .5148};
      final rows = [
        for (var i = 0; i < 4; i++)
          () {
            final req = {
              'model': 'fixture',
              'state': 'calibration $i',
              'questions': {
                'choice': {
                  'type': 'choice',
                  'criteria': {'b': null, 'a': null},
                },
              },
            };
            return {
              'version': 1,
              'model_sha256': modelHash,
              'request_sha256': requestHash(req),
              'request': req,
              'response': {
                'model': 'fixture',
                'answers': {
                  'choice': {
                    'type': 'choice',
                    'choice': 'a',
                    'probabilities': probabilities,
                    'confidence': 0,
                  },
                },
                'usage': {'input_tokens': 0, 'output_tokens': 0},
              },
              'labels': {'choice': 'a'},
            };
          }(),
      ];
      final gate = fitCalibration(
        CalibrationDataset.parse(
          rows.map(jsonEncode).join('\n'),
          modelSha256: modelHash,
        ),
      ).profile.questions['choice']!;
      final observation = CategoricalObservation.fromAnswer(
        const ChoiceAnswer(
          choice: 'a',
          probabilities: probabilities,
          confidence: 0,
        ),
        'a',
      );
      expect(
        gate.accepts(
          distributionConfidence(
            calibrateProbabilities(probabilities.values, gate.temperature),
          ),
        ),
        isTrue,
      );
      expect(
        gateMetrics(
          [observation],
          attempted: 1,
          gate: gate,
          targetError: .05,
        )['accepted'],
        1,
      );
    },
  );
  test('zero support, empty results, and ECE right endpoint remain valid', () {
    final result = categoricalMetrics([
      CategoricalObservation.fromAnswer(const NoulAnswer(noul: 0), true),
    ]);
    expect(result['accuracy'], 0);
    expect(result['ece10'], 1);
    expect(result['brier'], 2);
    expect((result['bins'] as List).last, containsPair('count', 1));
    expect(categoricalMetrics([])['accuracy'], isNull);
    expect(categoricalMetrics([])['ece10'], isNull);
    expect(categoricalMetrics([])['brier'], isNull);
  });

  test('tie conventions and invalid nonmodal Choice are explicit', () {
    expect(
      CategoricalObservation.fromAnswer(
        const NoulAnswer(noul: .5),
        true,
      ).correct,
      isTrue,
    );
    expect(
      CategoricalObservation.fromAnswer(
        const ChoiceAnswer(
          confidence: 0,
          choice: 'b',
          probabilities: {'a': .5, 'b': .5},
        ),
        'b',
      ).correct,
      isTrue,
    );
    expect(
      CategoricalObservation.fromAnswer(
        const ScoreAnswer(
          confidence: 0,
          score: .5,
          probabilities: {'1': .5, '0': .5},
          legend: {'0': 'low', '1': 'high'},
        ),
        '0',
      ).correct,
      isTrue,
    );
    expect(
      () => CategoricalObservation.fromAnswer(
        const ChoiceAnswer(
          confidence: 0,
          choice: 'a',
          probabilities: {'a': .2, 'b': .8},
        ),
        'a',
      ),
      throwsFormatException,
    );
  });

  test(
    'fixed inclusive gates count failures in coverage and never refit labels',
    () {
      final samples = [
        for (final pair in [
          (.875, true),
          (.75, false),
          (.625, true),
          (.5, true),
        ])
          CategoricalObservation.fromAnswer(NoulAnswer(noul: pair.$1), pair.$2),
      ];
      final gate = QuestionCalibration(
        type: 'noul',
        temperature: 1,
        threshold: .5,
      );
      final result = gateMetrics(
        samples,
        attempted: 6,
        gate: gate,
        targetError: .01,
      );
      expect(result['accepted'], 2);
      expect(result['coverage'], 2 / 6);
      expect(result['accepted_errors'], 1);
      expect(result['observed_error'], .5);
      expect(result['exceeds_target'], isTrue);
      final none = gateMetrics(
        samples,
        attempted: 6,
        gate: QuestionCalibration(
          type: 'noul',
          temperature: 1,
          threshold: null,
        ),
        targetError: .1,
      );
      expect(none['coverage'], 0);
      expect(none['observed_error'], isNull);
    },
  );

  test('nearest rank latency includes sample count and unknown exclusion', () {
    expect(latencyMetrics([1, 2, 3, 100, null]), {
      'samples': 4,
      'unmeasured': 1,
      'p50_us': 2,
      'p95_us': 100,
    });
    expect(latencyMetrics([null])['p50_us'], isNull);
  });
}
