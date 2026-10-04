import 'dart:async';

import 'client.dart';
import 'contract_json.dart';
import 'generated/system_one_v1.dart';
import 'remote_budget.dart';

/// Masks every outbound field, including state, instructions, and criteria.
///
/// Input and validated output are immutable snapshots. Preserve model, question
/// keys/types, Choice option keys, and Score level counts so answers still pair.
typedef BeforeRemote = FutureOr<SystemOneRequest> Function(SystemOneRequest);

/// Injected transport; the package itself performs no network or credential IO.
///
/// The request is a deeply immutable, schema-validated JSON object. The adapter
/// supplies an already-decoded JSON body. Configure timeouts in that adapter.
typedef RemoteTransport =
    Future<RemoteTransportResponse> Function(Map<String, Object?> request);

final class RemoteTransportResponse {
  const RemoteTransportResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Object? body;
}

/// Explicit application policy, with remote access disabled by default.
///
/// Consent and network callbacks must be read-only synchronous queries. They are
/// rechecked after masking, cost estimation, and the clock; consent is checked
/// last. Arbitrarily mutually mutating callbacks cannot be sampled atomically.
/// [estimateCost] sees the immutable masked request and returns a conservative
/// upper bound in the same integer microcredits as [budget]. Every dispatched
/// attempt is charged, even if the transport or service fails. No retry is made.
final class RemotePolicy {
  const RemotePolicy({
    this.localOnly = true,
    this.hasConsent,
    this.isNetworkAvailable,
    this.beforeRemote,
    this.budget,
    this.estimateCost,
  });

  final bool localOnly;
  final bool Function()? hasConsent;
  final bool Function()? isNetworkAvailable;
  final BeforeRemote? beforeRemote;
  final RemoteBudget? budget;
  final int Function(SystemOneRequest)? estimateCost;
}

enum RemotePolicyReason {
  localOnly,
  consentRequired,
  networkUnavailable,
  maskingRequired,
  budgetRequired,
  costEstimateRequired,
  budgetExhausted,
  policyCheckFailed,
  costEstimateFailed,
  backendUnavailable,
}

/// Safe-to-display failure codes never include request or service body content.
sealed class RemoteException implements Exception {
  const RemoteException();

  String get code;

  @override
  String toString() => 'RemoteException: $code';
}

final class RemotePolicyException extends RemoteException {
  const RemotePolicyException(this.reason);

  final RemotePolicyReason reason;

  @override
  String get code => reason.name;
}

enum RemoteStatusKind {
  unauthorized,
  invalidRequest,
  rateLimited,
  overloaded,
  unexpected,
}

final class RemoteStatusException extends RemoteException {
  const RemoteStatusException(this.statusCode);

  final int statusCode;

  RemoteStatusKind get kind => switch (statusCode) {
    401 => RemoteStatusKind.unauthorized,
    422 => RemoteStatusKind.invalidRequest,
    429 => RemoteStatusKind.rateLimited,
    529 => RemoteStatusKind.overloaded,
    _ => RemoteStatusKind.unexpected,
  };

  @override
  String get code => kind.name;

  @override
  String toString() => 'RemoteStatusException: $statusCode (${kind.name})';
}

final class RemoteTransportException extends RemoteException {
  const RemoteTransportException();

  @override
  String get code => 'transportFailed';
}

final class RemoteMaskingException extends RemoteException {
  const RemoteMaskingException();

  @override
  String get code => 'maskingFailed';
}

final class RemoteResponseException extends RemoteException {
  const RemoteResponseException();

  @override
  String get code => 'invalidResponse';
}

/// A policy-guarded System One backend using an application-supplied transport.
///
/// Direct calls and router/shadow calls share the same guards and full-request
/// masking. Typed remote failures contain no payloads or private error messages.
/// Invalid caller input throws [SystemOneFormatException] before any callback.
final class RemoteBackend implements SystemOneBackend {
  const RemoteBackend({
    required this.transport,
    this.policy = const RemotePolicy(),
  });

  final RemoteTransport transport;
  final RemotePolicy policy;

  @override
  Future<SystemOneResponse> evaluate(SystemOneRequest request) async {
    final original = _snapshot(request);
    _checkPolicy();
    late final SystemOneRequest masked;
    try {
      masked = _snapshot(await policy.beforeRemote!(original));
      _checkMaskShape(original, masked);
    } catch (_) {
      throw const RemoteMaskingException();
    }
    final wire =
        _freeze(SystemOneJson.encodeRequest(masked)) as Map<String, Object?>;
    _checkPolicy();
    late final int cost;
    try {
      cost = policy.estimateCost!(masked);
      // Cost and clock callbacks finish before the final policy verification.
      if (!policy.budget!.tryCharge(cost, beforeCharge: _checkPolicy)) {
        throw const RemotePolicyException(RemotePolicyReason.budgetExhausted);
      }
    } on RemotePolicyException {
      rethrow;
    } catch (_) {
      throw const RemotePolicyException(RemotePolicyReason.costEstimateFailed);
    }

    // No await or application callback between the charge and transport call.
    late final RemoteTransportResponse result;
    try {
      result = await transport(wire);
    } catch (_) {
      throw const RemoteTransportException();
    }
    if (result.statusCode < 200 || result.statusCode >= 300) {
      throw RemoteStatusException(result.statusCode);
    }
    try {
      final response = SystemOneJson.decodeResponse(result.body);
      SystemOneJson.checkAnswers(original.questions, response);
      return SystemOneResponse(
        model: response.model,
        answers: response.answers,
        usage: response.usage,
        xRoute: 'remote',
        xLatencyMs: response.xLatencyMs,
        xEngine: response.xEngine,
        xExtensions: response.xExtensions,
      );
    } catch (_) {
      throw const RemoteResponseException();
    }
  }

  void _checkPolicy() {
    try {
      if (policy.localOnly) {
        throw const RemotePolicyException(RemotePolicyReason.localOnly);
      }
      if (policy.hasConsent == null) {
        throw const RemotePolicyException(RemotePolicyReason.consentRequired);
      }
      if (policy.isNetworkAvailable == null) {
        throw const RemotePolicyException(
          RemotePolicyReason.networkUnavailable,
        );
      }
      if (policy.beforeRemote == null) {
        throw const RemotePolicyException(RemotePolicyReason.maskingRequired);
      }
      if (policy.budget == null) {
        throw const RemotePolicyException(RemotePolicyReason.budgetRequired);
      }
      if (policy.estimateCost == null) {
        throw const RemotePolicyException(
          RemotePolicyReason.costEstimateRequired,
        );
      }
      if (!policy.isNetworkAvailable!()) {
        throw const RemotePolicyException(
          RemotePolicyReason.networkUnavailable,
        );
      }
      // Consent is the last application callback before the budget charge.
      if (!policy.hasConsent!()) {
        throw const RemotePolicyException(RemotePolicyReason.consentRequired);
      }
    } on RemotePolicyException {
      rethrow;
    } catch (_) {
      throw const RemotePolicyException(RemotePolicyReason.policyCheckFailed);
    }
  }
}

SystemOneRequest _snapshot(SystemOneRequest request) =>
    SystemOneJson.decodeRequest(SystemOneJson.encodeRequest(request));

void _checkMaskShape(SystemOneRequest original, SystemOneRequest masked) {
  if (original.model != masked.model ||
      !_sameKeys(original.questions, masked.questions)) {
    throw const RemoteMaskingException();
  }
  for (final entry in original.questions.entries) {
    final other = masked.questions[entry.key];
    final matches = switch ((entry.value, other)) {
      (
        ChoiceQuestion(:final criteria),
        ChoiceQuestion(criteria: final other),
      ) =>
        _sameKeys(criteria, other),
      (ScoreQuestion(:final criteria), ScoreQuestion(criteria: final other)) =>
        criteria.length == other.length,
      (NoulQuestion(), NoulQuestion()) => true,
      _ => false,
    };
    if (!matches) throw const RemoteMaskingException();
  }
}

bool _sameKeys(Map<String, Object?> a, Map<String, Object?> b) =>
    a.length == b.length && a.keys.every(b.containsKey);

Object? _freeze(Object? value) => switch (value) {
  Map<String, Object?>() => Map<String, Object?>.unmodifiable({
    for (final entry in value.entries) entry.key: _freeze(entry.value),
  }),
  List<Object?>() => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};
