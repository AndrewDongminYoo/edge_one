import 'client.dart';
import 'contract_json.dart';
import 'generated/system_one_v1.dart';

/// A deterministic backend that answers each question from fixed weights.
///
/// Weights are keyed by question key, then by the answer's probability key:
/// the option name for Choice, `true` or `false` for Noul, and the level
/// index (`0`, `1`, ...) for Score. Omitted keys weigh 0, and questions
/// without weights receive a uniform distribution. The same request always
/// produces the same response, without a model, network, or clock.
///
/// Choice and Score confidence is `(K * max(p) - 1) / (K - 1)`. Score answers
/// echo each requested level as its legend value and report
/// `sum(index * p)`; this local convention is not verified against the
/// remote Score semantics.
final class FakeEngine implements SystemOneBackend {
  /// Throws [ArgumentError] when a weight is negative or not finite.
  FakeEngine({Map<String, Map<String, num>> weights = const {}})
    : weights = Map.unmodifiable({
        for (final MapEntry(:key, :value) in weights.entries)
          key: Map<String, num>.unmodifiable(value),
      }) {
    for (final MapEntry(key: question, value: entries) in weights.entries) {
      for (final MapEntry(:key, :value) in entries.entries) {
        if (!value.isFinite || value < 0) {
          throw ArgumentError.value(
            value,
            'weights',
            'weight for "$question"/"$key" must be finite and non-negative',
          );
        }
      }
    }
  }

  /// Identifies fake responses in the `x_engine` response field.
  static const Map<String, Object?> engine = {'id': 'edge-one-fake'};

  final Map<String, Map<String, num>> weights;

  /// Throws [SystemOneFormatException] for a Choice without options, which
  /// no answer can satisfy, and [StateError] when weights name an unknown
  /// answer key or leave a question with zero total weight.
  @override
  Future<SystemOneResponse> evaluate(SystemOneRequest request) async =>
      SystemOneResponse(
        model: request.model,
        answers: {
          for (final MapEntry(:key, :value) in request.questions.entries)
            key: _answer(key, value),
        },
        usage: const Usage(inputTokens: 0, outputTokens: 0),
        xEngine: engine,
      );

  SystemOneAnswer _answer(String key, SystemOneQuestion question) {
    switch (question) {
      case ChoiceQuestion(:final criteria):
        if (criteria.isEmpty) {
          throw SystemOneFormatException(
            '/questions/${key.replaceAll('~', '~0').replaceAll('/', '~1')}'
                '/criteria',
            'a Choice needs at least one option to be answered',
          );
        }
        final probabilities = _distribution(key, criteria.keys.toList());
        return ChoiceAnswer(
          choice: _mostLikely(probabilities),
          probabilities: probabilities,
          confidence: _confidence(probabilities),
        );
      case NoulQuestion():
        final probabilities = _distribution(key, const ['true', 'false']);
        return NoulAnswer(noul: probabilities['true']!);
      case ScoreQuestion(:final criteria):
        final levels = [for (var i = 0; i < criteria.length; i++) '$i'];
        final probabilities = _distribution(key, levels);
        var score = 0.0;
        for (final (index, level) in levels.indexed) {
          score += index * probabilities[level]!;
        }
        return ScoreAnswer(
          score: score,
          legend: {
            for (final (index, level) in levels.indexed) level: criteria[index],
          },
          probabilities: probabilities,
          confidence: _confidence(probabilities),
        );
    }
  }

  Map<String, double> _distribution(String question, List<String> keys) {
    final configured = weights[question];
    if (configured != null) {
      for (final name in configured.keys) {
        if (!keys.contains(name)) {
          throw StateError(
            'FakeEngine weights for "$question" name unknown key "$name"; '
            'expected one of ${keys.join(', ')}',
          );
        }
      }
    }
    // Doubles, because summing 64-bit integer weights can wrap silently.
    final chosen = [
      for (final name in keys)
        configured == null ? 1.0 : (configured[name] ?? 0).toDouble(),
    ];
    var scaled = chosen;
    var total = chosen.fold<double>(0, (sum, weight) => sum + weight);
    if (total <= 0) {
      throw StateError('FakeEngine weights for "$question" sum to zero');
    }
    if (!total.isFinite) {
      // Finite weights can overflow when summed; scale by the largest first.
      final top = chosen.reduce((a, b) => a > b ? a : b);
      scaled = [for (final weight in chosen) weight / top];
      total = scaled.fold<double>(0, (sum, weight) => sum + weight);
    }
    return {
      for (final (index, name) in keys.indexed) name: scaled[index] / total,
    };
  }
}

/// Returns the first key with the highest probability.
String _mostLikely(Map<String, double> probabilities) => probabilities.entries
    .reduce((best, entry) => entry.value > best.value ? entry : best)
    .key;

/// Generalizes `(K * max(p) - 1) / (K - 1)` to K options; one option is
/// certain.
double _confidence(Map<String, double> probabilities) {
  final count = probabilities.length;
  if (count == 1) {
    return 1;
  }
  final top = probabilities.values.reduce((a, b) => a > b ? a : b);
  return ((count * top - 1) / (count - 1)).clamp(0, 1).toDouble();
}
