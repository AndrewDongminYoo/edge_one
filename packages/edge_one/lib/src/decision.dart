import 'contract_json.dart';
import 'generated/system_one_v1.dart';

/// A typed question whose answer resolves to a [Decision] of [T].
sealed class Question<T> {
  const Question();

  /// The wire definition sent in a System One request.
  SystemOneQuestion get definition;
}

/// A Choice question whose options map to values of [T].
final class Choice<T> extends Question<T> {
  /// Creates a Choice from wire option names mapped to their values.
  ///
  /// [descriptions] may describe any subset of the option names.
  Choice(
    OptionalStructuredValue instructions,
    Map<String, T> options, {
    Map<String, OptionalStructuredValue> descriptions = const {},
  }) : options = Map.unmodifiable(options),
       definition = ChoiceQuestion(
         instructions: instructions,
         criteria: Map.unmodifiable({
           for (final name in options.keys) name: descriptions[name],
         }),
       ) {
    if (options.isEmpty) {
      throw ArgumentError.value(options, 'options', 'must not be empty');
    }
    for (final name in descriptions.keys) {
      if (!options.containsKey(name)) {
        throw ArgumentError.value(name, 'descriptions', 'is not an option');
      }
    }
  }

  /// Creates a Choice whose option names are the enum values' names.
  static Choice<T> fromEnum<T extends Enum>(
    Iterable<T> values,
    OptionalStructuredValue instructions, {
    Map<T, OptionalStructuredValue> descriptions = const {},
  }) => Choice(
    instructions,
    {for (final value in values) value.name: value},
    descriptions: {
      for (final MapEntry(:key, :value) in descriptions.entries)
        key.name: value,
    },
  );

  /// Values keyed by wire option name.
  final Map<String, T> options;

  @override
  final ChoiceQuestion definition;
}

/// A yes/no question that resolves to a [bool] decision.
final class Noul extends Question<bool> {
  Noul(
    OptionalStructuredValue instructions, {
    OptionalStructuredValue whenTrue,
    OptionalStructuredValue whenFalse,
  }) : definition = NoulQuestion(
         instructions: instructions,
         criteria: whenTrue == null && whenFalse == null
             ? null
             : Map.unmodifiable({
                 if (whenTrue != null) 'true': whenTrue,
                 if (whenFalse != null) 'false': whenFalse,
               }),
       );

  @override
  final NoulQuestion definition;
}

/// An ordered-level question that resolves to the answer's numeric score.
final class Score extends Question<num> {
  Score(OptionalStructuredValue instructions, List<StructuredValue> levels)
    : definition = ScoreQuestion(
        instructions: instructions,
        criteria: List.unmodifiable(levels),
      ) {
    if (levels.isEmpty) {
      throw ArgumentError.value(levels, 'levels', 'must not be empty');
    }
  }

  @override
  final ScoreQuestion definition;
}

/// A per-question outcome gated by a minimum confidence.
///
/// Both branches keep the answer's raw [probabilities], keyed by wire option,
/// level, or `true`/`false` names.
sealed class Decision<T> {
  const Decision({required this.confidence, required this.probabilities});

  final double confidence;
  final Map<String, double> probabilities;
}

/// A decision whose confidence reached the threshold.
final class Decided<T> extends Decision<T> {
  const Decided({
    required this.value,
    required super.confidence,
    required super.probabilities,
  });

  final T value;
}

/// A decision whose confidence fell below the threshold.
final class Uncertain<T> extends Decision<T> {
  const Uncertain({required super.confidence, required super.probabilities});
}

/// A validated response paired with the typed questions it answers.
final class Evaluation {
  /// Validates [response] against the schema and against [questions].
  ///
  /// Throws [SystemOneFormatException] when the response is malformed or does
  /// not answer exactly the given questions.
  factory Evaluation({
    required Map<String, Question<Object?>> questions,
    required SystemOneResponse response,
    required double minConfidence,
  }) {
    checkMinConfidence(minConfidence);
    final validated = SystemOneJson.decodeResponse(
      SystemOneJson.encodeResponse(response),
    );
    SystemOneJson.checkAnswers({
      for (final MapEntry(:key, :value) in questions.entries)
        key: value.definition,
    }, validated);
    return Evaluation._(Map.unmodifiable(questions), validated, minConfidence);
  }

  Evaluation._(this.questions, this.response, this.minConfidence);

  final Map<String, Question<Object?>> questions;
  final SystemOneResponse response;

  /// The default threshold for [Decided] results.
  final double minConfidence;

  /// Resolves the Choice question [key] to one of its option values.
  ///
  /// Throws [ArgumentError] unless [key] names a Choice question whose option
  /// values are all [T]. Values are checked rather than the Choice's type
  /// argument, which a `Question<Object?>` map context can widen.
  Decision<T> choice<T>(String key, {double? minConfidence}) {
    final question = _question(key);
    if (question is! Choice ||
        !question.options.values.every((value) => value is T)) {
      throw ArgumentError.value(key, 'key', 'is not a Choice of $T values');
    }
    final answer = response.answers[key] as ChoiceAnswer;
    return _decide(
      () => question.options[answer.choice] as T,
      answer.confidence.toDouble(),
      answer.probabilities,
      minConfidence,
    );
  }

  /// Resolves the Noul question [key] to `noul >= 0.5`.
  ///
  /// The wire answer has no confidence, so this applies the Choice formula
  /// with two options: `|2 * noul - 1|`.
  Decision<bool> noul(String key, {double? minConfidence}) {
    if (_question(key) is! Noul) {
      throw ArgumentError.value(key, 'key', 'is not a Noul question');
    }
    final yes = (response.answers[key] as NoulAnswer).noul.toDouble();
    return _decide(() => yes >= 0.5, (2 * yes - 1).abs(), {
      'true': yes,
      'false': 1 - yes,
    }, minConfidence);
  }

  /// Resolves the Score question [key] to the answer's weighted score.
  Decision<num> score(String key, {double? minConfidence}) {
    if (_question(key) is! Score) {
      throw ArgumentError.value(key, 'key', 'is not a Score question');
    }
    final answer = response.answers[key] as ScoreAnswer;
    return _decide(
      () => answer.score,
      answer.confidence.toDouble(),
      answer.probabilities,
      minConfidence,
    );
  }

  Question<Object?> _question(String key) {
    final question = questions[key];
    if (question == null) {
      throw ArgumentError.value(key, 'key', 'is not an evaluated question');
    }
    return question;
  }

  Decision<T> _decide<T>(
    T Function() value,
    double confidence,
    Map<String, num> probabilities,
    double? minConfidence,
  ) {
    final threshold = minConfidence ?? this.minConfidence;
    checkMinConfidence(threshold);
    final raw = Map<String, double>.unmodifiable({
      for (final MapEntry(:key, :value) in probabilities.entries)
        key: value.toDouble(),
    });
    return confidence >= threshold
        ? Decided(value: value(), confidence: confidence, probabilities: raw)
        : Uncertain(confidence: confidence, probabilities: raw);
  }
}

/// Throws [ArgumentError] unless [value] is a threshold in `[0, 1]`.
void checkMinConfidence(double value) {
  if (!(value >= 0 && value <= 1)) {
    throw ArgumentError.value(value, 'minConfidence', 'must be in [0, 1]');
  }
}
