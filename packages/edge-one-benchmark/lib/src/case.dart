import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';

/// An immutable request with categorical labels outside the wire request.
final class BenchmarkCase {
  BenchmarkCase({
    required this.id,
    required this.datasetId,
    required SystemOneRequest request,
    required Map<String, Object?> labels,
    required this.sourceSplit,
    required this.partition,
  }) : request = SystemOneJson.decodeRequest(
         SystemOneJson.encodeRequest(request),
       ),
       labels = Map.unmodifiable(labels) {
    requiredText(id);
    requiredText(datasetId);
    requiredText(sourceSplit);
    if (!const {'calibration', 'evaluation'}.contains(partition)) {
      throw const FormatException('invalid partition');
    }
    validateLabels(this.request, this.labels);
  }

  final String id, datasetId, sourceSplit, partition;
  final SystemOneRequest request;
  final Map<String, Object?> labels;
  String get requestSha256 => RecordingBackend.requestSha256(request);
}

void validateLabels(SystemOneRequest request, Map<String, Object?> labels) {
  if (labels.length != request.questions.length ||
      !request.questions.keys.every(labels.containsKey)) {
    throw const FormatException('labels must cover exactly the questions');
  }
  for (final entry in request.questions.entries) {
    final label = labels[entry.key];
    final valid = switch (entry.value) {
      ChoiceQuestion(:final criteria) =>
        label is String && criteria.containsKey(label),
      NoulQuestion() => label is bool,
      ScoreQuestion() => label is String && label.trim().isNotEmpty,
    };
    if (!valid) throw FormatException('invalid label for ${entry.key}');
  }
}

Map<String, Object?> jsonObject(Object? value) {
  if (value is! Map<String, Object?>)
    throw const FormatException('expected object');
  return value;
}

String requiredText(Object? value) {
  if (value is! String || value.trim().isEmpty)
    throw const FormatException('expected nonempty text');
  return value;
}
