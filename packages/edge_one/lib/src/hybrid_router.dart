import 'dart:async';

import 'calibration.dart';
import 'client.dart';
import 'contract_json.dart';
import 'generated/system_one_v1.dart';
import 'remote_backend.dart';

/// Opt-in shadow comparison with application-controlled deterministic sampling.
///
/// [sample] receives the immutable subset whose primary answers are local.
/// [observe] is awaited; its failures and sampling failures never alter the
/// primary response. Keep callbacks fast and handle persistence separately.
final class ShadowMode {
  const ShadowMode({required this.sample, required this.observe});

  final bool Function(SystemOneRequest) sample;
  final FutureOr<void> Function(ShadowComparison) observe;
}

/// Local answers paired with a validated remote comparison or typed failure.
///
/// Contains no request state. Applications explicitly control any observation IO.
final class ShadowComparison {
  ShadowComparison._({
    required Map<String, SystemOneAnswer> localAnswers,
    this.remoteResponse,
    this.error,
  }) : localAnswers = Map.unmodifiable(localAnswers);

  final Map<String, SystemOneAnswer> localAnswers;
  final SystemOneResponse? remoteResponse;
  final RemoteException? error;
}

/// Routes only forced questions and rejected local answers to a guarded remote.
///
/// Missing or mismatched calibration rejects all local answers for routing and
/// records a warning under `x_routing`. Ordinary remote denials/failures return
/// the complete local answer with `remote_error`; forced questions instead throw
/// the typed [RemoteException], because no local answer can satisfy their policy.
///
/// Calibration affects routing only. Returned answers retain raw probabilities,
/// scores, and confidence. It does not change `DecisionClient.minConfidence` or
/// the caller's `Decided` / `Uncertain` result. Inspect `x_routing` for gate status.
/// Use the verified local model's [modelSha256] and stable calibrated question
/// definitions. Applications determine [forcedRemoteKeys] outside the wire JSON;
/// this router does not guess native tokenizer or engine limits.
final class HybridRouter implements SystemOneBackend {
  HybridRouter({
    required this.local,
    required this.modelSha256,
    this.remote,
    this.calibration,
    this.shadow,
    Set<String> forcedRemoteKeys = const {},
  }) : forcedRemoteKeys = Set.unmodifiable(forcedRemoteKeys) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(modelSha256)) {
      throw ArgumentError.value(modelSha256, 'modelSha256');
    }
  }

  final SystemOneBackend local;
  final RemoteBackend? remote;
  final String modelSha256;
  final CalibrationProfile? calibration;
  final ShadowMode? shadow;
  final Set<String> forcedRemoteKeys;

  @override
  Future<SystemOneResponse> evaluate(SystemOneRequest request) async {
    final original = SystemOneJson.decodeRequest(
      SystemOneJson.encodeRequest(request),
    );
    for (final key in forcedRemoteKeys) {
      if (!original.questions.containsKey(key)) {
        throw ArgumentError.value(key, 'forcedRemoteKeys', 'unknown question');
      }
    }
    final localKeys = original.questions.keys
        .where((key) => !forcedRemoteKeys.contains(key))
        .toSet();
    SystemOneResponse? localResponse;
    if (localKeys.isNotEmpty) {
      final localRequest = _subset(original, localKeys);
      localResponse = _validatedResponse(
        localRequest,
        await local.evaluate(localRequest),
      );
    }

    final routing = <String, Map<String, Object?>>{};
    final remoteKeys = <String>{};
    for (final entry in original.questions.entries) {
      final key = entry.key;
      if (forcedRemoteKeys.contains(key)) {
        routing[key] = {'gate': 'forced'};
        remoteKeys.add(key);
      } else {
        final gate = _gate(key, entry.value, localResponse!.answers[key]!);
        routing[key] = gate;
        if (gate['gate'] != 'accepted') remoteKeys.add(key);
      }
    }

    SystemOneResponse? remoteResponse;
    if (remoteKeys.isNotEmpty) {
      try {
        final backend = remote;
        if (backend == null) {
          throw const RemotePolicyException(
            RemotePolicyReason.backendUnavailable,
          );
        }
        final candidate = await backend.evaluate(_subset(original, remoteKeys));
        // Both valid responses must also fit in a valid combined wire response.
        _combinedUsage(localResponse?.usage, candidate.usage);
        remoteResponse = candidate;
      } on RemoteException catch (error) {
        if (forcedRemoteKeys.isNotEmpty) rethrow;
        for (final key in remoteKeys) {
          routing[key]!['remote_error'] = error.code;
        }
      }
    }

    final answers = <String, SystemOneAnswer>{};
    for (final key in original.questions.keys) {
      final fromRemote = remoteResponse != null && remoteKeys.contains(key);
      final source = fromRemote ? remoteResponse : localResponse!;
      answers[key] = source.answers[key]!;
      routing[key]!.addAll({
        'route': fromRemote ? 'remote' : 'local',
        'model': source.model,
      });
    }
    final remoteCount = remoteResponse == null ? 0 : remoteKeys.length;
    final route = remoteCount == 0
        ? 'local'
        : remoteCount == answers.length
        ? 'remote'
        : 'auto';
    final singleSource = switch (route) {
      'local' => localResponse,
      'remote' => remoteResponse,
      _ => null,
    };
    final result = _validatedResponse(
      original,
      SystemOneResponse(
        model: singleSource?.model ?? original.model,
        answers: answers,
        usage: _combinedUsage(localResponse?.usage, remoteResponse?.usage),
        xRoute: route,
        xLatencyMs: singleSource?.xLatencyMs,
        xEngine: singleSource?.xEngine,
        xExtensions: {...?singleSource?.xExtensions, 'x_routing': routing},
      ),
    );
    await _runShadow(original, result, {
      for (final key in original.questions.keys)
        if (routing[key]!['route'] == 'local') key,
    });
    return result;
  }

  Future<void> _runShadow(
    SystemOneRequest request,
    SystemOneResponse primary,
    Set<String> localKeys,
  ) async {
    final mode = shadow;
    if (mode == null || localKeys.isEmpty) return;
    try {
      final candidate = _subset(request, localKeys);
      if (!mode.sample(candidate)) return;
      SystemOneResponse? comparison;
      RemoteException? failure;
      try {
        final backend = remote;
        if (backend == null) {
          throw const RemotePolicyException(
            RemotePolicyReason.backendUnavailable,
          );
        }
        comparison = await backend.evaluate(candidate);
      } on RemoteException catch (error) {
        failure = error;
      }
      await mode.observe(
        ShadowComparison._(
          localAnswers: {
            for (final key in localKeys) key: primary.answers[key]!,
          },
          remoteResponse: comparison,
          error: failure,
        ),
      );
    } catch (_) {
      // Shadow observation is best effort and cannot invalidate primary output.
    }
  }

  Map<String, Object?> _gate(
    String key,
    SystemOneQuestion question,
    SystemOneAnswer answer,
  ) {
    final profile = calibration;
    if (profile == null) {
      return {'gate': 'rejected', 'warning': 'missingProfile'};
    }
    if (profile.modelSha256 != modelSha256) {
      return {'gate': 'rejected', 'warning': 'modelHashMismatch'};
    }
    final fitted = profile.forQuestion(key, modelSha256: modelSha256);
    if (fitted == null) {
      return {'gate': 'rejected', 'warning': 'missingQuestion'};
    }
    final type = switch (question) {
      ChoiceQuestion() => 'choice',
      NoulQuestion() => 'noul',
      ScoreQuestion() => 'score',
    };
    if (fitted.type != type) {
      return {'gate': 'rejected', 'warning': 'questionTypeMismatch'};
    }
    final probabilities = switch (answer) {
      ChoiceAnswer(:final probabilities) => probabilities.values,
      ScoreAnswer(:final probabilities) => probabilities.values,
      NoulAnswer(:final noul) => [1 - noul, noul],
    };
    final confidence = distributionConfidence(
      calibrateProbabilities(probabilities, fitted.temperature),
    );
    return {
      'gate': fitted.accepts(confidence) ? 'accepted' : 'rejected',
      'calibrated_confidence': confidence,
      'threshold': fitted.threshold,
    };
  }
}

SystemOneRequest _subset(SystemOneRequest request, Set<String> keys) =>
    SystemOneRequest(
      state: request.state,
      model: request.model,
      questions: Map.unmodifiable({
        for (final entry in request.questions.entries)
          if (keys.contains(entry.key)) entry.key: entry.value,
      }),
    );

SystemOneResponse _validatedResponse(
  SystemOneRequest request,
  SystemOneResponse response,
) {
  final snapshot = SystemOneJson.decodeResponse(
    SystemOneJson.encodeResponse(response),
  );
  SystemOneJson.checkAnswers(request.questions, snapshot);
  return snapshot;
}

Usage _combinedUsage(Usage? local, Usage? remote) {
  final inputTokens = (local?.inputTokens ?? 0) + (remote?.inputTokens ?? 0);
  final outputTokens = (local?.outputTokens ?? 0) + (remote?.outputTokens ?? 0);
  if (inputTokens > 9007199254740991 || outputTokens > 9007199254740991) {
    throw const RemoteResponseException();
  }
  return Usage(inputTokens: inputTokens, outputTokens: outputTokens);
}
