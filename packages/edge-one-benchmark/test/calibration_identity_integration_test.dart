import 'dart:convert';

import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';
import 'package:edge_one_benchmark/edge_one_benchmark.dart';
import 'package:edge_one_calibrate/edge_one_calibrate.dart';
import 'package:test/test.dart';

SystemOneRequest _request(String model, Object state) => SystemOneRequest(
  model: model,
  state: state,
  questions: const {'positive': NoulQuestion(instructions: 'Positive?')},
);

FakeEngine _backend() => FakeEngine(
  weights: {
    'positive': {'true': 7, 'false': 1},
  },
);

Future<CalibrationRun> _recaptureAndFit(
  List<SystemOneRequest> originals,
  String modelHash,
) async {
  final sidecar = CalibrationIdentitySidecar.parse(
    jsonDecode(
      jsonEncode(CalibrationIdentitySidecar.fromRequests(originals).toJson()),
    ),
  );
  final recorded = StringBuffer();
  final recorder = RecordingBackend.record(_backend(), recorded);
  for (final original in originals) {
    await recorder.evaluate(original);
  }
  final labeled = const LineSplitter()
      .convert(recorded.toString())
      .map((line) {
        final row = jsonDecode(line) as Map<String, Object?>;
        return jsonEncode({
          ...row,
          'model_sha256': modelHash,
          'labels': {'positive': true},
        });
      })
      .join('\n');
  return fitCalibration(
    CalibrationDataset.parse(
      labeled,
      modelSha256: modelHash,
      identitySidecar: sidecar,
      originalRequests: {
        for (final request in originals)
          RecordingBackend.requestSha256(request): request,
      },
    ),
  );
}

void main() {
  test(
    'sidecar recapture keeps benchmark gates physically model-bound',
    () async {
      final oldHash = 'a' * 64;
      final newHash = 'b' * 64;
      final oldRequests = [
        for (var i = 0; i < 8; i++)
          _request('synthetic-v1', {'calibration_case': i}),
      ];
      final newRequests = [
        for (final request in oldRequests)
          _request('synthetic-v2', request.state),
      ];
      expect(
        comparisonRequestSha256(oldRequests.first),
        comparisonRequestSha256(newRequests.first),
      );
      expect(
        RecordingBackend.requestSha256(oldRequests.first),
        isNot(RecordingBackend.requestSha256(newRequests.first)),
      );

      final baseline = await _recaptureAndFit(oldRequests, oldHash);
      final candidate = await _recaptureAndFit(newRequests, newHash);
      expect(baseline.report['version'], 2);
      expect(candidate.report['version'], 2);
      for (final field in [
        'identity_scheme',
        'split_scheme',
        'dataset_sha256',
        'split',
      ]) {
        expect(candidate.report[field], baseline.report[field]);
      }
      expect(candidate.report['identity_scheme'], isNotEmpty);
      expect(candidate.report['split_scheme'], isNotEmpty);
      expect(
        candidate.report['provenance'],
        isNot(baseline.report['provenance']),
      );
      expect(
        checkRegression(
          baseline.report,
          candidate.report,
          maxAccuracyDrop: 0,
          maxCoverageDrift: 0,
          maxErrorIncrease: 0,
        ),
        isEmpty,
      );

      // Report v2 does not change the artifact consumed by benchmark/router code.
      final artifact = candidate.profile.toJson();
      expect(artifact['version'], 1);
      final profile = CalibrationProfile.fromJson(
        jsonDecode(jsonEncode(artifact)),
      );
      expect(profile.modelSha256, newHash);
      expect(profile.forQuestion('positive', modelSha256: oldHash), isNull);
      final gate = profile.forQuestion('positive', modelSha256: newHash)!;
      final request = _request('synthetic-v2', 'separate synthetic evaluation');
      final response = await HybridRouter(
        local: _backend(),
        modelSha256: newHash,
        calibration: profile,
      ).evaluate(request);
      final routing =
          (response.xExtensions['x_routing'] as Map)['positive'] as Map;
      expect(routing['gate'], 'accepted');
      expect(routing['route'], 'local');
      expect(routing.containsKey('warning'), isFalse);
      expect(
        gateMetrics(
          [
            CategoricalObservation.fromAnswer(
              response.answers['positive']!,
              true,
            ),
          ],
          attempted: 1,
          gate: gate,
          targetError: profile.targetError,
        )['accepted'],
        1,
      );

      final mismatched = await HybridRouter(
        local: _backend(),
        modelSha256: oldHash,
        calibration: profile,
      ).evaluate(request);
      final mismatchRouting =
          (mismatched.xExtensions['x_routing'] as Map)['positive'] as Map;
      expect(mismatchRouting['gate'], 'rejected');
      expect(mismatchRouting['warning'], 'modelHashMismatch');
    },
  );
}
