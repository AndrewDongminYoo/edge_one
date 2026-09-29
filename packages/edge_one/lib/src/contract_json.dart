import 'generated/system_one_v1.dart';

/// A System One document or pairing that violates the versioned contract.
///
/// [pointer] is an RFC 6901 JSON Pointer to the offending value; the empty
/// string denotes the document root.
final class SystemOneFormatException extends FormatException {
  SystemOneFormatException(this.pointer, String message) : super(message);

  final String pointer;

  @override
  String toString() =>
      'SystemOneFormatException at ${pointer.isEmpty ? '/' : pointer}: '
      '$message';
}

/// Strict JSON codec for `schemas/system-one-v1.schema.json`.
///
/// Decoders accept exactly the documents the schema accepts and return
/// unmodifiable deep copies. Encoders validate their output the same way, so
/// they never emit a document the schema would reject.
abstract final class SystemOneJson {
  /// Largest accepted distance between a probability map's total and 1.
  ///
  /// Wide enough for per-value rounding in remote responses; local numerical
  /// parity is gated separately at `1e-3` per probability.
  static const double probabilitySumTolerance = 1e-2;

  static SystemOneRequest decodeRequest(Object? json) => _request(json, '');

  static Map<String, Object?> encodeRequest(SystemOneRequest request) =>
      _requestJson(_request(_requestJson(request), ''));

  static SystemOneResponse decodeResponse(Object? json) => _response(json, '');

  static Map<String, Object?> encodeResponse(SystemOneResponse response) =>
      _responseJson(_response(_responseJson(response), ''));

  /// Checks the cross-field rules that the schema cannot express.
  ///
  /// Every question needs exactly one answer of the same type. Choice
  /// probabilities must cover exactly the requested options and include the
  /// chosen one. Score legends must list one entry per requested level and
  /// share their keys with the probabilities. Each probability map must sum
  /// to 1 within [probabilitySumTolerance].
  static void checkAnswers(
    Map<String, SystemOneQuestion> questions,
    SystemOneResponse response,
  ) {
    for (final key in questions.keys) {
      if (!response.answers.containsKey(key)) {
        throw SystemOneFormatException(
          '/answers',
          'missing answer for question "$key"',
        );
      }
    }
    for (final MapEntry(:key, value: answer) in response.answers.entries) {
      final pointer = _child('/answers', key);
      final question = questions[key];
      if (question == null) {
        throw SystemOneFormatException(pointer, 'no question has this key');
      }
      switch ((question, answer)) {
        case (
          ChoiceQuestion(:final criteria),
          ChoiceAnswer(:final choice, :final probabilities),
        ):
          _checkKeys(
            probabilities.keys,
            criteria.keys,
            '$pointer/probabilities',
            'option',
          );
          if (!criteria.containsKey(choice)) {
            throw SystemOneFormatException(
              '$pointer/choice',
              'choice "$choice" is not a requested option',
            );
          }
          _checkTotal(probabilities, '$pointer/probabilities');
        case (
          ScoreQuestion(:final criteria),
          ScoreAnswer(:final legend, :final probabilities),
        ):
          if (legend.length != criteria.length) {
            throw SystemOneFormatException(
              '$pointer/legend',
              'legend has ${legend.length} levels; '
                  'the question has ${criteria.length}',
            );
          }
          _checkKeys(
            probabilities.keys,
            legend.keys,
            '$pointer/probabilities',
            'level',
          );
          _checkTotal(probabilities, '$pointer/probabilities');
        case (NoulQuestion(), NoulAnswer()):
          break;
        case (_, _):
          throw SystemOneFormatException(
            '$pointer/type',
            'answer type "${_answerType(answer)}" does not match '
                'question type "${_questionType(question)}"',
          );
      }
    }
  }
}

const _requestFields = {'state', 'model', 'questions'};
const _questionFields = {'type', 'instructions', 'criteria'};
const _choiceAnswerFields = {'type', 'choice', 'probabilities', 'confidence'};
const _scoreAnswerFields = {
  'type',
  'score',
  'legend',
  'probabilities',
  'confidence',
};
const _noulAnswerFields = {'type', 'noul'};
const _usageFields = {'input_tokens', 'output_tokens'};
const _responseFields = {'model', 'answers', 'usage'};
const _responseExtensionFields = {'x_route', 'x_latency_ms', 'x_engine'};
const _routes = {'local', 'remote', 'auto'};
const _noulCriteria = {'true', 'false'};

// JSON integers beyond 2^53 cannot round-trip through JavaScript clients.
const _maxSafeInteger = 9007199254740991;

// Absorbs binary64 summation error, so a total such as 0.33 + 0.33 + 0.33
// that lies exactly on the tolerance boundary is accepted.
const _sumRoundingSlack = 1e-12;

SystemOneRequest _request(Object? json, String pointer) {
  final map = _object(json, pointer, _requestFields, _requestFields);
  final questions = _object(
    map['questions'],
    '$pointer/questions',
    null,
    const {},
  );
  if (questions.isEmpty) {
    throw SystemOneFormatException(
      '$pointer/questions',
      'expected at least one question',
    );
  }
  return SystemOneRequest(
    state: _structured(map['state'], '$pointer/state'),
    model: _string(map['model'], '$pointer/model'),
    questions: Map.unmodifiable({
      for (final MapEntry(:key, :value) in questions.entries)
        key: _question(value, _child('$pointer/questions', key)),
    }),
  );
}

SystemOneQuestion _question(Object? json, String pointer) {
  final type = _type(json, pointer);
  final required = type == 'noul' ? const {'type'} : const {'type', 'criteria'};
  final map = _object(json, pointer, _questionFields, required);
  final instructions = _optionalStructured(
    map['instructions'],
    '$pointer/instructions',
  );
  final criteriaPointer = '$pointer/criteria';
  switch (type) {
    case 'choice':
      final criteria = _object(
        map['criteria'],
        criteriaPointer,
        null,
        const {},
      );
      return ChoiceQuestion(
        instructions: instructions,
        criteria: Map.unmodifiable({
          for (final MapEntry(:key, :value) in criteria.entries)
            key: _optionalStructured(value, _child(criteriaPointer, key)),
        }),
      );
    case 'score':
      final criteria = _array(map['criteria'], criteriaPointer);
      if (criteria.isEmpty) {
        throw SystemOneFormatException(
          criteriaPointer,
          'expected at least one level',
        );
      }
      return ScoreQuestion(
        instructions: instructions,
        criteria: List.unmodifiable([
          for (final (index, value) in criteria.indexed)
            _structured(value, '$criteriaPointer/$index'),
        ]),
      );
    default:
      final criteria = map['criteria'];
      if (criteria == null) {
        return NoulQuestion(instructions: instructions);
      }
      final descriptions = _object(
        criteria,
        criteriaPointer,
        _noulCriteria,
        const {},
      );
      return NoulQuestion(
        instructions: instructions,
        criteria: Map.unmodifiable({
          for (final MapEntry(:key, :value) in descriptions.entries)
            key: _optionalStructured(value, _child(criteriaPointer, key)),
        }),
      );
  }
}

SystemOneResponse _response(Object? json, String pointer) {
  final map = _map(json, pointer);
  for (final key in map.keys) {
    if (!_responseFields.contains(key) && !key.startsWith('x_')) {
      throw SystemOneFormatException(
        _child(pointer, key),
        'unexpected field; response extensions must start with "x_"',
      );
    }
  }
  _requireFields(map, pointer, _responseFields);
  final answers = _object(map['answers'], '$pointer/answers', null, const {});
  if (answers.isEmpty) {
    throw SystemOneFormatException(
      '$pointer/answers',
      'expected at least one answer',
    );
  }
  final route = map['x_route'];
  if (map.containsKey('x_route') && !_routes.contains(route)) {
    throw SystemOneFormatException(
      '$pointer/x_route',
      'expected "local", "remote", or "auto"',
    );
  }
  final latency = map.containsKey('x_latency_ms')
      ? _number(map['x_latency_ms'], '$pointer/x_latency_ms', min: 0)
      : null;
  return SystemOneResponse(
    model: _string(map['model'], '$pointer/model'),
    answers: Map.unmodifiable({
      for (final MapEntry(:key, :value) in answers.entries)
        key: _answer(value, _child('$pointer/answers', key)),
    }),
    usage: _usage(map['usage'], '$pointer/usage'),
    xRoute: route as String?,
    xLatencyMs: latency,
    xEngine: _jsonValue(map['x_engine'], '$pointer/x_engine'),
    xExtensions: Map.unmodifiable({
      for (final MapEntry(:key, :value) in map.entries)
        if (key.startsWith('x_') && !_responseExtensionFields.contains(key))
          key: _jsonValue(value, _child(pointer, key)),
    }),
  );
}

SystemOneAnswer _answer(Object? json, String pointer) {
  final type = _type(json, pointer);
  switch (type) {
    case 'choice':
      final map = _object(
        json,
        pointer,
        _choiceAnswerFields,
        _choiceAnswerFields,
      );
      return ChoiceAnswer(
        choice: _string(map['choice'], '$pointer/choice'),
        probabilities: _probabilities(
          map['probabilities'],
          '$pointer/probabilities',
        ),
        confidence: _probability(map['confidence'], '$pointer/confidence'),
      );
    case 'score':
      final map = _object(
        json,
        pointer,
        _scoreAnswerFields,
        _scoreAnswerFields,
      );
      final legendPointer = '$pointer/legend';
      final legend = _object(map['legend'], legendPointer, null, const {});
      if (legend.isEmpty) {
        throw SystemOneFormatException(
          legendPointer,
          'expected at least one level',
        );
      }
      return ScoreAnswer(
        score: _number(map['score'], '$pointer/score'),
        legend: Map.unmodifiable({
          for (final MapEntry(:key, :value) in legend.entries)
            key: _structured(value, _child(legendPointer, key)),
        }),
        probabilities: _probabilities(
          map['probabilities'],
          '$pointer/probabilities',
        ),
        confidence: _probability(map['confidence'], '$pointer/confidence'),
      );
    default:
      final map = _object(json, pointer, _noulAnswerFields, _noulAnswerFields);
      return NoulAnswer(noul: _probability(map['noul'], '$pointer/noul'));
  }
}

Usage _usage(Object? json, String pointer) {
  final map = _object(json, pointer, _usageFields, _usageFields);
  return Usage(
    inputTokens: _count(map['input_tokens'], '$pointer/input_tokens'),
    outputTokens: _count(map['output_tokens'], '$pointer/output_tokens'),
  );
}

Map<String, Object?> _requestJson(SystemOneRequest request) =>
    Map.unmodifiable({
      'state': request.state,
      'model': request.model,
      'questions': Map<String, Object?>.unmodifiable({
        for (final MapEntry(:key, :value) in request.questions.entries)
          key: _questionJson(value),
      }),
    });

Map<String, Object?> _questionJson(SystemOneQuestion question) {
  final (type, instructions, criteria) = switch (question) {
    ChoiceQuestion() => (
      question.type,
      question.instructions,
      question.criteria,
    ),
    ScoreQuestion() => (
      question.type,
      question.instructions,
      question.criteria,
    ),
    NoulQuestion() => (question.type, question.instructions, question.criteria),
  };
  return Map.unmodifiable({
    'type': type,
    if (instructions != null) 'instructions': instructions,
    if (criteria != null) 'criteria': criteria,
  });
}

Map<String, Object?> _responseJson(SystemOneResponse response) {
  for (final key in response.xExtensions.keys) {
    if (!key.startsWith('x_')) {
      throw SystemOneFormatException(
        _child('', key),
        'response extensions must start with "x_"',
      );
    }
    if (_responseExtensionFields.contains(key)) {
      throw SystemOneFormatException(
        _child('', key),
        'use the dedicated response field instead of xExtensions',
      );
    }
  }
  return Map.unmodifiable({
    'model': response.model,
    'answers': Map<String, Object?>.unmodifiable({
      for (final MapEntry(:key, :value) in response.answers.entries)
        key: _answerJson(value),
    }),
    'usage': Map<String, Object?>.unmodifiable({
      'input_tokens': response.usage.inputTokens,
      'output_tokens': response.usage.outputTokens,
    }),
    if (response.xRoute != null) 'x_route': response.xRoute,
    if (response.xLatencyMs != null) 'x_latency_ms': response.xLatencyMs,
    if (response.xEngine != null) 'x_engine': response.xEngine,
    ...response.xExtensions,
  });
}

Map<String, Object?> _answerJson(SystemOneAnswer answer) =>
    Map.unmodifiable(switch (answer) {
      ChoiceAnswer() => {
        'type': answer.type,
        'choice': answer.choice,
        'probabilities': answer.probabilities,
        'confidence': answer.confidence,
      },
      ScoreAnswer() => {
        'type': answer.type,
        'score': answer.score,
        'legend': answer.legend,
        'probabilities': answer.probabilities,
        'confidence': answer.confidence,
      },
      NoulAnswer() => {'type': answer.type, 'noul': answer.noul},
    });

String _questionType(SystemOneQuestion question) => switch (question) {
  ChoiceQuestion() => question.type,
  ScoreQuestion() => question.type,
  NoulQuestion() => question.type,
};

String _answerType(SystemOneAnswer answer) => switch (answer) {
  ChoiceAnswer() => answer.type,
  ScoreAnswer() => answer.type,
  NoulAnswer() => answer.type,
};

void _checkKeys(
  Iterable<String> actual,
  Iterable<String> expected,
  String pointer,
  String noun,
) {
  final actualKeys = actual.toSet();
  for (final key in expected) {
    if (!actualKeys.contains(key)) {
      throw SystemOneFormatException(
        pointer,
        'missing probability for $noun "$key"',
      );
    }
  }
  final expectedKeys = expected.toSet();
  for (final key in actualKeys) {
    if (!expectedKeys.contains(key)) {
      throw SystemOneFormatException(_child(pointer, key), 'unknown $noun');
    }
  }
}

void _checkTotal(Map<String, num> probabilities, String pointer) {
  final total = probabilities.values.fold<double>(0, (sum, p) => sum + p);
  if ((total - 1).abs() >
      SystemOneJson.probabilitySumTolerance + _sumRoundingSlack) {
    throw SystemOneFormatException(pointer, 'probabilities sum to $total');
  }
}

String _type(Object? json, String pointer) {
  final map = _map(json, pointer);
  if (!map.containsKey('type')) {
    throw SystemOneFormatException(pointer, 'missing required field "type"');
  }
  final type = map['type'];
  if (type != 'choice' && type != 'score' && type != 'noul') {
    throw SystemOneFormatException(
      '$pointer/type',
      'expected "choice", "score", or "noul"',
    );
  }
  return type as String;
}

Map<String, Object?> _map(Object? json, String pointer) {
  if (json is! Map) {
    throw SystemOneFormatException(pointer, 'expected an object');
  }
  for (final key in json.keys) {
    if (key is! String) {
      throw SystemOneFormatException(pointer, 'expected string object keys');
    }
  }
  return json.cast<String, Object?>();
}

/// Reads an object whose field names are limited to [allowed] when non-null.
Map<String, Object?> _object(
  Object? json,
  String pointer,
  Set<String>? allowed,
  Set<String> required,
) {
  final map = _map(json, pointer);
  if (allowed != null) {
    for (final key in map.keys) {
      if (!allowed.contains(key)) {
        throw SystemOneFormatException(
          _child(pointer, key),
          'unexpected field',
        );
      }
    }
  }
  _requireFields(map, pointer, required);
  return map;
}

void _requireFields(
  Map<String, Object?> map,
  String pointer,
  Set<String> required,
) {
  for (final key in required) {
    if (!map.containsKey(key)) {
      throw SystemOneFormatException(pointer, 'missing required field "$key"');
    }
  }
}

List<Object?> _array(Object? json, String pointer) {
  if (json is! List) {
    throw SystemOneFormatException(pointer, 'expected an array');
  }
  return json.cast<Object?>();
}

String _string(Object? json, String pointer) {
  if (json is! String) {
    throw SystemOneFormatException(pointer, 'expected a string');
  }
  return json;
}

num _number(Object? json, String pointer, {num? min, num? max}) {
  if (json is! num || !json.isFinite) {
    throw SystemOneFormatException(pointer, 'expected a finite number');
  }
  if ((min != null && json < min) || (max != null && json > max)) {
    throw SystemOneFormatException(
      pointer,
      'expected a number in [${min ?? '-inf'}, ${max ?? 'inf'}]',
    );
  }
  return json;
}

num _probability(Object? json, String pointer) =>
    _number(json, pointer, min: 0, max: 1);

Map<String, num> _probabilities(Object? json, String pointer) {
  final map = _object(json, pointer, null, const {});
  if (map.isEmpty) {
    throw SystemOneFormatException(
      pointer,
      'expected at least one probability',
    );
  }
  return Map.unmodifiable({
    for (final MapEntry(:key, :value) in map.entries)
      key: _probability(value, _child(pointer, key)),
  });
}

int _count(Object? json, String pointer) {
  final value = _number(json, pointer, min: 0);
  if (value > _maxSafeInteger) {
    throw SystemOneFormatException(pointer, 'expected at most 2^53 - 1');
  }
  if (value is int) {
    return value;
  }
  if (value != value.roundToDouble()) {
    throw SystemOneFormatException(pointer, 'expected an integer');
  }
  return value.toInt();
}

Object _structured(Object? json, String pointer) {
  if (json is String || json is Map || json is List) {
    return _jsonValue(json, pointer)!;
  }
  throw SystemOneFormatException(
    pointer,
    'expected a string, object, or array',
  );
}

Object? _optionalStructured(Object? json, String pointer) =>
    json == null ? null : _structured(json, pointer);

Object? _jsonValue(Object? json, String pointer) =>
    _copyJson(json, pointer, Set.identity());

/// Copies [json], rejecting containers already open on the current path.
Object? _copyJson(Object? json, String pointer, Set<Object> open) {
  if (json == null || json is String || json is bool) {
    return json;
  }
  if (json is num) {
    return _number(json, pointer);
  }
  if (json is! List && json is! Map) {
    throw SystemOneFormatException(pointer, 'expected a JSON value');
  }
  if (!open.add(json)) {
    throw SystemOneFormatException(pointer, 'expected an acyclic value');
  }
  try {
    if (json is List) {
      return List<Object?>.unmodifiable([
        for (final (index, item) in json.indexed)
          _copyJson(item, '$pointer/$index', open),
      ]);
    }
    return Map<String, Object?>.unmodifiable({
      for (final MapEntry(:key, :value) in _map(json, pointer).entries)
        key: _copyJson(value, _child(pointer, key), open),
    });
  } finally {
    open.remove(json);
  }
}

String _child(String pointer, String key) =>
    '$pointer/${key.replaceAll('~', '~0').replaceAll('/', '~1')}';
