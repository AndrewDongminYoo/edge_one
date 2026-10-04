import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart' show RecordingBackend;

import 'dataset.dart' show checkHash;

/// Ordered typed request identity, excluding only the top-level logical model.
const comparisonIdentityScheme = 'system-one-request-excluding-model-v1';

/// Ranks semantic request digests by SHA-256 of UTF-8 `$seed:$digest`.
const comparisonSplitScheme = 'sha256-seed-comparison-v1';

/// Stable ranking shared by fitting and v2 report validation.
String comparisonSplitRank(int seed, String digest) =>
    sha256.convert(utf8.encode('$seed:$digest')).toString();

/// Computes comparison identity before redaction. No original content is saved.
/// Mapping, question, Choice option, array, scalar and Unicode order/content are
/// preserved by the typed codec. This digest is not an anonymization mechanism.
String comparisonRequestSha256(SystemOneRequest original) {
  final json = Map<String, Object?>.from(SystemOneJson.encodeRequest(original))
    ..remove('model');
  return sha256
      .convert(
        utf8.encode(
          'edge-one-calibrate:$comparisonIdentityScheme\n${jsonEncode(json)}',
        ),
      )
      .toString();
}

/// Exact raw-recording to comparison identity associations, without originals.
final class CalibrationIdentitySidecar {
  CalibrationIdentitySidecar._(Map<String, String> associations)
    : associations = Map.unmodifiable(associations);

  /// Produce before redaction, using the same originals passed to the recorder.
  factory CalibrationIdentitySidecar.fromRequests(
    Iterable<SystemOneRequest> originals,
  ) {
    String? model;
    final entries = <Map<String, Object?>>[];
    for (final original in originals) {
      model ??= original.model;
      if (model != original.model) {
        throw const FormatException('mixed logical models in originals');
      }
      entries.add({
        'request_sha256': RecordingBackend.requestSha256(original),
        'comparison_sha256': comparisonRequestSha256(original),
      });
    }
    return CalibrationIdentitySidecar.parse({
      'version': 1,
      'identity_scheme': comparisonIdentityScheme,
      'associations': entries,
    });
  }

  /// Parses a decoded JSON sidecar; duplicate or conflicting pairs fail closed.
  factory CalibrationIdentitySidecar.parse(Object? value) {
    final json = _object(value, {'version', 'identity_scheme', 'associations'});
    if (json['version'] != 1 ||
        json['identity_scheme'] != comparisonIdentityScheme) {
      throw const FormatException('unsupported comparison identity sidecar');
    }
    final entries = json['associations'];
    if (entries is! List || entries.isEmpty) {
      throw const FormatException('sidecar associations must be nonempty');
    }
    final result = <String, String>{};
    final comparisons = <String>{};
    for (final entry in entries) {
      final pair = _object(entry, {'request_sha256', 'comparison_sha256'});
      final raw = checkHash(pair['request_sha256'], 'request_sha256');
      final semantic = checkHash(
        pair['comparison_sha256'],
        'comparison_sha256',
      );
      if (result.containsKey(raw) || !comparisons.add(semantic)) {
        throw const FormatException(
          'duplicate or conflicting identity association',
        );
      }
      result[raw] = semantic;
    }
    return CalibrationIdentitySidecar._(result);
  }

  final Map<String, String> associations;

  Map<String, Object?> toJson() => {
    'version': 1,
    'identity_scheme': comparisonIdentityScheme,
    'associations': [
      for (final raw in associations.keys.toList()..sort())
        {'request_sha256': raw, 'comparison_sha256': associations[raw]},
    ],
  };
}

Map<String, Object?> _object(Object? value, Set<String> fields) {
  if (value is! Map<String, Object?> ||
      value.length != fields.length ||
      !fields.every(value.containsKey)) {
    throw const FormatException('invalid identity sidecar fields');
  }
  return value;
}
