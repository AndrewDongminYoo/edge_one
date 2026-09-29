import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'client.dart';
import 'contract_json.dart';
import 'generated/system_one_v1.dart';

/// Returns a copy of a request with private content removed.
///
/// A redactor must keep every question key and type, and every Choice
/// option name and Score level count, so the recorded response still pairs
/// with the stored request.
typedef RequestRedactor = SystemOneRequest Function(SystemOneRequest request);

/// Replaces the request `state` with [redactedState].
SystemOneRequest redactState(SystemOneRequest request) => SystemOneRequest(
  state: redactedState,
  model: request.model,
  questions: request.questions,
);

/// Stored in place of the request `state` by [redactState].
const redactedState = '[redacted]';

/// A line of a recording that violates the recording format.
final class RecordingFormatException extends FormatException {
  RecordingFormatException(this.line, String message) : super(message);

  /// The 1-based line number in the JSON Lines input.
  final int line;

  @override
  String toString() => 'RecordingFormatException at line $line: $message';
}

/// A replayed request that the recording does not contain.
final class RecordingMissException implements Exception {
  RecordingMissException(this.requestSha256);

  final String requestSha256;

  @override
  String toString() =>
      'RecordingMissException: no recorded response for request '
      '$requestSha256';
}

/// Records System One calls as JSON Lines, or replays such a recording.
///
/// Each line is an object with exactly `version` (1), `request_sha256`, the
/// redacted `request`, and the `response`. The digest covers the UTF-8
/// bytes of `jsonEncode(SystemOneJson.encodeRequest(request))` before
/// redaction, so replay matches the original request, including key order,
/// without storing its private content.
sealed class RecordingBackend implements SystemOneBackend {
  /// Forwards each request to [backend] and appends one line to [sink].
  ///
  /// [redact] defaults to [redactState]. Responses are validated against
  /// the schema and the request, then stored unchanged.
  factory RecordingBackend.record(
    SystemOneBackend backend,
    StringSink sink, {
    RequestRedactor redact,
  }) = _Recorder;

  /// Answers requests from the lines of [jsonl] without a backend.
  ///
  /// Throws [RecordingFormatException] when a line is malformed. When lines
  /// share a digest, the first one is replayed.
  factory RecordingBackend.replay(String jsonl) = _Replayer.parse;

  /// The SHA-256 digest that identifies [request] in a recording.
  static String requestSha256(SystemOneRequest request) => sha256
      .convert(utf8.encode(jsonEncode(SystemOneJson.encodeRequest(request))))
      .toString();
}

final class _Recorder implements RecordingBackend {
  _Recorder(this.backend, this.sink, {this.redact = redactState});

  final SystemOneBackend backend;
  final StringSink sink;
  final RequestRedactor redact;

  @override
  Future<SystemOneResponse> evaluate(SystemOneRequest request) async {
    final digest = RecordingBackend.requestSha256(request);
    final response = SystemOneJson.decodeResponse(
      SystemOneJson.encodeResponse(await backend.evaluate(request)),
    );
    SystemOneJson.checkAnswers(request.questions, response);
    final redacted = SystemOneJson.encodeRequest(redact(request));
    try {
      SystemOneJson.checkAnswers(
        SystemOneJson.decodeRequest(redacted).questions,
        response,
      );
    } on SystemOneFormatException catch (error) {
      throw StateError(
        'The redactor changed the question structure: ${error.message}',
      );
    }
    sink.writeln(
      jsonEncode({
        'version': _version,
        'request_sha256': digest,
        'request': redacted,
        'response': SystemOneJson.encodeResponse(response),
      }),
    );
    return response;
  }
}

final class _Replayer implements RecordingBackend {
  _Replayer(this.responses);

  factory _Replayer.parse(String jsonl) {
    final responses = <String, SystemOneResponse>{};
    for (final (index, text) in const LineSplitter().convert(jsonl).indexed) {
      if (text.trim().isEmpty) {
        continue;
      }
      final (digest, response) = _parseLine(text, index + 1);
      responses.putIfAbsent(digest, () => response);
    }
    return _Replayer(Map.unmodifiable(responses));
  }

  final Map<String, SystemOneResponse> responses;

  /// Throws [RecordingMissException] for a request that was not recorded.
  @override
  Future<SystemOneResponse> evaluate(SystemOneRequest request) async {
    final digest = RecordingBackend.requestSha256(request);
    return responses[digest] ?? (throw RecordingMissException(digest));
  }
}

const _version = 1;
const _lineFields = {'version', 'request_sha256', 'request', 'response'};
final _digestPattern = RegExp(r'^[0-9a-f]{64}$');

(String, SystemOneResponse) _parseLine(String text, int line) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (error) {
    throw RecordingFormatException(line, 'invalid JSON: ${error.message}');
  }
  if (json is! Map<String, Object?>) {
    throw RecordingFormatException(line, 'expected an object');
  }
  final fields = json;
  for (final key in json.keys) {
    if (!_lineFields.contains(key)) {
      throw RecordingFormatException(line, 'unexpected field "$key"');
    }
  }
  for (final key in _lineFields) {
    if (!json.containsKey(key)) {
      throw RecordingFormatException(line, 'missing field "$key"');
    }
  }
  if (json['version'] != _version) {
    throw RecordingFormatException(line, 'expected version $_version');
  }
  final digest = json['request_sha256'];
  if (digest is! String || !_digestPattern.hasMatch(digest)) {
    throw RecordingFormatException(
      line,
      'request_sha256 must be 64 lowercase hex digits',
    );
  }
  final request = _field(
    line,
    'request',
    () => SystemOneJson.decodeRequest(fields['request']),
  );
  final response = _field(
    line,
    'response',
    () => SystemOneJson.decodeResponse(fields['response']),
  );
  _field(
    line,
    'response',
    () => SystemOneJson.checkAnswers(request.questions, response),
  );
  return (digest, response);
}

T _field<T>(int line, String field, T Function() read) {
  try {
    return read();
  } on SystemOneFormatException catch (error) {
    final pointer = error.pointer.isEmpty ? '/' : error.pointer;
    throw RecordingFormatException(line, '$field $pointer: ${error.message}');
  }
}
