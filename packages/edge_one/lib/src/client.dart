import 'contract_json.dart';
import 'decision.dart';
import 'generated/system_one_v1.dart';

/// A local, remote, or test engine that answers System One requests.
///
/// Implementations receive requests that already passed schema validation.
abstract interface class SystemOneBackend {
  Future<SystemOneResponse> evaluate(SystemOneRequest request);
}

/// Validates both sides of a [SystemOneBackend] call.
final class DecisionClient {
  DecisionClient(
    this.backend, {
    required this.model,
    required this.minConfidence,
  }) {
    checkMinConfidence(minConfidence);
  }

  final SystemOneBackend backend;

  /// The `model` field of requests built by [evaluate].
  final String model;

  /// The default threshold for [Decided] results.
  final double minConfidence;

  /// Evaluates typed [questions] against [state].
  ///
  /// Throws [SystemOneFormatException] before calling the backend when the
  /// request is invalid, or afterwards when the backend's response is.
  Future<Evaluation> evaluate({
    required StructuredValue state,
    required Map<String, Question<Object?>> questions,
  }) async {
    final snapshot = Map<String, Question<Object?>>.unmodifiable(questions);
    final request = SystemOneJson.decodeRequest(
      SystemOneJson.encodeRequest(
        SystemOneRequest(
          state: state,
          model: model,
          questions: {
            for (final MapEntry(:key, :value) in snapshot.entries)
              key: value.definition,
          },
        ),
      ),
    );
    return Evaluation(
      questions: snapshot,
      response: await backend.evaluate(request),
      minConfidence: minConfidence,
    );
  }

  /// Evaluates a raw `/v1/systemone` request and returns the raw response.
  ///
  /// Throws [SystemOneFormatException] before calling the backend when
  /// [request] is invalid, or afterwards when the backend's response is.
  Future<Map<String, Object?>> evaluateJson(
    Map<String, Object?> request,
  ) async {
    final decoded = SystemOneJson.decodeRequest(request);
    final response = SystemOneJson.encodeResponse(
      await backend.evaluate(decoded),
    );
    SystemOneJson.checkAnswers(
      decoded.questions,
      SystemOneJson.decodeResponse(response),
    );
    return response;
  }
}
