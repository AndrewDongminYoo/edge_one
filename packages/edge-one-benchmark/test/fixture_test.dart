import 'dart:convert';
import 'package:edge_one_benchmark/edge_one_benchmark.dart';
import 'package:test/test.dart';
import 'support/bundle.dart';

void main() {
  test(
    'strict bundle accepts synthetic files and fixed separately fitted gates',
    () {
      final bundle = parseBenchmarkBundle(smallFiles());
      expect(bundle.cases.single.id, 'nsmc:one');
      expect(bundle.runs.length, 3);
      expect(bundle.profiles.keys, [.01, .05, .1]);
    },
  );
  test('capture grid identities cannot collide at colon boundaries', () {
    final files = smallFiles();
    final first = request('one'), second = request('two');
    replaceFile(files, 'requests.jsonl', lines([first, second]));
    replaceFile(
      files,
      'cases.jsonl',
      lines([
        for (final pair in [('c', first), ('b:c', second)])
          {
            'version': 1,
            'case_id': pair.$1,
            'request_sha256': requestHash(pair.$2),
            'dataset_id': 'nsmc',
            'source_split': 'synthetic',
            'partition': 'evaluation',
            'labels': {'positive': true},
          },
      ]),
    );
    final suite = jsonDecode(files['suite.json']!) as Map<String, dynamic>;
    final run = (suite['runs'] as List).first as Map;
    suite['runs'] = [
      {...run, 'id': 'a:b'},
      {...run, 'id': 'a'},
    ];
    files['suite.json'] = jsonEncode(suite);
    final bundle = parseBenchmarkBundle(files);
    final captures = [
      for (final run in bundle.runs)
        for (final source in bundle.cases)
          if (!(run.id == 'a:b' && source.id == 'c'))
            BenchmarkCapture(
              runId: run.id,
              caseId: source.id,
              requestSha256: source.requestSha256,
              trial: 0,
              outcome: 'error',
              errorCode: 'fixture',
              exchanges: [],
            ),
    ];
    expect(() => validateCaptures(bundle, captures), throwsFormatException);
  });
  test(
    'nullable provenance types and nonfinite raw bodies fail at preflight',
    () {
      for (final pair in [
        ('temperature', -1),
        ('manifest_sha256', 'bad'),
        ('core_revision', 8),
      ]) {
        final files = smallFiles();
        final suite = jsonDecode(files['suite.json']!) as Map<String, dynamic>;
        (suite['provenance'] as Map)[pair.$1] = pair.$2;
        files['suite.json'] = jsonEncode(suite);
        expect(() => parseBenchmarkBundle(files), throwsFormatException);
      }
      final provenance = smallFiles();
      provenance['suite.json'] = provenance['suite.json']!.replaceFirst(
        '"temperature":null',
        '"temperature":1e309',
      );
      expect(() => parseBenchmarkBundle(provenance), throwsFormatException);
      final body = smallFiles();
      replaceFile(
        body,
        'backend_fixtures.jsonl',
        body['backend_fixtures.jsonl']!.replaceFirst(
          '"noul":0.8',
          '"noul":1e309',
        ),
      );
      expect(() => parseBenchmarkBundle(body), throwsFormatException);
    },
  );
  test(
    'unknown versions, fields, external origin, file names and drift fail',
    () {
      for (final change in [
        (Map<String, dynamic> s) => s['version'] = 2,
        (Map<String, dynamic> s) => s['extra'] = true,
        (Map<String, dynamic> s) => s['origin'] = 'external',
        (Map<String, dynamic> s) =>
            (s['files'] as Map)['../requests.jsonl'] = 'a',
      ]) {
        final files = smallFiles();
        final suite = jsonDecode(files['suite.json']!) as Map<String, dynamic>;
        change(suite);
        files['suite.json'] = jsonEncode(suite);
        expect(() => parseBenchmarkBundle(files), throwsFormatException);
      }
      final files = smallFiles()..update('requests.jsonl', (s) => '$s\n');
      expect(() => parseBenchmarkBundle(files), throwsFormatException);
    },
  );
  test('reject duplicate exchanges before first-wins recording replay', () {
    final files = smallFiles();
    replaceFile(
      files,
      'backend_fixtures.jsonl',
      files['backend_fixtures.jsonl']! * 2,
    );
    expect(() => parseBenchmarkBundle(files), throwsFormatException);
  });
  test(
    'reject reused cases, request digests and malformed local answer pairing',
    () {
      for (final name in ['cases.jsonl', 'requests.jsonl']) {
        final files = smallFiles();
        replaceFile(files, name, files[name]! * 2);
        expect(() => parseBenchmarkBundle(files), throwsFormatException);
      }
      final files = smallFiles();
      final rows = const LineSplitter()
          .convert(files['backend_fixtures.jsonl']!)
          .map((s) => jsonDecode(s) as Map<String, dynamic>)
          .toList();
      (rows.first['body'] as Map)['answers'] = {};
      replaceFile(files, 'backend_fixtures.jsonl', lines(rows));
      expect(() => parseBenchmarkBundle(files), throwsFormatException);
    },
  );
  test(
    'calibration/evaluation overlap, changed definitions and altered gates fail',
    () {
      final overlap = smallFiles();
      final record =
          jsonDecode(
                const LineSplitter()
                    .convert(overlap['calibration.jsonl']!)
                    .first,
              )
              as Map<String, dynamic>;
      replaceFile(overlap, 'requests.jsonl', lines([record['request']]));
      final row = jsonDecode(overlap['cases.jsonl']!) as Map<String, dynamic>;
      row['request_sha256'] = record['request_sha256'];
      replaceFile(overlap, 'cases.jsonl', lines([row]));
      expect(() => parseBenchmarkBundle(overlap), throwsFormatException);
      final changed = smallFiles();
      final req = request('synthetic evaluation');
      ((req['questions'] as Map)['positive'] as Map)['instructions'] =
          'Different meaning?';
      replaceFile(changed, 'requests.jsonl', lines([req]));
      final changedCase =
          jsonDecode(changed['cases.jsonl']!) as Map<String, dynamic>;
      changedCase['request_sha256'] = requestHash(req);
      replaceFile(changed, 'cases.jsonl', lines([changedCase]));
      expect(() => parseBenchmarkBundle(changed), throwsFormatException);
      final altered = smallFiles();
      final gates = jsonDecode(altered['gates.json']!) as Map<String, dynamic>;
      ((gates['profiles'] as List).first['questions']['positive']
              as Map)['threshold'] =
          0;
      replaceFile(altered, 'gates.json', jsonEncode(gates));
      expect(() => parseBenchmarkBundle(altered), throwsFormatException);
    },
  );
}
