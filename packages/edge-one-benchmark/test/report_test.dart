import 'dart:convert';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one_benchmark/edge_one_benchmark.dart';
import 'package:test/test.dart';
import 'support/bundle.dart';

void main() {
  test(
    'complete denominators, repeated latency/cost and quality sampled once',
    () async {
      final files = smallFiles();
      final requests = [
        for (var i = 0; i < 6; i++) request('synthetic evaluation $i'),
      ];
      replaceFile(files, 'requests.jsonl', lines(requests));
      replaceFile(
        files,
        'cases.jsonl',
        lines([
          for (var i = 0; i < 6; i++)
            {
              'version': 1,
              'case_id': 'nsmc:$i',
              'request_sha256': requestHash(requests[i]),
              'dataset_id': 'nsmc',
              'source_split': 'synthetic',
              'partition': 'evaluation',
              'labels': {'positive': i != 1},
            },
        ]),
      );
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          for (var i = 0; i < 6; i++)
            exchange(
              requests[i],
              'local',
              i < 4 ? response([.9, .7, .6, .8][i]) : null,
              error: i == 4
                  ? 'unsupported'
                  : (i == 5 ? 'fixtureFailure' : null),
              elapsed: [1, 2, 3, 100, 5, 6][i],
            ),
        ]),
      );
      changeRuns(files, (r) => r['trial_count'] = 2);
      final bundle = parseBenchmarkBundle(files);
      final captures = await replayBenchmark(bundle);
      final report = benchmarkReport(bundle, captures);
      final group = (report['groups'] as List).first as Map;
      expect(group['request_counts'], {
        'attempted': 6,
        'answered': 4,
        'unsupported': 1,
        'error': 1,
      });
      expect(group['trial_requests'], 12);
      final question = (group['questions'] as List).single as Map;
      expect(question['attempted'], 6);
      expect(question['answered'], 4);
      expect(question['unsupported'], 1);
      expect(question['error'], 1);
      expect(question['accuracy'], .75);
      expect(question['completion_rate'], 4 / 6);
      expect(question['end_to_end_success_rate'], .5);
      expect(question['ece10'], closeTo(.35, 1e-12));
      expect((group['latency'] as Map)['answered'], containsPair('samples', 8));
      expect((group['latency'] as Map)['answered'], containsPair('p50_us', 2));
      expect(
        (group['latency'] as Map)['answered'],
        containsPair('p95_us', 100),
      );
      expect(
        () => benchmarkReport(bundle, captures.sublist(1)),
        throwsFormatException,
      );
      expect(
        () => benchmarkReport(bundle, [...captures, captures.first]),
        throwsFormatException,
      );
    },
  );
  test(
    'local fixed gates accept; direct remote gates are unavailable, fallback is not accepted',
    () async {
      final files = smallFiles();
      var bundle = parseBenchmarkBundle(files);
      var report = benchmarkReport(bundle, await replayBenchmark(bundle));
      final groups = report['groups'] as List;
      final localQuestion = (groups.first['questions'] as List).single as Map;
      expect(
        (localQuestion['local_gate_coverage'] as List).map(
          (g) => g['accepted'],
        ),
        [1, 1, 1],
      );
      expect(
        (groups[1]['questions'] as List).single['local_gate_coverage_reason'],
        'local_model_artifact_not_applicable',
      );
      expect(
        (groups[1]['questions'] as List).single['local_gate_coverage'],
        isNull,
      );
      final req = request('synthetic evaluation');
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([exchange(req, 'local', response(.5))]),
      );
      changeRuns(files, (r) => r['consent'] = false);
      bundle = parseBenchmarkBundle(files);
      report = benchmarkReport(bundle, await replayBenchmark(bundle));
      final hybrid = (report['groups'] as List).last as Map;
      expect(hybrid['routing'], containsPair('accepted_local', 0));
      expect(hybrid['routing'], containsPair('fallback_local', 1));
      expect(hybrid['routing'], containsPair('denied_escalations', 1));
      expect(
        ((hybrid['questions'] as List).single['local_gate_coverage'] as List)
            .map((g) => g['accepted']),
        [0, 0, 0],
      );
    },
  );
  test(
    'all-error report preserves raw failures and unit-tagged reservation cost',
    () async {
      final files = smallFiles();
      final req = request('synthetic evaluation');
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          exchange(req, 'local', null, error: 'fixtureFailure'),
          exchange(
            {...req, 'state': '[masked]'},
            'remote',
            {'message': 'synthetic'},
            status: 529,
            cost: 3,
          ),
        ]),
      );
      final bundle = parseBenchmarkBundle(files);
      final report = benchmarkReport(bundle, await replayBenchmark(bundle));
      final remote = (report['groups'] as List)[1] as Map;
      expect((remote['questions'] as List).single['accuracy'], isNull);
      expect(remote['cost'], containsPair('reserved_microcredits', 3));
      expect(remote['cost'], containsPair('unit', 'application_microcredits'));
      expect(remote['cost'], containsPair('billing', isNull));
      expect(remote['cost'], containsPair('dispatches', 1));
      expect(jsonEncode(report), contains('decoded_transport_body'));
      expect(report['origin'], origin);
    },
  );
  test(
    'failed capture cannot smuggle a partial response into metrics',
    () async {
      final bundle = parseBenchmarkBundle(smallFiles());
      final captures = await replayBenchmark(bundle);
      final first = captures.first;
      final bad = BenchmarkCapture(
        runId: first.runId,
        caseId: first.caseId,
        requestSha256: first.requestSha256,
        trial: 0,
        outcome: 'error',
        response: SystemOneJson.decodeResponse(response(.8)),
        errorCode: 'bad',
        exchanges: [],
      );
      expect(
        () => benchmarkReport(bundle, [bad, ...captures.skip(1)]),
        throwsFormatException,
      );
    },
  );

  for (final denial in [false, true]) {
    test(
      'failed mixed forced request counts only escalated keys ($denial)',
      () async {
        final files = smallFiles();
        final localReq = request('synthetic evaluation');
        final forced = {
          'type': 'choice',
          'criteria': {for (var i = 0; i < 77; i++) 'intent$i': null},
        };
        final req = {
          ...localReq,
          'questions': {
            ...(localReq['questions'] as Map<String, Object?>),
            'banking_intent': forced,
          },
        };
        replaceFile(files, 'requests.jsonl', lines([req]));
        final row = jsonDecode(files['cases.jsonl']!) as Map<String, dynamic>;
        row['request_sha256'] = requestHash(req);
        (row['labels'] as Map)['banking_intent'] = 'intent0';
        replaceFile(files, 'cases.jsonl', lines([row]));
        final remoteSubset = {
          'model': 'fixture',
          'state': '[masked]',
          'questions': {'banking_intent': forced},
        };
        replaceFile(
          files,
          'backend_fixtures.jsonl',
          lines([
            exchange(localReq, 'local', response(1)),
            exchange(remoteSubset, 'remote', {
              'error': 'synthetic',
            }, status: 529),
          ]),
        );
        if (denial) changeRuns(files, (r) => r['consent'] = false);
        final bundle = parseBenchmarkBundle(files);
        final captures = await replayBenchmark(bundle);
        final hybrid = captures.last;
        expect(hybrid.outcome, 'error');
        expect(hybrid.errorCode, denial ? 'consentRequired' : 'overloaded');
        if (!denial)
          expect(hybrid.exchanges.last.request.questions.keys, [
            'banking_intent',
          ]);
        final report = benchmarkReport(bundle, captures);
        final group = (report['groups'] as List).last as Map;
        expect(
          (group['routing'] as Map)[denial
              ? 'denied_escalations'
              : 'failed_escalations'],
          1,
        );
        expect((group['routing'] as Map)['accepted_local'], 0);
        final positive =
            (group['questions'] as List).singleWhere(
                  (q) => q['key'] == 'positive',
                )
                as Map;
        expect(positive['answered'], 0);
        expect(positive['accuracy'], isNull);
        expect(
          (positive['local_gate_coverage'] as List).map((g) => g['accepted']),
          [1, 1, 1],
        );
      },
    );
  }

  test(
    'local failure with remote-like code does not count remote escalation',
    () async {
      final files = smallFiles();
      final local = request('synthetic evaluation');
      final req = {
        ...local,
        'questions': {
          ...(local['questions'] as Map<String, Object?>),
          'forced': {
            'type': 'choice',
            'criteria': {for (var i = 0; i < 27; i++) 'x$i': null},
          },
        },
      };
      replaceFile(files, 'requests.jsonl', lines([req]));
      final row = jsonDecode(files['cases.jsonl']!) as Map<String, dynamic>;
      row['request_sha256'] = requestHash(req);
      (row['labels'] as Map)['forced'] = 'x0';
      replaceFile(files, 'cases.jsonl', lines([row]));
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([exchange(local, 'local', null, error: 'consentRequired')]),
      );
      final bundle = parseBenchmarkBundle(files);
      final captures = await replayBenchmark(bundle);
      final hybrid = captures.last;
      expect(hybrid.outcome, 'error');
      expect(hybrid.exchanges.map((e) => e.backend), ['local']);
      final report = benchmarkReport(bundle, captures);
      final group = (report['groups'] as List).last as Map;
      expect((group['routing'] as Map)['denied_escalations'], 0);
    },
  );
}
