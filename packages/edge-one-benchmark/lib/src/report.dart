import 'package:edge_one/edge_one.dart';
import 'package:edge_one_calibrate/edge_one_calibrate.dart' show canonicalJson;
import 'case.dart';
import 'fixture.dart';
import 'metrics.dart';
import 'replay.dart' show validateReplayProvenance;

Map<String, int> _counts(Iterable<BenchmarkCapture> captures) {
  final rows = captures.toList();
  return {
    'attempted': rows.length,
    for (final outcome in ['answered', 'unsupported', 'error'])
      outcome: rows.where((c) => c.outcome == outcome).length,
  };
}

/// Pure report over the unchanged list returned by replayBenchmark for this exact
/// [bundle]. Caller-assembled, copied or imported captures are not accepted.
/// Only each run's selected quality trial contributes labels; all trials
/// contribute synthetic duration and cost.
Map<String, Object?> benchmarkReport(
  BenchmarkBundle bundle,
  List<BenchmarkCapture> captures,
) {
  validateReplayProvenance(bundle, captures);
  validateCaptures(bundle, captures);
  final cases = {for (final source in bundle.cases) source.id: source};
  final datasets = bundle.cases.map((c) => c.datasetId).toSet().toList()
    ..sort();
  final groups = <Map<String, Object?>>[];
  for (final run in bundle.runs) {
    for (final dataset in datasets) {
      final trials = captures
          .where(
            (c) => c.runId == run.id && cases[c.caseId]!.datasetId == dataset,
          )
          .toList();
      final quality = trials.where((c) => c.trial == run.qualityTrial).toList();
      final keys = {
        for (final capture in quality)
          ...cases[capture.caseId]!.request.questions.keys,
      }.toList()..sort();
      final questionReports = <Map<String, Object?>>[];
      final routing = {
        'accepted_local': 0,
        'fallback_local': 0,
        'returned_local': 0,
        'answered_remote': 0,
        'denied_escalations': 0,
        'failed_escalations': 0,
      };
      for (final key in keys) {
        final relevant = quality
            .where((c) => cases[c.caseId]!.request.questions.containsKey(key))
            .toList();
        final samples = <CategoricalObservation>[];
        final localSamples = <CategoricalObservation>[];
        for (final capture in relevant) {
          final source = cases[capture.caseId]!;
          CategoricalObservation? local;
          if (run.mode == 'local' && capture.outcome == 'answered') {
            local = CategoricalObservation.fromAnswer(
              capture.response!.answers[key]!,
              source.labels[key],
            );
          } else if (run.mode == 'hybrid' && capture.failureOrigin != 'local') {
            for (final exchange in capture.exchanges) {
              if (exchange.backend == 'local' &&
                  exchange.error == null &&
                  exchange.request.questions.containsKey(key)) {
                local = CategoricalObservation.fromAnswer(
                  SystemOneJson.decodeResponse(exchange.body).answers[key]!,
                  source.labels[key],
                );
              }
            }
          }
          if (local != null) localSamples.add(local);
          if (capture.outcome != 'answered') continue;
          samples.add(
            CategoricalObservation.fromAnswer(
              capture.response!.answers[key]!,
              source.labels[key],
            ),
          );
          if (run.mode == 'hybrid') {
            final route =
                (capture.response!.xExtensions['x_routing'] as Map)[key] as Map;
            if (route['route'] == 'remote')
              routing['answered_remote'] = routing['answered_remote']! + 1;
            if (route['route'] == 'local') {
              routing['returned_local'] = routing['returned_local']! + 1;
              final label = route['gate'] == 'accepted'
                  ? 'accepted_local'
                  : 'fallback_local';
              routing[label] = routing[label]! + 1;
            }
            if (route['remote_error'] case final String error) {
              final label = _denied(error)
                  ? 'denied_escalations'
                  : 'failed_escalations';
              routing[label] = routing[label]! + 1;
            }
          } else if (run.mode == 'remote') {
            routing['answered_remote'] = routing['answered_remote']! + 1;
          } else {
            routing['returned_local'] = routing['returned_local']! + 1;
            final gate = bundle.profiles[.05]!.questions[key];
            if (gate != null &&
                gate.accepts(
                  distributionConfidence(
                    calibrateProbabilities(
                      local!.gateProbabilities,
                      gate.temperature,
                    ),
                  ),
                )) {
              routing['accepted_local'] = routing['accepted_local']! + 1;
            }
          }
        }
        final counts = _counts(relevant);
        final reason = run.mode == 'remote'
            ? 'local_model_artifact_not_applicable'
            : bundle.profiles.values.any((p) => !p.questions.containsKey(key))
            ? 'question_has_no_local_calibration'
            : null;
        final metrics = categoricalMetrics(samples);
        questionReports.add({
          'key': key,
          'type': _questionType(
            cases[relevant.first.caseId]!.request.questions[key]!,
          ),
          ...counts,
          ...metrics,
          'completion_rate': counts['answered']! / relevant.length,
          'end_to_end_success_rate':
              (metrics['correct'] as int) / relevant.length,
          'local_gate_coverage_reason': reason,
          'local_gate_coverage': reason != null
              ? null
              : [
                  for (final target in [.01, .05, .1])
                    gateMetrics(
                      localSamples,
                      attempted: relevant.length,
                      gate: bundle.profiles[target]!.questions[key]!,
                      targetError: target,
                    ),
                ],
        });
      }
      // Forced remote failures return no partial response; account for their
      // attempted question escalations even though x_routing is unavailable.
      for (final capture in quality.where((c) => c.outcome != 'answered')) {
        if (run.mode == 'hybrid' &&
            (capture.failureOrigin == 'remote' ||
                capture.failureOrigin == 'response_validation') &&
            capture.errorCode != null &&
            (capture.exchanges.any((e) => e.backend == 'remote') ||
                _denied(capture.errorCode!))) {
          final label = _denied(capture.errorCode!)
              ? 'denied_escalations'
              : 'failed_escalations';
          routing[label] =
              routing[label]! +
              _escalatedKeys(bundle, cases[capture.caseId]!, capture).length;
        }
      }
      final remote = [
        for (final capture in trials)
          ...capture.exchanges.where((e) => e.backend == 'remote'),
      ];
      final cost = remote.fold(0, (sum, e) => sum + e.cost);
      groups.add({
        'dataset_id': dataset,
        'run_id': run.id,
        'mode': run.mode,
        'condition': run.condition,
        'quality_trial': run.qualityTrial,
        'request_counts': _counts(quality),
        'trial_requests': trials.length,
        'trial_request_counts': _counts(trials),
        'questions': questionReports,
        'routing': routing,
        'latency': {
          'scope':
              'sum_of_entered_synthetic_exchange_durations; not inference or replay wall-clock',
          'answered': latencyMetrics([
            for (final c in trials.where((c) => c.outcome == 'answered'))
              c.elapsedUs,
          ]),
          'failed': latencyMetrics([
            for (final c in trials.where((c) => c.outcome != 'answered'))
              c.elapsedUs,
          ]),
        },
        'cost': {
          'unit': 'application_microcredits',
          'basis': 'conservative_fixture_reservation',
          'billing': null,
          'dispatches': remote.length,
          'primary_reserved_microcredits': cost,
          'shadow_reserved_microcredits': 0,
          'reserved_microcredits': cost,
          'reserved_per_1000_request_attempts': trials.isEmpty
              ? null
              : cost * 1000 / trials.length,
        },
      });
    }
  }
  return {
    'version': 1,
    'origin': bundle.suite['origin'],
    'rights': bundle.suite['rights'],
    'datasets': [
      for (final dataset in datasets)
        {
          'dataset_id': dataset,
          'mapping_contract_version': 1,
          'source_split': 'synthetic',
          'selection': 'all authored fixture rows; no external sampling',
          'requests': bundle.cases.where((c) => c.datasetId == dataset).length,
          'question_definition_sha256': {
            for (final source in bundle.cases.where(
              (c) => c.datasetId == dataset,
            ))
              for (final entry
                  in (SystemOneJson.encodeRequest(source.request)['questions']
                          as Map<String, Object?>)
                      .entries)
                entry.key: textSha256(canonicalJson(entry.value)),
          },
        },
    ],
    'limitations': [
      'All text, labels, probabilities, durations and reservations are invented.',
      'Model hash is a synthetic fixture identity, not downloaded model bytes.',
      'Native/API/device performance, real corpus accuracy, dataset rights and billed currency are unmeasured.',
      'Fixture provenance identifies the frozen input producer base, not the current replay checkout.',
    ],
    'fixture_provenance': bundle.suite['provenance'],
    'fixture_files': bundle.suite['files'],
    'conventions': {
      'ece':
          '10 equal-width bins of raw maximum probability; final bin includes 1',
      'brier':
          'unscaled categorical sum, including both Noul classes; range [0,2]',
      'coverage':
          'fixed calibration-only local gates; hybrid uses preserved local subresponses; denominator includes every attempted evaluation question',
      'quality': 'one declared trial per request; no evaluation-label fitting',
      'timing': 'synthetic fixture durations only',
      'cost': 'application microcredits reserved, not money or billing',
    },
    'groups': groups,
    'captures': [
      for (final capture in captures) capture.toJson(cases[capture.caseId]!),
    ],
  };
}

String _questionType(SystemOneQuestion question) => switch (question) {
  ChoiceQuestion() => 'choice',
  NoulQuestion() => 'noul',
  ScoreQuestion() => 'score',
};
bool _denied(String code) => const {
  'localOnly',
  'consentRequired',
  'networkUnavailable',
  'maskingRequired',
  'budgetRequired',
  'costEstimateRequired',
  'budgetExhausted',
  'policyCheckFailed',
  'costEstimateFailed',
  'maskingFailed',
}.contains(code);

Set<String> _escalatedKeys(
  BenchmarkBundle bundle,
  BenchmarkCase source,
  BenchmarkCapture capture,
) {
  final dispatched = {
    for (final exchange in capture.exchanges.where(
      (e) => e.backend == 'remote',
    ))
      ...exchange.request.questions.keys,
  };
  if (dispatched.isNotEmpty) return dispatched;
  final keys = {
    for (final entry in source.request.questions.entries)
      if (exceedsLocalOptions(entry.value)) entry.key,
  };
  for (final exchange in capture.exchanges.where(
    (e) => e.backend == 'local' && e.error == null,
  )) {
    final response = SystemOneJson.decodeResponse(exchange.body);
    for (final entry in response.answers.entries) {
      final gate = bundle.profiles[.05]!.questions[entry.key];
      final sample = CategoricalObservation.fromAnswer(
        entry.value,
        source.labels[entry.key],
      );
      if (gate == null ||
          !gate.accepts(
            distributionConfidence(
              calibrateProbabilities(
                sample.gateProbabilities,
                gate.temperature,
              ),
            ),
          ))
        keys.add(entry.key);
    }
  }
  return keys;
}
