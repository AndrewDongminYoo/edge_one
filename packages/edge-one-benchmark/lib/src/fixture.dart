import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';
import 'package:edge_one_calibrate/edge_one_calibrate.dart';
import 'case.dart';
import 'metrics.dart';

const syntheticOrigin =
    'synthetic represented dataset shapes; not Banking77/KLUE/NSMC/model measurements';
const fixtureFiles = {
  'requests.jsonl',
  'cases.jsonl',
  'backend_fixtures.jsonl',
  'calibration.jsonl',
  'gates.json',
};
String textSha256(String text) => sha256.convert(utf8.encode(text)).toString();
Map<String, Object?> exactObject(Object? value, Set<String> keys) {
  final map = jsonObject(value);
  if (map.length != keys.length || !keys.every(map.containsKey))
    throw FormatException('expected exactly ${keys.join(', ')}');
  return map;
}

List<Map<String, Object?>> jsonLines(String value) => [
  for (final line in const LineSplitter().convert(value))
    if (line.trim().isNotEmpty) jsonObject(jsonDecode(line)),
];
Object? freezeJson(Object? value) => switch (value) {
  num() when !value.isFinite => throw const FormatException(
    'nonfinite JSON number',
  ),
  Map<String, Object?>() => Map<String, Object?>.unmodifiable(
    value.map((k, v) => MapEntry(k, freezeJson(v))),
  ),
  List() => List<Object?>.unmodifiable(value.map(freezeJson)),
  _ => value,
};
int nonnegativeInt(Object? value) {
  if (value is! int || value < 0 || value > 9007199254740991)
    throw const FormatException('expected nonnegative safe integer');
  return value;
}

final class BenchmarkRun {
  BenchmarkRun._(
    this.id,
    this.mode,
    this.condition,
    this.trialCount,
    this.qualityTrial,
    this.consent,
    this.networkAvailable,
    this.budgetMicrocredits,
  );
  final String id, mode, condition;
  final int trialCount, qualityTrial, budgetMicrocredits;
  final bool consent, networkAvailable;
  factory BenchmarkRun.parse(Object? value) {
    final map = exactObject(value, {
      'id',
      'mode',
      'condition',
      'trial_count',
      'quality_trial',
      'consent',
      'network_available',
      'budget_microcredits',
    });
    final id = requiredText(map['id']);
    final mode = requiredText(map['mode']);
    if (!{'local', 'remote', 'hybrid'}.contains(mode) ||
        map['condition'] != 'fixture')
      throw const FormatException('v1 supports only synthetic fixture modes');
    final trials = nonnegativeInt(map['trial_count']);
    final quality = nonnegativeInt(map['quality_trial']);
    if (trials == 0 ||
        quality >= trials ||
        map['consent'] is! bool ||
        map['network_available'] is! bool)
      throw const FormatException('invalid run');
    return BenchmarkRun._(
      id,
      mode,
      'fixture',
      trials,
      quality,
      map['consent'] as bool,
      map['network_available'] as bool,
      nonnegativeInt(map['budget_microcredits']),
    );
  }
}

final class BackendExchange {
  BackendExchange._(this.json, this.request);
  final Map<String, Object?> json;
  final SystemOneRequest request;
  String get backend => json['backend_id'] as String;
  String get digest => json['request_sha256'] as String;
  int get status => json['status_code'] as int;
  Object? get body => json['body'];
  String? get error => json['error_code'] as String?;
  int? get elapsedUs => json['elapsed_us'] as int?;
  int get cost => json['reserved_microcredits'] as int;
  factory BackendExchange.parse(Object? value) {
    final map = exactObject(value, {
      'version',
      'backend_id',
      'request_sha256',
      'request',
      'status_code',
      'body',
      'error_code',
      'elapsed_us',
      'reserved_microcredits',
    });
    if (map['version'] != 1 || !{'local', 'remote'}.contains(map['backend_id']))
      throw const FormatException('invalid exchange version/backend');
    final request = SystemOneJson.decodeRequest(map['request']);
    if (RecordingBackend.requestSha256(request) != map['request_sha256'])
      throw const FormatException('exchange request digest mismatch');
    final status = nonnegativeInt(map['status_code']);
    if (status < 100 || status > 599)
      throw const FormatException('invalid status');
    if (map['error_code'] != null) requiredText(map['error_code']);
    if (map['elapsed_us'] != null) nonnegativeInt(map['elapsed_us']);
    final cost = nonnegativeInt(map['reserved_microcredits']);
    if (map['backend_id'] == 'local' && cost != 0)
      throw const FormatException('local exchange cannot reserve remote cost');
    if (map['backend_id'] == 'local' && map['error_code'] == null) {
      if (status != 200)
        throw const FormatException('local failure requires error_code');
      SystemOneJson.checkAnswers(
        request.questions,
        SystemOneJson.decodeResponse(map['body']),
      );
    }
    return BackendExchange._(freezeJson(map) as Map<String, Object?>, request);
  }
}

final class BenchmarkBundle {
  BenchmarkBundle._(
    this.suite,
    this.cases,
    this.runs,
    this.exchanges,
    this.profiles,
    this.scoreLegends,
  );
  final Map<String, Object?> suite;
  final List<BenchmarkCase> cases;
  final List<BenchmarkRun> runs;
  final Map<String, BackendExchange> exchanges;
  final Map<double, CalibrationProfile> profiles;
  final Map<String, String> scoreLegends;
  String get modelSha256 =>
      (suite['provenance'] as Map)['local_model_sha256'] as String;
}

BenchmarkBundle parseBenchmarkBundle(Map<String, String> files) {
  if (files.length != fixtureFiles.length + 1 ||
      !{...fixtureFiles, 'suite.json'}.every(files.containsKey))
    throw const FormatException('expected the six fixed fixture files');
  final suite = exactObject(jsonDecode(files['suite.json']!), {
    'version',
    'origin',
    'rights',
    'provenance',
    'runs',
    'files',
  });
  if (suite['version'] != 1 ||
      suite['origin'] != syntheticOrigin ||
      suite['rights'] !=
          'invented fixtures only; no external dataset rights claimed')
    throw const FormatException(
      'only version 1 invented synthetic fixtures are accepted',
    );
  final identities = exactObject(suite['files'], fixtureFiles);
  for (final name in fixtureFiles) {
    if (identities[name] != textSha256(files[name]!))
      throw FormatException('file digest mismatch: $name');
  }
  final provenance = exactObject(suite['provenance'], {
    'repository_revision',
    'dirty',
    'platform',
    'architecture',
    'toolchain',
    'local_model_sha256',
    'manifest_sha256',
    'core_revision',
    'llama_revision',
    'render_version',
    'readout_version',
    'temperature',
    'remote_model_revision',
  });
  for (final key in [
    'repository_revision',
    'platform',
    'architecture',
    'toolchain',
  ]) {
    requiredText(provenance[key]);
  }
  if (provenance['dirty'] is! bool)
    throw const FormatException('dirty must be boolean');
  final modelHash = checkHash(
    provenance['local_model_sha256'],
    'local_model_sha256',
  );
  if (provenance['manifest_sha256'] != null)
    checkHash(provenance['manifest_sha256'], 'manifest_sha256');
  for (final key in [
    'core_revision',
    'llama_revision',
    'render_version',
    'readout_version',
    'remote_model_revision',
  ]) {
    if (provenance[key] != null) requiredText(provenance[key]);
  }
  final temperature = provenance['temperature'];
  if (temperature != null &&
      (temperature is! num || !temperature.isFinite || temperature <= 0))
    throw const FormatException(
      'temperature must be null or finite and positive',
    );
  final definitions = <String, String>{};
  final legends = <String, String>{};
  void definitionsFor(SystemOneRequest request) {
    final questions = SystemOneJson.encodeRequest(request)['questions'] as Map;
    for (final key in request.questions.keys) {
      final definition = canonicalJson(questions[key]);
      if (definitions.putIfAbsent(key, () => definition) != definition)
        throw FormatException('question $key changes definition');
    }
  }

  void legendsFor(SystemOneResponse response) {
    for (final entry in response.answers.entries) {
      if (entry.value case final ScoreAnswer answer) {
        final legend = canonicalJson(answer.legend);
        if (legends.putIfAbsent(entry.key, () => legend) != legend)
          throw FormatException('score ${entry.key} changes legend meanings');
      }
    }
  }

  final calibrationRows = jsonLines(files['calibration.jsonl']!);
  final calibrationDigests = <String>{};
  final calibrationRequests = <String>{};
  for (final row in calibrationRows) {
    final request = SystemOneJson.decodeRequest(row['request']);
    final digest = RecordingBackend.requestSha256(request);
    if (digest != row['request_sha256'])
      throw const FormatException('calibration request digest mismatch');
    calibrationDigests.add(digest);
    calibrationRequests.add(
      canonicalJson(SystemOneJson.encodeRequest(request)),
    );
    definitionsFor(request);
    legendsFor(SystemOneJson.decodeResponse(row['response']));
  }
  final calibration = CalibrationDataset.parse(
    files['calibration.jsonl']!,
    modelSha256: modelHash,
  );
  final gateFile = exactObject(jsonDecode(files['gates.json']!), {
    'version',
    'seed',
    'profiles',
  });
  if (gateFile['version'] != 1 ||
      gateFile['seed'] is! int ||
      gateFile['profiles'] is! List ||
      (gateFile['profiles'] as List).length != 3)
    throw const FormatException('invalid fixed gate file');
  final profiles = <double, CalibrationProfile>{};
  for (final json in gateFile['profiles'] as List) {
    final profile = CalibrationProfile.fromJson(json);
    if (!{.01, .05, .1}.contains(profile.targetError) ||
        profiles.containsKey(profile.targetError))
      throw const FormatException('expected unique 1/5/10 percent gates');
    final fitted = fitCalibration(
      calibration,
      seed: gateFile['seed'] as int,
      targetError: profile.targetError,
    );
    if (canonicalJson(profile.toJson()) !=
        canonicalJson(fitted.profile.toJson()))
      throw const FormatException('gate does not match calibration-only input');
    profiles[profile.targetError] = profile;
  }
  final requests = <String, SystemOneRequest>{};
  final canonicalRequests = <String>{};
  for (final row in jsonLines(files['requests.jsonl']!)) {
    final request = SystemOneJson.decodeRequest(row);
    final digest = RecordingBackend.requestSha256(request);
    final canonical = canonicalJson(SystemOneJson.encodeRequest(request));
    if (requests.containsKey(digest) ||
        !canonicalRequests.add(canonical) ||
        calibrationDigests.contains(digest) ||
        calibrationRequests.contains(canonical))
      throw const FormatException(
        'duplicate or overlapping evaluation request',
      );
    definitionsFor(request);
    requests[digest] = request;
  }
  final cases = <BenchmarkCase>[];
  final caseIds = <String>{}, caseDigests = <String>{};
  for (final row in jsonLines(files['cases.jsonl']!)) {
    exactObject(row, {
      'version',
      'case_id',
      'request_sha256',
      'dataset_id',
      'source_split',
      'partition',
      'labels',
    });
    final digest = requiredText(row['request_sha256']);
    final id = requiredText(row['case_id']);
    if (row['version'] != 1 ||
        !caseIds.add(id) ||
        !caseDigests.add(digest) ||
        !requests.containsKey(digest) ||
        row['partition'] != 'evaluation' ||
        row['source_split'] != 'synthetic' ||
        !{
          'banking77',
          'klueYnat',
          'klueNli',
          'nsmc',
          'tickets',
        }.contains(row['dataset_id']))
      throw const FormatException('invalid/reused case identity');
    cases.add(
      BenchmarkCase(
        id: id,
        datasetId: row['dataset_id'] as String,
        request: requests[digest]!,
        labels: jsonObject(row['labels']),
        sourceSplit: 'synthetic',
        partition: 'evaluation',
      ),
    );
  }
  if (cases.isEmpty || caseDigests.length != requests.length)
    throw const FormatException('cases must cover every request exactly once');
  final exchanges = <String, BackendExchange>{};
  for (final row in jsonLines(files['backend_fixtures.jsonl']!)) {
    final exchange = BackendExchange.parse(row);
    final key = '${exchange.backend}:${exchange.digest}';
    if (exchanges.containsKey(key))
      throw const FormatException('duplicate exchange');
    definitionsFor(exchange.request);
    if (exchange.status >= 200 &&
        exchange.status < 300 &&
        exchange.error == null) {
      // Remote invalid bodies are legitimate failure fixtures. Valid bodies
      // must nevertheless keep Score label meanings consistent across sources.
      SystemOneResponse? response;
      try {
        final decoded = SystemOneJson.decodeResponse(exchange.body);
        SystemOneJson.checkAnswers(exchange.request.questions, decoded);
        response = decoded;
      } on FormatException {
        /* retained as remote invalid-response evidence */
      }
      if (response != null) {
        legendsFor(response);
      }
    }
    exchanges[key] = exchange;
  }
  if (suite['runs'] is! List)
    throw const FormatException('runs must be a list');
  final runs = (suite['runs'] as List).map(BenchmarkRun.parse).toList();
  if (runs.isEmpty || runs.map((r) => r.id).toSet().length != runs.length)
    throw const FormatException('runs must have unique ids');
  return BenchmarkBundle._(
    freezeJson(suite) as Map<String, Object?>,
    List.unmodifiable(cases),
    List.unmodifiable(runs),
    Map.unmodifiable(exchanges),
    Map.unmodifiable(profiles),
    Map.unmodifiable(legends),
  );
}

/// One complete request outcome. Raw backend bodies remain separate from the
/// four-field, validated recording of the final answer.
final class BenchmarkCapture {
  BenchmarkCapture({
    required this.runId,
    required this.caseId,
    required this.requestSha256,
    required this.trial,
    required this.outcome,
    this.response,
    this.errorCode,
    this.failureOrigin,
    required List<BackendExchange> exchanges,
  }) : exchanges = List.unmodifiable(exchanges);
  final String runId, caseId, requestSha256, outcome;
  final int trial;
  final SystemOneResponse? response;
  final String? errorCode, failureOrigin;
  final List<BackendExchange> exchanges;
  int? get elapsedUs =>
      exchanges.isEmpty || exchanges.any((e) => e.elapsedUs == null)
      ? null
      : exchanges.fold(0, (sum, e) => sum! + e.elapsedUs!);
  Map<String, Object?> toJson(BenchmarkCase source) => {
    'version': 1,
    'run_id': runId,
    'case_id': caseId,
    'request_sha256': requestSha256,
    'trial': trial,
    'outcome': outcome,
    'recording': response == null
        ? null
        : {
            'version': 1,
            'request_sha256': requestSha256,
            'request': SystemOneJson.encodeRequest(source.request),
            'response': SystemOneJson.encodeResponse(response!),
          },
    'error_code': errorCode,
    'failure_origin': failureOrigin,
    'elapsed_us': elapsedUs,
    'exchanges': [
      for (final exchange in exchanges)
        {
          'scope': exchange.backend == 'remote'
              ? 'decoded_transport_body'
              : 'decoded_backend_response',
          ...exchange.json,
        },
    ],
  };
}

void validateCaptures(BenchmarkBundle bundle, List<BenchmarkCapture> captures) {
  final expected = {
    for (final run in bundle.runs)
      for (final source in bundle.cases)
        for (var trial = 0; trial < run.trialCount; trial++)
          (run.id, source.id, trial): source,
  };
  for (final capture in captures) {
    final source = expected.remove((
      capture.runId,
      capture.caseId,
      capture.trial,
    ));
    if (source == null || source.requestSha256 != capture.requestSha256)
      throw const FormatException('duplicate, extra or mismatched capture');
    if (capture.failureOrigin != null &&
        !{
          'local',
          'remote',
          'response_validation',
        }.contains(capture.failureOrigin))
      throw const FormatException('invalid failure origin');
    if (!{'answered', 'unsupported', 'error'}.contains(capture.outcome))
      throw const FormatException('unknown outcome');
    if (capture.outcome == 'answered') {
      if (capture.response == null ||
          capture.errorCode != null ||
          capture.failureOrigin != null)
        throw const FormatException('answered requires response only');
      final response = SystemOneJson.decodeResponse(
        SystemOneJson.encodeResponse(capture.response!),
      );
      SystemOneJson.checkAnswers(source.request.questions, response);
      validateBenchmarkAnswerSemantics(bundle, source.labels, response);
    } else {
      if (capture.response != null)
        throw const FormatException(
          'failed capture cannot include partial response',
        );
      requiredText(capture.errorCode);
    }
    for (final exchange in capture.exchanges) {
      final original =
          bundle.exchanges['${exchange.backend}:${exchange.digest}'];
      if (original == null ||
          canonicalJson(original.json) != canonicalJson(exchange.json))
        throw const FormatException('capture exchange not in fixture');
    }
  }
  if (expected.isNotEmpty) throw const FormatException('missing captures');
}

final class BenchmarkAnswerException extends FormatException {
  const BenchmarkAnswerException(String message) : super(message);
}

void validateBenchmarkAnswerSemantics(
  BenchmarkBundle bundle,
  Map<String, Object?> labels,
  SystemOneResponse response,
) {
  try {
    for (final entry in response.answers.entries) {
      CategoricalObservation.fromAnswer(entry.value, labels[entry.key]);
      if (entry.value case final ScoreAnswer answer) {
        if (bundle.scoreLegends[entry.key] != canonicalJson(answer.legend))
          throw const FormatException('capture changes score legend');
      }
    }
  } on FormatException catch (error) {
    throw BenchmarkAnswerException(error.message);
  }
}
