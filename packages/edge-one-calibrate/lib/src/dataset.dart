import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart' show redactedState, RecordingBackend;

import 'identity.dart';

/// One labeled cached response. Its questions always share a split partition.
final class CalibrationRecord {
  CalibrationRecord._(
    this.requestSha256,
    this.comparisonSha256,
    this.samples,
    this._identity,
  );
  final String requestSha256;
  final String? comparisonSha256;

  /// Version-specific grouped split identity; raw provenance remains separate.
  String get splitSha256 => comparisonSha256 ?? requestSha256;
  final Map<String, CalibrationSample> samples;
  final Map<String, Object?> _identity;
}

/// A categorical view of one cached System One answer and its label.
final class CalibrationSample {
  CalibrationSample._(
    this.type,
    this.probabilities,
    this.labelIndex,
    this.predictedIndex,
  );
  final String type;
  final List<double> probabilities;
  final int labelIndex;
  final int predictedIndex;
  bool get correct => labelIndex == predictedIndex;
}

/// Validated, model-bound cached responses; never invokes a backend.
final class CalibrationDataset {
  CalibrationDataset._(
    this.modelSha256,
    this.records,
    this.sha256,
    this.identitySidecar,
  );

  /// [redactedRequests] asserts that the whole input contains redacted requests
  /// with trustworthy original, pre-redaction digests. It skips deduplication of
  /// stored request bodies, which can coincide after a custom redactor runs.
  /// Duplicate original digests and all other validation remain enforced.
  /// Producers must deduplicate original requests before redaction; hidden
  /// originals cannot be verified or canonically deduplicated here.
  ///
  /// Defaults to false; the built-in [redactedState] marker is always recognized.
  ///
  /// [identitySidecar] opts into report v2 and ordered model-independent identity.
  /// Available unredacted bodies and [originalRequests] always verify both raw
  /// and semantic digests. Supplied originals must cover the dataset exactly.
  /// Only hidden originals may rely on [trustIdentitySidecar], an explicit
  /// producer assertion that cannot authenticate their content. This attests
  /// that the producer validated stable ordered original question definitions,
  /// original digest correctness and uniqueness before redaction.
  factory CalibrationDataset.parse(
    String jsonl, {
    required String modelSha256,
    bool redactedRequests = false,
    CalibrationIdentitySidecar? identitySidecar,
    Map<String, SystemOneRequest>? originalRequests,
    bool trustIdentitySidecar = false,
  }) {
    checkHash(modelSha256, 'model_sha256');
    if (identitySidecar == null &&
        (originalRequests != null || trustIdentitySidecar)) {
      throw const FormatException(
        'originals and identity trust require a sidecar',
      );
    }
    String? logicalModel;
    final records = <CalibrationRecord>[];
    final digests = <String>{};
    final requests = <String>{};
    final definitions = <String, String>{};
    for (final (index, line) in const LineSplitter().convert(jsonl).indexed) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line);
        const fields = {
          'version',
          'request_sha256',
          'model_sha256',
          'request',
          'response',
          'labels',
        };
        if (json is! Map<String, Object?> ||
            json.length != fields.length ||
            !fields.every(json.containsKey)) {
          throw const FormatException('expected a labeled version 1 recording');
        }
        if (json['version'] != 1)
          throw const FormatException('expected version 1');
        if (json['model_sha256'] != modelSha256) {
          throw const FormatException(
            'model_sha256 does not match the requested model',
          );
        }
        final digest = checkHash(json['request_sha256'], 'request_sha256');
        if (!digests.add(digest))
          throw const FormatException('duplicate request_sha256');
        final request = SystemOneJson.decodeRequest(json['request']);
        final response = SystemOneJson.decodeResponse(json['response']);
        SystemOneJson.checkAnswers(request.questions, response);
        if (request.model != response.model)
          throw const FormatException('request/response model mismatch');
        final requestJson = SystemOneJson.encodeRequest(request);
        final hidden = redactedRequests || request.state == redactedState;
        if (!hidden && RecordingBackend.requestSha256(request) != digest) {
          throw const FormatException('raw request digest mismatch');
        }
        String? comparison;
        SystemOneRequest? verifiedOriginal;
        if (identitySidecar != null) {
          logicalModel ??= request.model;
          if (logicalModel != request.model) {
            throw const FormatException('mixed logical models in dataset');
          }
          comparison = identitySidecar.associations[digest];
          if (comparison == null) {
            throw const FormatException('missing identity association');
          }
          final supplied = originalRequests?[digest];
          if (originalRequests != null && supplied == null) {
            throw const FormatException('missing original request');
          }
          // Trust is used only when original content is unavailable. Available
          // originals and unredacted stored bodies always verify both hashes.
          for (final original in [
            if (!hidden) request,
            if (supplied != null) supplied,
          ]) {
            if (RecordingBackend.requestSha256(original) != digest ||
                comparisonRequestSha256(original) != comparison) {
              throw const FormatException(
                'original raw or comparison digest mismatch',
              );
            }
            if (original.model != request.model) {
              throw const FormatException(
                'original/stored logical model mismatch',
              );
            }
            SystemOneJson.checkAnswers(original.questions, response);
            verifiedOriginal = original;
          }
          if (verifiedOriginal == null && !trustIdentitySidecar) {
            throw const FormatException(
              'hidden originals require explicit trusted identity sidecar',
            );
          }
        }
        if (identitySidecar == null &&
            !redactedRequests &&
            request.state != redactedState &&
            !requests.add(canonicalJson(requestJson))) {
          throw const FormatException('duplicate canonical request');
        }
        final labels = json['labels'];
        if (labels is! Map<String, Object?> ||
            labels.length != request.questions.length ||
            !request.questions.keys.every(labels.containsKey)) {
          throw const FormatException(
            'labels must cover exactly the request questions',
          );
        }
        final definitionRequest = verifiedOriginal == null
            ? requestJson
            : SystemOneJson.encodeRequest(verifiedOriginal);
        final samples = <String, CalibrationSample>{};
        final scoreLegends = <String, Object?>{};
        for (final key in request.questions.keys.toList()..sort()) {
          final answer = response.answers[key]!;
          if (answer is ScoreAnswer) scoreLegends[key] = answer.legend;
          final definition =
              (identitySidecar == null ? canonicalJson : jsonEncode)({
                'question': (definitionRequest['questions'] as Map)[key],
                if (answer is ScoreAnswer) 'score_legend': answer.legend,
              });
          final previous = definitions.putIfAbsent(key, () => definition);
          if (previous != definition)
            throw FormatException('question "$key" changes definition');
          samples[key] = _sample(answer, labels[key], key);
        }
        records.add(
          CalibrationRecord._(digest, comparison, Map.unmodifiable(samples), {
            if (comparison != null) 'comparison_sha256': comparison,
            if (comparison == null) ...{
              'request_sha256': digest,
              'request': requestJson,
            },
            'labels': comparison == null
                ? labels
                : {
                    for (final key in labels.keys.toList()..sort())
                      key: labels[key],
                  },
            'score_legends': scoreLegends,
          }),
        );
      } on FormatException catch (error) {
        throw FormatException('line ${index + 1}: ${error.message}');
      } on ArgumentError catch (error) {
        throw FormatException('line ${index + 1}: ${error.message}');
      }
    }
    if (records.isEmpty) throw const FormatException('dataset is empty');
    if (identitySidecar != null &&
        (identitySidecar.associations.length != digests.length ||
            !identitySidecar.associations.keys.every(digests.contains))) {
      throw const FormatException('sidecar must cover exactly the dataset');
    }
    if (originalRequests != null &&
        (originalRequests.length != digests.length ||
            !originalRequests.keys.every(digests.contains))) {
      throw const FormatException('originals must cover exactly the dataset');
    }
    records.sort((a, b) => a.splitSha256.compareTo(b.splitSha256));
    return CalibrationDataset._(
      modelSha256,
      List.unmodifiable(records),
      identitySidecar == null
          ? digestJson([for (final record in records) record._identity])
          : _sha256Ordered([for (final record in records) record._identity]),
      identitySidecar,
    );
  }

  final String modelSha256;
  final CalibrationIdentitySidecar? identitySidecar;
  final List<CalibrationRecord> records;

  /// Data identity binds labels, question definitions and Score legend meanings,
  /// but excludes predicted probabilities so model upgrades can be compared.
  final String sha256;
}

CalibrationSample _sample(SystemOneAnswer answer, Object? label, String key) {
  final String type;
  final List<String> keys;
  final List<double> probabilities;
  final int predicted;
  final int truth;
  switch (answer) {
    case ChoiceAnswer():
      type = 'choice';
      keys = answer.probabilities.keys.toList()..sort();
      probabilities = [
        for (final key in keys) answer.probabilities[key]!.toDouble(),
      ];
      predicted = keys.indexOf(answer.choice);
      truth = label is String ? keys.indexOf(label) : -1;
      if (predicted < 0 ||
          probabilities.any((p) => p > probabilities[predicted])) {
        throw FormatException(
          'question "$key": cached choice must be a maximum-probability option',
        );
      }
    case ScoreAnswer():
      type = 'score';
      keys = answer.probabilities.keys.toList()..sort();
      probabilities = [
        for (final key in keys) answer.probabilities[key]!.toDouble(),
      ];
      predicted = _mode(probabilities);
      truth = label is String ? keys.indexOf(label) : -1;
    case NoulAnswer():
      type = 'noul';
      probabilities = [1 - answer.noul.toDouble(), answer.noul.toDouble()];
      predicted = answer.noul >= 0.5 ? 1 : 0;
      truth = label is bool ? (label ? 1 : 0) : -1;
  }
  if (truth < 0) throw FormatException('question "$key": invalid $type label');
  if (probabilities[truth] == 0) {
    throw FormatException(
      'question "$key": true label has zero probability; temperature cannot repair zero support',
    );
  }
  return CalibrationSample._(
    type,
    calibrateProbabilities(probabilities, 1),
    truth,
    predicted,
  );
}

int _mode(List<double> probabilities) {
  var index = 0;
  for (var i = 1; i < probabilities.length; i++) {
    if (probabilities[i] > probabilities[index]) index = i;
  }
  return index;
}

String checkHash(Object? value, String name) {
  if (value is! String ||
      value.length != 64 ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw FormatException('$name must be 64 lowercase hexadecimal digits');
  }
  return value;
}

String digestJson(Object? json) =>
    sha256.convert(utf8.encode(canonicalJson(json))).toString();

String canonicalJson(Object? value) => jsonEncode(_canonical(value));

Object? _canonical(Object? value) => switch (value) {
  Map<String, Object?>() => {
    for (final key in value.keys.toList()..sort()) key: _canonical(value[key]),
  },
  List() => [for (final child in value) _canonical(child)],
  _ => value,
};

String _sha256Ordered(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
