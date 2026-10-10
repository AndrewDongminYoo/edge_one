enum LocalStatusKind {
  busy,
  invalidRequest,
  cancelled,
  internal,
  unavailable,
  unexpected,
}

/// A native status, without retaining request data or native error payloads.
final class LocalEngineException implements Exception {
  const LocalEngineException(this.statusCode);

  final int statusCode;

  LocalStatusKind get kind => switch (statusCode) {
    409 => LocalStatusKind.busy,
    422 => LocalStatusKind.invalidRequest,
    499 => LocalStatusKind.cancelled,
    500 => LocalStatusKind.internal,
    503 => LocalStatusKind.unavailable,
    _ => LocalStatusKind.unexpected,
  };

  @override
  String toString() => 'LocalEngineException: $statusCode (${kind.name})';
}
