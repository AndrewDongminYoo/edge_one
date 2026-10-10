/// Explicit maintainer command. Tests/CI never rewrite expected artifacts.
import 'dart:convert';
import 'dart:io';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';
import 'package:edge_one_benchmark/edge_one_benchmark.dart';
import 'package:edge_one_calibrate/edge_one_calibrate.dart';

const _modelHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _encoder = JsonEncoder.withIndent('  ');
String _lines(Iterable<Object?> rows) => '${rows.map(jsonEncode).join('\n')}\n';

Future<void> main() async {
  final cases = [
    ...adaptRows(DatasetAdapter.banking77, [
      {
        'id': '1',
        'text': 'Invented banking request 001',
        'label': 'synthetic_intent_0',
      },
    ], intentNames: List.generate(77, (i) => 'synthetic_intent_$i')),
    ...adaptRows(DatasetAdapter.klueYnat, [
      {'id': '1', 'title': '가상 연구소가 상상의 장치를 발표했다', 'label': 0},
    ]),
    ...adaptRows(DatasetAdapter.klueNli, [
      {
        'id': '1',
        'premise': '가상의 로봇이 앉아 있다',
        'hypothesis': '로봇이 쉬고 있다',
        'label': 1,
      },
    ]),
    ...adaptRows(DatasetAdapter.nsmc, [
      for (var i = 0; i < 6; i++)
        {
          'id': '$i',
          'document': '완전히 창작한 영화 감상 예시 $i',
          'label': i == 1 ? 0 : 1,
        },
    ]),
    ...adaptRows(DatasetAdapter.tickets, [
      for (var i = 0; i < 2; i++)
        {
          'id': '$i',
          'state': {
            'ticket': 'Invented duplicate charge $i',
            'customer': 'synthetic',
          },
          'labels': {
            'ticket_topic': 'billing',
            'ticket_refund': true,
            'ticket_urgency': '1',
          },
        },
    ]),
  ];
  final questions = <String, SystemOneQuestion>{};
  final labels = <String, Object?>{};
  for (final source in cases.where((c) => c.datasetId != 'banking77')) {
    questions.addAll(source.request.questions);
    labels.addAll(source.labels);
  }
  final calibration = _lines([
    for (var i = 0; i < 4; i++)
      () {
        final request = SystemOneRequest(
          state: 'Entirely synthetic calibration-only $i',
          model: 'benchmark-fixture',
          questions: questions,
        );
        return {
          'version': 1,
          'request_sha256': RecordingBackend.requestSha256(request),
          'model_sha256': _modelHash,
          'request': SystemOneJson.encodeRequest(request),
          'response': _body(
            request,
            labels,
            const {},
            defaultProbability: .875,
          ),
          'labels': labels,
        };
      }(),
  ]);
  final dataset = CalibrationDataset.parse(
    calibration,
    modelSha256: _modelHash,
  );
  final gates = {
    'version': 1,
    'seed': 0,
    'profiles': [
      for (final target in [.01, .05, .1])
        fitCalibration(dataset, targetError: target).profile.toJson(),
    ],
  };
  final exchanges = <Map<String, Object?>>[];
  void add(
    SystemOneRequest request,
    String backend,
    Object? body, {
    String? error,
    int status = 200,
    int elapsed = 2,
  }) {
    final row = {
      'version': 1,
      'backend_id': backend,
      'request_sha256': RecordingBackend.requestSha256(request),
      'request': SystemOneJson.encodeRequest(request),
      'status_code': status,
      'body': body,
      'error_code': error,
      'elapsed_us': elapsed,
      'reserved_microcredits': backend == 'remote' ? 3 : 0,
    };
    final matching = exchanges.where(
      (e) =>
          e['backend_id'] == backend &&
          e['request_sha256'] == row['request_sha256'],
    );
    if (matching.isEmpty) {
      exchanges.add(row);
    } else if (canonicalJson(matching.single) != canonicalJson(row)) {
      throw StateError(
        'conflicting authored exchange for exact masked request',
      );
    }
  }

  for (final source in cases) {
    final request = source.request;
    final overrides = <String, double>{};
    String? localError;
    if (source.datasetId == 'nsmc') {
      final index = int.parse(source.id.split(':').last);
      if (index < 4) overrides['positive'] = [.9, .7, .6, .8][index];
      if (index >= 4)
        localError = index == 4 ? 'unsupported' : 'fixtureFailure';
    }
    if (source.datasetId == 'klueNli') overrides['nli_relation'] = .5;
    if (source.datasetId == 'tickets') overrides['ticket_refund'] = .5;
    final localBody = _body(request, source.labels, overrides);
    if (source.datasetId != 'banking77')
      add(
        request,
        'local',
        localError == null ? localBody : null,
        error: localError,
        elapsed: source.datasetId == 'nsmc'
            ? [1, 2, 3, 100, 5, 6][int.parse(source.id.split(':').last)]
            : 2,
      );
    final masked = SystemOneRequest(
      state: '[masked]',
      model: request.model,
      questions: request.questions,
    );
    final failedRemote = source.datasetId == 'tickets';
    add(
      masked,
      'remote',
      failedRemote
          ? {'error': 'synthetic overload'}
          : _body(
              masked,
              {...source.labels, 'positive': true},
              const {},
              model: 'synthetic-remote-id',
            ),
      status: failedRemote ? 529 : 200,
      elapsed: 10,
    );
    if (source.datasetId == 'tickets') {
      final subset = SystemOneRequest(
        state: '[masked]',
        model: request.model,
        questions: {'ticket_refund': request.questions['ticket_refund']!},
      );
      add(
        subset,
        'remote',
        failedRemote
            ? {'error': 'synthetic overload'}
            : _body(
                subset,
                {...source.labels, 'positive': true},
                const {},
                model: 'synthetic-remote-id',
              ),
        status: failedRemote ? 529 : 200,
        elapsed: 10,
      );
    }
  }
  final files = <String, String>{
    'requests.jsonl': _lines(
      cases.map((c) => SystemOneJson.encodeRequest(c.request)),
    ),
    'cases.jsonl': _lines([
      for (final c in cases)
        {
          'version': 1,
          'case_id': c.id,
          'request_sha256': c.requestSha256,
          'dataset_id': c.datasetId,
          'source_split': c.sourceSplit,
          'partition': c.partition,
          'labels': c.labels,
        },
    ]),
    'backend_fixtures.jsonl': _lines(exchanges),
    'calibration.jsonl': calibration,
    'gates.json': '${_encoder.convert(gates)}\n',
  };
  files['suite.json'] =
      '${_encoder.convert({
        'version': 1,
        'origin': syntheticOrigin,
        'rights': 'invented fixtures only; no external dataset rights claimed',
        'provenance': {'repository_revision': 'f3e01e3505e79997d3e1599be8b4be1990fa9624', 'dirty': true, 'platform': 'synthetic-linux-fixture', 'architecture': 'unmeasured', 'toolchain': 'Dart fixture authoring; no native execution', 'local_model_sha256': _modelHash, 'manifest_sha256': null, 'core_revision': '58526f3', 'llama_revision': null, 'render_version': null, 'readout_version': null, 'temperature': null, 'remote_model_revision': null},
        'runs': [
          for (final mode in ['local', 'remote', 'hybrid', 'hybrid-denied']) {'id': mode, 'mode': mode == 'hybrid-denied' ? 'hybrid' : mode, 'condition': 'fixture', 'trial_count': 1, 'quality_trial': 0, 'consent': mode != 'hybrid-denied', 'network_available': true, 'budget_microcredits': 1000},
        ],
        'files': {for (final entry in files.entries) entry.key: textSha256(entry.value)},
      })}\n';
  final directory = Directory('test/fixtures/v1');
  directory.createSync(recursive: true);
  final bundle = parseBenchmarkBundle(files);
  final report = benchmarkReport(bundle, await replayBenchmark(bundle));
  for (final entry in files.entries) {
    File('${directory.path}/${entry.key}').writeAsStringSync(entry.value);
  }
  File(
    '${directory.path}/expected-report.json',
  ).writeAsStringSync('${_encoder.convert(report)}\n');
  stdout.writeln(
    'Wrote ${cases.length} invented cases and ${bundle.runs.length} fixture runs.',
  );
}

Map<String, Object?> _body(
  SystemOneRequest request,
  Map<String, Object?> labels,
  Map<String, double> overrides, {
  double defaultProbability = 1,
  String? model,
}) {
  final answers = <String, SystemOneAnswer>{};
  for (final entry in request.questions.entries) {
    final key = entry.key, label = labels[entry.key];
    final p = overrides[key] ?? defaultProbability;
    switch (entry.value) {
      case NoulQuestion():
        answers[key] = NoulAnswer(
          noul: overrides.containsKey(key) ? p : (label == true ? p : 1 - p),
        );
      case ChoiceQuestion(:final criteria):
        final names = criteria.keys.toList();
        final probabilities = {
          for (final name in names)
            name: name == label ? p : (1 - p) / (names.length - 1),
        };
        answers[key] = ChoiceAnswer(
          choice: label as String,
          probabilities: probabilities,
          confidence: distributionConfidence(probabilities.values),
        );
      case ScoreQuestion(:final criteria):
        final probabilities = {
          for (var i = 0; i < criteria.length; i++)
            '$i': '$i' == label ? p : (1 - p) / (criteria.length - 1),
        };
        answers[key] = ScoreAnswer(
          score: 1,
          legend: {for (var i = 0; i < criteria.length; i++) '$i': criteria[i]},
          probabilities: probabilities,
          confidence: distributionConfidence(probabilities.values),
        );
    }
  }
  return SystemOneJson.encodeResponse(
    SystemOneResponse(
      model: model ?? request.model,
      answers: answers,
      usage: const Usage(inputTokens: 1, outputTokens: 1),
      xEngine: model == null
          ? {'id': 'synthetic-local', 'revision': 'fixture-v1'}
          : null,
    ),
  );
}
