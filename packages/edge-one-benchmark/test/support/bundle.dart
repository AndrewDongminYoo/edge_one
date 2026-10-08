import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';
import 'package:edge_one_calibrate/edge_one_calibrate.dart';

const modelHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const origin =
    'synthetic represented dataset shapes; not Banking77/KLUE/NSMC/model measurements';
String lines(Iterable<Object?> rows) => '${rows.map(jsonEncode).join('\n')}\n';
String hashText(String value) => sha256.convert(utf8.encode(value)).toString();
Map<String, Object?> request(String state) => {
  'state': state,
  'model': 'fixture',
  'questions': {
    'positive': {'type': 'noul', 'instructions': 'Positive?'},
  },
};
Map<String, Object?> response(double p, {String model = 'fixture'}) => {
  'model': model,
  'answers': {
    'positive': {'type': 'noul', 'noul': p},
  },
  'usage': {'input_tokens': 1, 'output_tokens': 1},
};
String requestHash(Map<String, Object?> request) =>
    RecordingBackend.requestSha256(SystemOneJson.decodeRequest(request));
Map<String, Object?> exchange(
  Map<String, Object?> req,
  String backend,
  Object? body, {
  int status = 200,
  int elapsed = 2,
  int cost = 3,
  String? error,
}) => {
  'version': 1,
  'backend_id': backend,
  'request_sha256': requestHash(req),
  'request': req,
  'status_code': status,
  'body': body,
  'error_code': error,
  'elapsed_us': elapsed,
  'reserved_microcredits': backend == 'local' ? 0 : cost,
};
Map<String, String> smallFiles() {
  final req = request('synthetic evaluation');
  final calibration = lines([
    for (var i = 0; i < 4; i++)
      {
        'version': 1,
        'request_sha256': requestHash(request('synthetic calibration $i')),
        'model_sha256': modelHash,
        'request': request('synthetic calibration $i'),
        'response': response(i.isEven ? .875 : .125),
        'labels': {'positive': i.isEven},
      },
  ]);
  final dataset = CalibrationDataset.parse(calibration, modelSha256: modelHash);
  final gates = {
    'version': 1,
    'seed': 0,
    'profiles': [
      for (final target in [.01, .05, .1])
        fitCalibration(dataset, targetError: target).profile.toJson(),
    ],
  };
  final files = <String, String>{
    'requests.jsonl': lines([req]),
    'cases.jsonl': lines([
      {
        'version': 1,
        'case_id': 'nsmc:one',
        'request_sha256': requestHash(req),
        'dataset_id': 'nsmc',
        'source_split': 'synthetic',
        'partition': 'evaluation',
        'labels': {'positive': true},
      },
    ]),
    'backend_fixtures.jsonl': lines([
      exchange(req, 'local', response(1)),
      exchange(
        {...req, 'state': '[masked]'},
        'remote',
        response(.8, model: 'remote-id'),
      ),
    ]),
    'calibration.jsonl': calibration,
    'gates.json': jsonEncode(gates),
  };
  files['suite.json'] = jsonEncode({
    'version': 1,
    'origin': origin,
    'rights': 'invented fixtures only; no external dataset rights claimed',
    'provenance': {
      'repository_revision': 'fixture-build',
      'dirty': false,
      'platform': 'synthetic-linux',
      'architecture': 'synthetic',
      'toolchain': 'synthetic',
      'local_model_sha256': modelHash,
      'manifest_sha256': null,
      'core_revision': null,
      'llama_revision': null,
      'render_version': null,
      'readout_version': null,
      'temperature': null,
      'remote_model_revision': null,
    },
    'runs': [
      for (final mode in ['local', 'remote', 'hybrid'])
        {
          'id': mode,
          'mode': mode,
          'condition': 'fixture',
          'trial_count': 1,
          'quality_trial': 0,
          'consent': true,
          'network_available': true,
          'budget_microcredits': 1000,
        },
    ],
    'files': {
      for (final entry in files.entries) entry.key: hashText(entry.value),
    },
  });
  return files;
}

void replaceFile(Map<String, String> files, String name, String value) {
  files[name] = value;
  final suite = jsonDecode(files['suite.json']!) as Map<String, dynamic>;
  (suite['files'] as Map)[name] = hashText(value);
  files['suite.json'] = jsonEncode(suite);
}

void rebuildGates(Map<String, String> files) {
  final dataset = CalibrationDataset.parse(
    files['calibration.jsonl']!,
    modelSha256: modelHash,
  );
  replaceFile(
    files,
    'gates.json',
    jsonEncode({
      'version': 1,
      'seed': 0,
      'profiles': [
        for (final target in [.01, .05, .1])
          fitCalibration(dataset, targetError: target).profile.toJson(),
      ],
    }),
  );
}

void changeRuns(
  Map<String, String> files,
  void Function(Map<String, dynamic>) change,
) {
  final suite = jsonDecode(files['suite.json']!) as Map<String, dynamic>;
  for (final run in suite['runs'] as List) {
    change(run as Map<String, dynamic>);
  }
  files['suite.json'] = jsonEncode(suite);
}
