// Generated from schemas/system-one-v1.schema.json.
// Schema SHA-256: b50719e9750907eaf07fd641c83148dfec1fcf33cae5e47426fe353dbc88a238
// Do not edit. Run: python3 tools/generate_contracts.py

typedef JsonValue = Object?;
typedef StructuredValue = Object;
typedef OptionalStructuredValue = Object?;

sealed class SystemOneQuestion {
  const SystemOneQuestion();
}

sealed class SystemOneAnswer {
  const SystemOneAnswer();
}

final class ChoiceQuestion extends SystemOneQuestion {
  String get type => "choice";
  final OptionalStructuredValue instructions;
  final Map<String, OptionalStructuredValue> criteria;

  const ChoiceQuestion({this.instructions, required this.criteria});
}

final class ScoreQuestion extends SystemOneQuestion {
  String get type => "score";
  final OptionalStructuredValue instructions;
  final List<StructuredValue> criteria;

  const ScoreQuestion({this.instructions, required this.criteria});
}

final class NoulQuestion extends SystemOneQuestion {
  String get type => "noul";
  final OptionalStructuredValue instructions;
  final Map<String, OptionalStructuredValue>? criteria;

  const NoulQuestion({this.instructions, this.criteria});
}

final class ChoiceAnswer extends SystemOneAnswer {
  String get type => "choice";
  final String choice;
  final Map<String, double> probabilities;
  final double confidence;

  const ChoiceAnswer({
    required this.choice,
    required this.probabilities,
    required this.confidence,
  });
}

final class ScoreAnswer extends SystemOneAnswer {
  String get type => "score";
  final double score;
  final Map<String, StructuredValue> legend;
  final Map<String, double> probabilities;
  final double confidence;

  const ScoreAnswer({
    required this.score,
    required this.legend,
    required this.probabilities,
    required this.confidence,
  });
}

final class NoulAnswer extends SystemOneAnswer {
  String get type => "noul";
  final double noul;

  const NoulAnswer({required this.noul});
}

final class Usage {
  final int inputTokens;
  final int outputTokens;

  const Usage({required this.inputTokens, required this.outputTokens});
}

final class SystemOneRequest {
  final StructuredValue state;
  final String model;
  final Map<String, SystemOneQuestion> questions;

  const SystemOneRequest({
    required this.state,
    required this.model,
    required this.questions,
  });
}

final class SystemOneResponse {
  final String model;
  final Map<String, SystemOneAnswer> answers;
  final Usage usage;
  final String? xRoute;
  final double? xLatencyMs;
  final JsonValue xEngine;
  final Map<String, JsonValue> xExtensions;

  const SystemOneResponse({
    required this.model,
    required this.answers,
    required this.usage,
    this.xRoute,
    this.xLatencyMs,
    this.xEngine,
    this.xExtensions = const {},
  });
}
