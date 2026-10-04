import 'dart:collection';
import 'dart:convert';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';
import 'fixture.dart';
import 'case.dart';

export 'case.dart' show exceedsLocalOptions;

// Only this library can mint a result after the full replay and validation.
// Copy the backing list so even its producer cannot change a minted result.
final class _ReplayCaptures extends UnmodifiableListView<BenchmarkCapture> {
  _ReplayCaptures(this._bundle, List<BenchmarkCapture> captures)
    : super(List<BenchmarkCapture>.unmodifiable(captures));

  final BenchmarkBundle _bundle;
}

/// Internal report precondition; structural capture validation cannot establish
/// whether arbitrary caller-authored evidence records what actually executed.
void validateReplayProvenance(
  BenchmarkBundle bundle,
  List<BenchmarkCapture> captures,
) {
  if (captures is! _ReplayCaptures || !identical(captures._bundle, bundle)) {
    throw const FormatException(
      'report requires the unchanged replayBenchmark result for this bundle',
    );
  }
}

final class _FixtureFailure implements Exception {
  const _FixtureFailure(this.code, {this.unsupported = false});
  final String code;
  final bool unsupported;
}

final class _LocalReplay implements SystemOneBackend {
  _LocalReplay(this.bundle, this.entered, this.labels);
  final BenchmarkBundle bundle;
  final Map<String, Object?> labels;
  final List<BackendExchange> entered;
  bool attempted = false, completed = false;
  @override
  Future<SystemOneResponse> evaluate(SystemOneRequest request) async {
    attempted = true;
    if (request.questions.values.any(exceedsLocalOptions))
      throw const _FixtureFailure('localOptionLimit26', unsupported: true);
    final digest = RecordingBackend.requestSha256(request);
    final exchange = bundle.exchanges['local:$digest'];
    if (exchange == null) throw const _FixtureFailure('localFixtureMiss');
    entered.add(exchange);
    if (exchange.error != null)
      throw _FixtureFailure(
        exchange.error!,
        unsupported: exchange.error == 'unsupported',
      );
    // Preserve the existing strict four-field recording seam. The bundle has
    // already rejected duplicate digests and validated their unredacted hash.
    final response = await RecordingBackend.replay(
      jsonEncode({
        'version': 1,
        'request_sha256': digest,
        'request': SystemOneJson.encodeRequest(request),
        'response': exchange.body,
      }),
    ).evaluate(request);
    validateBenchmarkAnswerSemantics(bundle, labels, response);
    completed = true;
    return response;
  }
}

/// Replays fixtures through the real guarded remote backend and hybrid router.
/// There is no process, FFI, network fallback or replay wall-clock measurement.
/// The returned immutable list is bound to this exact [bundle]. Pass it directly
/// to benchmarkReport; copying or rebuilding it discards replay provenance.
Future<List<BenchmarkCapture>> replayBenchmark(BenchmarkBundle bundle) async {
  final captures = <BenchmarkCapture>[];
  for (final run in bundle.runs) {
    final budget = RemoteBudget(
      dailyLimitMicrocredits: run.budgetMicrocredits,
      now: () => DateTime.utc(2026, 1, 1),
    );
    var reserved = 0;
    for (final source in bundle.cases) {
      for (var trial = 0; trial < run.trialCount; trial++) {
        final entered = <BackendExchange>[];
        BackendExchange findRemote(SystemOneRequest request) {
          final exchange = bundle
              .exchanges['remote:${RecordingBackend.requestSha256(request)}'];
          if (exchange == null)
            throw const _FixtureFailure('remoteFixtureMiss');
          return exchange;
        }

        final remote = RemoteBackend(
          transport: (json) async {
            final exchange = findRemote(SystemOneJson.decodeRequest(json));
            entered.add(exchange); // entered transport is the charge boundary
            reserved += exchange.cost;
            if (exchange.error != null)
              throw const _FixtureFailure('fixtureTransportFailure');
            // The decoded body was deeply frozen before library parsing. This
            // is decoded transport evidence, never raw HTTP bytes.
            return RemoteTransportResponse(
              statusCode: exchange.status,
              body: exchange.body,
            );
          },
          policy: RemotePolicy(
            localOnly: false,
            hasConsent: () => run.consent,
            isNetworkAvailable: () => run.networkAvailable,
            beforeRemote: (request) => SystemOneRequest(
              state: '[masked]',
              model: request.model,
              questions: request.questions,
            ),
            budget: budget,
            estimateCost: (request) => findRemote(request).cost,
          ),
        );
        final local = _LocalReplay(bundle, entered, source.labels);
        final SystemOneBackend backend = switch (run.mode) {
          'local' => local,
          'remote' => remote,
          _ => HybridRouter(
            local: local,
            remote: remote,
            modelSha256: bundle.modelSha256,
            calibration: bundle.profiles[.05],
            forcedRemoteKeys: {
              for (final entry in source.request.questions.entries)
                if (exceedsLocalOptions(entry.value)) entry.key,
            },
          ),
        };
        var outcome = 'answered';
        String? error;
        SystemOneResponse? response;
        var validatingFinalResponse = false;
        try {
          final candidate = await backend.evaluate(source.request);
          validatingFinalResponse = true;
          final decoded = SystemOneJson.decodeResponse(
            SystemOneJson.encodeResponse(candidate),
          );
          SystemOneJson.checkAnswers(source.request.questions, decoded);
          validateBenchmarkAnswerSemantics(bundle, source.labels, decoded);
          response = decoded;
        } on _FixtureFailure catch (failure) {
          outcome = failure.unsupported ? 'unsupported' : 'error';
          error = failure.code;
        } on RemoteException catch (failure) {
          outcome = 'error';
          error = failure.code;
        } on BenchmarkAnswerException {
          outcome = 'error';
          error = 'invalidBenchmarkResponse';
        } on FormatException {
          outcome = 'error';
          error = 'invalidResponse';
        }
        final failureOrigin = outcome == 'answered'
            ? null
            : validatingFinalResponse
            ? 'response_validation'
            : run.mode == 'local' || (local.attempted && !local.completed)
            ? 'local'
            : 'remote';
        captures.add(
          BenchmarkCapture(
            failureOrigin: failureOrigin,
            runId: run.id,
            caseId: source.id,
            requestSha256: source.requestSha256,
            trial: trial,
            outcome: outcome,
            response: response,
            errorCode: error,
            exchanges: entered,
          ),
        );
      }
    }
    if (reserved != budget.spentMicrocredits)
      throw StateError(
        'entered transport reservations do not reconcile with budget',
      );
  }
  validateCaptures(bundle, captures);
  return _ReplayCaptures(bundle, captures);
}
