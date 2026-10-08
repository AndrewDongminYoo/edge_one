import 'dart:convert';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one_benchmark/edge_one_benchmark.dart';
import 'package:test/test.dart';
import 'support/bundle.dart';

void main() {
  test(
    'three modes share original digest; actual remote preserves decoded body/model',
    () async {
      final files = smallFiles();
      final before = jsonEncode(files);
      final bundle = parseBenchmarkBundle(files);
      final captures = await replayBenchmark(bundle);
      expect(captures.length, 3);
      expect(captures.map((c) => c.requestSha256).toSet(), {
        bundle.cases.single.requestSha256,
      });
      expect(captures.map((c) => c.outcome), everyElement('answered'));
      final remote = captures.singleWhere((c) => c.runId == 'remote');
      expect(remote.response!.model, 'remote-id');
      expect(remote.response!.xRoute, 'remote');
      expect(remote.exchanges.single.body, isNot(contains('x_route')));
      expect(remote.toJson(bundle.cases.single)['exchanges'], isNotEmpty);
      final hybrid = captures.last;
      expect(hybrid.exchanges.map((e) => e.backend), ['local']);
      expect(
        (hybrid.response!.xExtensions['x_routing'] as Map)['positive'],
        containsPair('gate', 'accepted'),
      );
      expect(jsonEncode(files), before);
    },
  );
  test(
    'remote invalid pairing is retained and counted as invalidResponse',
    () async {
      final files = smallFiles();
      final req = request('synthetic evaluation');
      final bad = response(.8);
      bad['answers'] = {
        'unrequested': {'type': 'noul', 'noul': .8},
      };
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          exchange(req, 'local', response(1)),
          exchange({...req, 'state': '[masked]'}, 'remote', bad),
        ]),
      );
      final captures = await replayBenchmark(parseBenchmarkBundle(files));
      expect(captures[1].outcome, 'error');
      expect(captures[1].errorCode, 'invalidResponse');
      expect(captures[1].exchanges.single.body, bad);
    },
  );
  test(
    'denied escalation returns uncertain local fallback and no charged transport',
    () async {
      final files = smallFiles();
      final req = request('synthetic evaluation');
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([exchange(req, 'local', response(.5))]),
      );
      changeRuns(files, (r) => r['consent'] = false);
      final captures = await replayBenchmark(parseBenchmarkBundle(files));
      expect(captures[1].outcome, 'error');
      expect(captures[1].errorCode, 'consentRequired');
      expect(captures[1].exchanges, isEmpty);
      expect(captures.last.outcome, 'answered');
      final routing =
          (captures.last.response!.xExtensions['x_routing'] as Map)['positive']
              as Map;
      expect(routing['gate'], 'rejected');
      expect(routing['route'], 'local');
      expect(routing['remote_error'], 'consentRequired');
    },
  );
  test(
    '77-choice local unsupported, forced-only hybrid skips local or errors on denial',
    () async {
      final files = smallFiles();
      final req = {
        'model': 'fixture',
        'state': 'synthetic banking',
        'questions': {
          'banking_intent': {
            'type': 'choice',
            'criteria': {for (var i = 0; i < 77; i++) 'intent$i': null},
          },
        },
      };
      final body = {
        'model': 'remote-id',
        'answers': {
          'banking_intent': {
            'type': 'choice',
            'choice': 'intent0',
            'confidence': 1,
            'probabilities': {
              for (var i = 0; i < 77; i++) 'intent$i': i == 0 ? 1 : 0,
            },
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
            'case_id': 'banking77:one',
            'request_sha256': requestHash(req),
            'dataset_id': 'banking77',
            'source_split': 'synthetic',
            'partition': 'evaluation',
            'labels': {'banking_intent': 'intent0'},
          },
        ]),
      );
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          exchange({...req, 'state': '[masked]'}, 'remote', body),
        ]),
      );
      var captures = await replayBenchmark(parseBenchmarkBundle(files));
      expect(captures.first.outcome, 'unsupported');
      expect(captures.first.exchanges, isEmpty);
      expect(captures.last.outcome, 'answered');
      expect(captures.last.exchanges.single.backend, 'remote');
      changeRuns(files, (r) => r['consent'] = false);
      captures = await replayBenchmark(parseBenchmarkBundle(files));
      expect(captures.last.outcome, 'error');
      expect(captures.last.errorCode, 'consentRequired');
    },
  );
  test(
    'mixed router requires exact masked subset and never slices a full response',
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
        'model': 'different-remote',
        'answers': {
          'uncertain': {'type': 'noul', 'noul': .9},
        },
        'usage': {'input_tokens': 1, 'output_tokens': 1},
      };
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          exchange(req, 'local', localBody),
          exchange(subset, 'remote', remoteBody),
        ]),
      );
      var captures = await replayBenchmark(parseBenchmarkBundle(files));
      final hybrid = captures.last;
      expect(hybrid.outcome, 'answered');
      expect(hybrid.exchanges.last.request.questions.keys, ['uncertain']);
      expect(hybrid.exchanges.last.request.state, '[masked]');
      expect((hybrid.response!.answers['uncertain'] as NoulAnswer).noul, .9);
      expect(hybrid.response!.model, 'fixture');
      expect(
        captures[1].outcome,
        'error',
      ); // full direct remote has no exact exchange
      final fullRemote = {...req, 'state': '[masked]'};
      final fullBody = response(.9, model: 'remote-id');
      (fullBody['answers'] as Map)['uncertain'] = {'type': 'noul', 'noul': .9};
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          exchange(req, 'local', localBody),
          exchange(fullRemote, 'remote', fullBody),
        ]),
      );
      captures = await replayBenchmark(parseBenchmarkBundle(files));
      expect(
        (captures.last.response!.answers['uncertain'] as NoulAnswer).noul,
        .5,
      );
      expect(captures.last.exchanges.length, 1);
    },
  );
  test(
    'failed dispatch preserves body/cost; refusal and exhausted budget dispatch nothing',
    () async {
      final files = smallFiles();
      final req = request('synthetic evaluation');
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          exchange(req, 'local', response(.5)),
          exchange(
            {...req, 'state': '[masked]'},
            'remote',
            {'error': 'synthetic overloaded'},
            status: 529,
            cost: 3,
          ),
        ]),
      );
      var captures = await replayBenchmark(parseBenchmarkBundle(files));
      expect(captures[1].errorCode, 'overloaded');
      expect(captures[1].exchanges.single.body, {
        'error': 'synthetic overloaded',
      });
      expect(captures[1].exchanges.single.cost, 3);
      changeRuns(files, (r) => r['budget_microcredits'] = 2);
      captures = await replayBenchmark(parseBenchmarkBundle(files));
      expect(captures[1].errorCode, 'budgetExhausted');
      expect(captures[1].exchanges, isEmpty);
      expect(captures.last.exchanges.map((e) => e.backend), ['local']);
    },
  );

  test('valid non-200 successful Score preserves legend and replays', () async {
    final files = smallFiles();
    final req = {
      'model': 'fixture',
      'state': 'synthetic score',
      'questions': {
        'score': {
          'type': 'score',
          'criteria': [for (var i = 0; i < 27; i++) 'level$i'],
        },
      },
    };
    final body = {
      'model': 'remote-id',
      'answers': {
        'score': {
          'type': 'score',
          'score': 0,
          'legend': {for (var i = 0; i < 27; i++) 'level$i': 'level$i'},
          'confidence': 1,
          'probabilities': {
            for (var i = 0; i < 27; i++) 'level$i': i == 0 ? 1 : 0,
          },
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
          'case_id': 'tickets:score',
          'request_sha256': requestHash(req),
          'dataset_id': 'tickets',
          'source_split': 'synthetic',
          'partition': 'evaluation',
          'labels': {'score': 'level0'},
        },
      ]),
    );
    replaceFile(
      files,
      'backend_fixtures.jsonl',
      lines([
        exchange({...req, 'state': '[masked]'}, 'remote', body, status: 201),
      ]),
    );
    final captures = await replayBenchmark(parseBenchmarkBundle(files));
    expect(captures.map((c) => c.outcome), [
      'unsupported',
      'answered',
      'answered',
    ]);
  });
  test('trial reservations share run budget and immutable evidence', () async {
    final files = smallFiles();
    changeRuns(files, (r) {
      r['trial_count'] = 2;
      r['budget_microcredits'] = 3;
    });
    final bundle = parseBenchmarkBundle(files);
    final captures = await replayBenchmark(bundle);
    final remote = captures.where((c) => c.runId == 'remote').toList();
    expect(remote.map((c) => c.outcome), ['answered', 'error']);
    expect(remote.last.errorCode, 'budgetExhausted');
    expect(remote.last.exchanges, isEmpty);
    expect(
      () => (remote.first.exchanges.single.body as Map).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => bundle.cases.single.request.questions.clear(),
      throwsUnsupportedError,
    );
    final report = benchmarkReport(bundle, captures);
    final group = (report['groups'] as List)[1] as Map;
    expect(group['trial_request_counts'], {
      'attempted': 2,
      'answered': 1,
      'unsupported': 0,
      'error': 1,
    });
    expect(group['cost'], containsPair('dispatches', 1));
    expect(group['cost'], containsPair('reserved_microcredits', 3));
    expect(group['cost'], containsPair('shadow_reserved_microcredits', 0));
  });

  test(
    'benchmark-invalid remote answer becomes error capture, retaining body',
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
      final body = {
        'model': 'remote-id',
        'answers': {
          'q': {
            'type': 'choice',
            'choice': 'a',
            'probabilities': {'a': 0.1, 'b': 0.9},
            'confidence': 0.8,
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
          exchange({...req, 'state': '[masked]'}, 'remote', body),
        ]),
      );
      final captures = await replayBenchmark(parseBenchmarkBundle(files));
      expect(captures[1].outcome, 'error');
      expect(captures[1].errorCode, 'invalidBenchmarkResponse');
      expect(captures[1].exchanges.single.body, body);
    },
  );
  test(
    'invalid local categorical evidence is a complete error before routing',
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
      final body = {
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
        lines([exchange(req, 'local', body)]),
      );
      final bundle = parseBenchmarkBundle(files);
      final captures = await replayBenchmark(bundle);
      expect(captures.last.outcome, 'error');
      expect(captures.last.errorCode, 'invalidBenchmarkResponse');
      expect(captures.last.failureOrigin, 'local');
      expect(captures.last.exchanges.single.body, body);
      expect(() => benchmarkReport(bundle, captures), returnsNormally);
    },
  );
}
