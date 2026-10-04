import 'dart:convert';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one_benchmark/edge_one_benchmark.dart';
import 'package:test/test.dart';

import 'support/bundle.dart';

BenchmarkCapture withExchanges(
  BenchmarkCapture capture,
  List<BackendExchange> exchanges,
) => BenchmarkCapture(
  runId: capture.runId,
  caseId: capture.caseId,
  requestSha256: capture.requestSha256,
  trial: capture.trial,
  outcome: capture.outcome,
  response: capture.response,
  errorCode: capture.errorCode,
  failureOrigin: capture.failureOrigin,
  exchanges: exchanges,
);

void main() {
  test(
    'exported report rejects a remote exchange appended to a local capture',
    () async {
      final bundle = parseBenchmarkBundle(smallFiles());
      final captures = await replayBenchmark(bundle);
      final forged = withExchanges(captures.first, [
        ...captures.first.exchanges,
        captures[1].exchanges.single,
      ]);
      expect(
        () => benchmarkReport(bundle, [forged, ...captures.skip(1)]),
        throwsFormatException,
      );
    },
  );

  test(
    'exported report rejects repeated exchanges that inflate latency and cost',
    () async {
      final bundle = parseBenchmarkBundle(smallFiles());
      final captures = await replayBenchmark(bundle);
      final remote = captures[1];
      final forged = withExchanges(remote, [
        ...remote.exchanges,
        ...remote.exchanges,
      ]);
      expect(
        () => benchmarkReport(bundle, [captures.first, forged, captures.last]),
        throwsFormatException,
      );
    },
  );

  test(
    'globally valid local exchange must match this capture source request',
    () async {
      final files = smallFiles();
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        '${files['backend_fixtures.jsonl']}${lines([exchange(request('another synthetic source'), 'local', response(1), elapsed: 999)])}',
      );
      final bundle = parseBenchmarkBundle(files);
      final captures = await replayBenchmark(bundle);
      final unrelated = bundle.exchanges.values.singleWhere(
        (e) => e.request.state == 'another synthetic source',
      );
      final forged = withExchanges(captures.first, [unrelated]);
      expect(
        () => benchmarkReport(bundle, [forged, ...captures.skip(1)]),
        throwsFormatException,
      );
    },
  );
  test(
    'accepted hybrid gates cannot authorize appended remote evidence',
    () async {
      final bundle = parseBenchmarkBundle(smallFiles());
      final captures = await replayBenchmark(bundle);
      final hybrid = captures.last;
      final wire =
          jsonDecode(jsonEncode(SystemOneJson.encodeResponse(hybrid.response!)))
              as Map<String, dynamic>;
      final routing = (wire['x_routing'] as Map)['positive'] as Map;
      routing['gate'] = 'rejected';
      routing['route'] = 'remote';
      final forged = BenchmarkCapture(
        runId: hybrid.runId,
        caseId: hybrid.caseId,
        requestSha256: hybrid.requestSha256,
        trial: hybrid.trial,
        outcome: 'answered',
        response: SystemOneJson.decodeResponse(wire),
        exchanges: [...hybrid.exchanges, captures[1].exchanges.single],
      );
      expect(
        () => benchmarkReport(bundle, [...captures.take(2), forged]),
        throwsFormatException,
      );
    },
  );

  test(
    'hybrid sequence keeps local first and exact masked escalation subset',
    () async {
      final files = smallFiles();
      final req = request('synthetic evaluation');
      (req['questions'] as Map)['uncertain'] = {
        'type': 'noul',
        'instructions': 'Other?',
      };
      final localBody = response(1);
      (localBody['answers'] as Map)['uncertain'] = {'type': 'noul', 'noul': .5};
      final row = jsonDecode(files['cases.jsonl']!) as Map<String, dynamic>;
      row['request_sha256'] = requestHash(req);
      (row['labels'] as Map)['uncertain'] = true;
      replaceFile(files, 'requests.jsonl', lines([req]));
      replaceFile(files, 'cases.jsonl', lines([row]));
      final subset = {
        'model': 'fixture',
        'state': '[masked]',
        'questions': {'uncertain': (req['questions'] as Map)['uncertain']},
      };
      final remoteBody = {
        'model': 'remote',
        'answers': {
          'uncertain': {'type': 'noul', 'noul': .9},
        },
        'usage': {'input_tokens': 1, 'output_tokens': 1},
      };
      final fullBody = response(.9, model: 'remote');
      (fullBody['answers'] as Map)['uncertain'] = {'type': 'noul', 'noul': .9};
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          exchange(req, 'local', localBody),
          exchange(subset, 'remote', remoteBody),
          exchange({...req, 'state': '[masked]'}, 'remote', fullBody),
        ]),
      );
      final bundle = parseBenchmarkBundle(files);
      final captures = await replayBenchmark(bundle);
      final hybrid = captures.last;
      expect(hybrid.exchanges.map((e) => e.backend), ['local', 'remote']);
      expect(() => benchmarkReport(bundle, captures), returnsNormally);
      for (final trace in [
        hybrid.exchanges.reversed.toList(),
        [hybrid.exchanges.first, captures[1].exchanges.single],
      ]) {
        final forged = withExchanges(hybrid, trace);
        expect(
          () => benchmarkReport(bundle, [...captures.take(2), forged]),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'answered captures require source evidence and matching routing metadata',
    () async {
      final bundle = parseBenchmarkBundle(smallFiles());
      final captures = await replayBenchmark(bundle);
      expect(
        () => benchmarkReport(bundle, [
          withExchanges(captures.first, []),
          ...captures.skip(1),
        ]),
        throwsFormatException,
      );
      final hybrid = captures.last;
      final wire =
          jsonDecode(jsonEncode(SystemOneJson.encodeResponse(hybrid.response!)))
              as Map<String, dynamic>;
      ((wire['x_routing'] as Map)['positive'] as Map)['gate'] = 'rejected';
      final forged = BenchmarkCapture(
        runId: hybrid.runId,
        caseId: hybrid.caseId,
        requestSha256: hybrid.requestSha256,
        trial: hybrid.trial,
        outcome: hybrid.outcome,
        response: SystemOneJson.decodeResponse(wire),
        exchanges: hybrid.exchanges,
      );
      expect(
        () => benchmarkReport(bundle, [...captures.take(2), forged]),
        throwsFormatException,
      );
    },
  );
  test(
    'declared budget refusal cannot carry a dispatched remote exchange',
    () async {
      final files = smallFiles();
      changeRuns(files, (run) => run['budget_microcredits'] = 2);
      final bundle = parseBenchmarkBundle(files);
      final captures = await replayBenchmark(bundle);
      expect(captures[1].errorCode, 'budgetExhausted');
      expect(captures[1].exchanges, isEmpty);
      final remote = bundle.exchanges.values.singleWhere(
        (e) => e.backend == 'remote',
      );
      final refused = captures[1];
      for (final origin in ['remote', null, 'response_validation']) {
        final forged = BenchmarkCapture(
          runId: refused.runId,
          caseId: refused.caseId,
          requestSha256: refused.requestSha256,
          trial: refused.trial,
          outcome: refused.outcome,
          errorCode: refused.errorCode,
          failureOrigin: origin,
          exchanges: [remote],
        );
        expect(
          () =>
              benchmarkReport(bundle, [captures.first, forged, captures.last]),
          throwsFormatException,
          reason: 'refusal cannot enter transport with origin $origin',
        );
      }
    },
  );

  test(
    'hybrid fallback refusal cannot include an entered remote failure',
    () async {
      final files = smallFiles();
      changeRuns(files, (run) => run['budget_microcredits'] = 2);
      final req = request('synthetic evaluation');
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          exchange(req, 'local', response(.5)),
          exchange(
            {...req, 'state': '[masked]'},
            'remote',
            {'error': 'fixture'},
            status: 529,
          ),
        ]),
      );
      final bundle = parseBenchmarkBundle(files);
      final captures = await replayBenchmark(bundle);
      final hybrid = captures.last;
      expect(hybrid.outcome, 'answered');
      expect(
        ((hybrid.response!.xExtensions['x_routing'] as Map)['positive']
            as Map)['remote_error'],
        'budgetExhausted',
      );
      expect(hybrid.exchanges.length, 1);
      final remote = bundle.exchanges.values.singleWhere(
        (e) => e.backend == 'remote',
      );
      final forged = withExchanges(hybrid, [...hybrid.exchanges, remote]);
      expect(
        () => benchmarkReport(bundle, [...captures.take(2), forged]),
        throwsFormatException,
      );
    },
  );

  test(
    'forged failure origin cannot authorize remote after invalid local evidence',
    () async {
      final files = smallFiles();
      final req = {
        'model': 'fixture',
        'state': 'synthetic choice',
        'questions': {
          'q': {
            'type': 'choice',
            'criteria': {'a': null, 'b': null},
          },
        },
      };
      final bad = {
        'model': 'fixture',
        'answers': {
          'q': {
            'type': 'choice',
            'choice': 'a',
            'probabilities': {'a': .1, 'b': .9},
            'confidence': .8,
          },
        },
        'usage': {'input_tokens': 1, 'output_tokens': 1},
      };
      replaceFile(files, 'requests.jsonl', lines([req]));
      replaceFile(
        files,
        'cases.jsonl',
        lines([
          {
            'version': 1,
            'case_id': 'tickets:choice',
            'request_sha256': requestHash(req),
            'dataset_id': 'tickets',
            'source_split': 'synthetic',
            'partition': 'evaluation',
            'labels': {'q': 'b'},
          },
        ]),
      );
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          exchange(req, 'local', bad),
          exchange(
            {...req, 'state': '[masked]'},
            'remote',
            {'error': 'fixture'},
            status: 529,
          ),
        ]),
      );
      final bundle = parseBenchmarkBundle(files);
      final captures = await replayBenchmark(bundle);
      final hybrid = captures.last;
      final remote = captures[1].exchanges.single;
      final forged = BenchmarkCapture(
        runId: hybrid.runId,
        caseId: hybrid.caseId,
        requestSha256: hybrid.requestSha256,
        trial: hybrid.trial,
        outcome: 'error',
        failureOrigin: 'remote',
        errorCode: 'overloaded',
        exchanges: [...hybrid.exchanges, remote],
      );
      expect(
        () => benchmarkReport(bundle, [...captures.take(2), forged]),
        throwsFormatException,
      );
    },
  );

  test(
    'direct remote provider extensions are not router refusal metadata',
    () async {
      final files = smallFiles();
      final req = request('synthetic evaluation');
      final remoteBody = response(.8, model: 'remote-id')
        ..['x_routing'] = {
          'positive': {'remote_error': 'budgetExhausted'},
        };
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          exchange(req, 'local', response(1)),
          exchange({...req, 'state': '[masked]'}, 'remote', remoteBody),
        ]),
      );
      final bundle = parseBenchmarkBundle(files);
      final captures = await replayBenchmark(bundle);
      expect(captures[1].outcome, 'answered');
      expect(
        captures[1].response!.xExtensions['x_routing'],
        remoteBody['x_routing'],
      );
      expect(() => benchmarkReport(bundle, captures), returnsNormally);
    },
  );
}
