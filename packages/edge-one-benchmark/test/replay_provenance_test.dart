import 'dart:collection';
import 'dart:convert';
import 'package:edge_one/edge_one.dart';
import 'package:edge_one_benchmark/edge_one_benchmark.dart';
import 'package:test/test.dart';

import 'support/bundle.dart';

// Reporting must check an actual replay result, not a caller's runtimeType claim.
final class _SpoofedCaptures extends ListBase<BenchmarkCapture> {
  _SpoofedCaptures(this.original);
  final List<BenchmarkCapture> original;
  @override
  Type get runtimeType => original.runtimeType;
  @override
  int get length => original.length;
  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  BenchmarkCapture operator [](int index) => original[index];
  @override
  void operator []=(int index, BenchmarkCapture value) =>
      throw UnsupportedError('immutable');
}

void main() {
  test(
    'failed dispatch evidence cannot be stripped before reporting',
    () async {
      final files = smallFiles();
      final req = request('synthetic evaluation');
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          exchange(req, 'local', response(1)),
          exchange(
            {...req, 'state': '[masked]'},
            'remote',
            {'error': 'fixture'},
            status: 529,
            cost: 7,
            elapsed: 17,
          ),
        ]),
      );
      final bundle = parseBenchmarkBundle(files);
      final captures = await replayBenchmark(bundle);
      final remote = captures[1];
      expect(remote.errorCode, 'overloaded');
      final group =
          (benchmarkReport(bundle, captures)['groups'] as List)[1] as Map;
      expect(group['cost'], containsPair('reserved_microcredits', 7));
      expect((group['latency'] as Map)['failed'], containsPair('p50_us', 17));
      final stripped = BenchmarkCapture(
        runId: remote.runId,
        caseId: remote.caseId,
        requestSha256: remote.requestSha256,
        trial: remote.trial,
        outcome: remote.outcome,
        errorCode: remote.errorCode,
        failureOrigin: remote.failureOrigin,
        exchanges: [],
      );
      expect(() {
        benchmarkReport(bundle, [captures.first, stripped, captures.last]);
      }, throwsFormatException);
    },
  );

  test(
    'hybrid fallback refusal metadata cannot be removed or reclassified',
    () async {
      final files = smallFiles();
      changeRuns(files, (run) => run['consent'] = false);
      final req = request('synthetic evaluation');
      replaceFile(
        files,
        'backend_fixtures.jsonl',
        lines([
          exchange(req, 'local', response(.5)),
          exchange({...req, 'state': '[masked]'}, 'remote', response(.8)),
        ]),
      );
      final bundle = parseBenchmarkBundle(files);
      final captures = await replayBenchmark(bundle);
      final hybrid = captures.last;
      expect(hybrid.outcome, 'answered');
      final group =
          (benchmarkReport(bundle, captures)['groups'] as List).last as Map;
      expect(group['routing'], containsPair('denied_escalations', 1));
      for (final replacement in [null, 'overloaded']) {
        final wire =
            jsonDecode(
                  jsonEncode(SystemOneJson.encodeResponse(hybrid.response!)),
                )
                as Map<String, dynamic>;
        final route = (wire['x_routing'] as Map)['positive'] as Map;
        expect(route['remote_error'], 'consentRequired');
        if (replacement == null) {
          route.remove('remote_error');
        } else {
          route['remote_error'] = replacement;
        }
        final altered = BenchmarkCapture(
          runId: hybrid.runId,
          caseId: hybrid.caseId,
          requestSha256: hybrid.requestSha256,
          trial: hybrid.trial,
          outcome: hybrid.outcome,
          response: SystemOneJson.decodeResponse(wire),
          exchanges: hybrid.exchanges,
        );
        expect(() {
          benchmarkReport(bundle, [...captures.take(2), altered]);
        }, throwsFormatException);
      }
    },
  );

  test(
    'copied, wrapped and spoofed capture lists lack replay provenance',
    () async {
      final bundle = parseBenchmarkBundle(smallFiles());
      final captures = await replayBenchmark(bundle);
      final spoofed = _SpoofedCaptures(captures);
      expect(spoofed.runtimeType, captures.runtimeType);
      for (final copy in [
        [...captures],
        List<BenchmarkCapture>.unmodifiable(captures),
        UnmodifiableListView(captures),
        spoofed,
      ]) {
        expect(() {
          benchmarkReport(bundle, copy);
        }, throwsFormatException);
      }
      expect(() => benchmarkReport(bundle, captures), returnsNormally);
    },
  );

  test('replay results belong to the exact parsed bundle', () async {
    final files = smallFiles();
    final bundle = parseBenchmarkBundle(files);
    final equalBundle = parseBenchmarkBundle(files);
    final captures = await replayBenchmark(bundle);
    expect(() {
      benchmarkReport(equalBundle, captures);
    }, throwsFormatException);
    expect(() => benchmarkReport(bundle, captures), returnsNormally);
  });

  test(
    'replay provenance cannot outlive mutations to its nested evidence',
    () async {
      final bundle = parseBenchmarkBundle(smallFiles());
      final captures = await replayBenchmark(bundle);
      final before = jsonEncode(benchmarkReport(bundle, captures));
      final local = captures.first;
      final hybrid = captures.last;
      for (final mutate in <void Function()>[
        () => captures.clear(),
        () => captures[0] = captures.last,
        () => local.exchanges.clear(),
        () => local.response!.answers.clear(),
        () =>
            ((hybrid.response!.xExtensions['x_routing'] as Map)['positive']
                    as Map)['remote_error'] =
                'overloaded',
        () =>
            (((local.exchanges.single.body as Map)['answers']
                        as Map)['positive']
                    as Map)['noul'] =
                .1,
        () => bundle.cases.single.request.questions.clear(),
        () => bundle.cases.single.labels['positive'] = false,
        () => (bundle.suite['provenance'] as Map)['repository_revision'] =
            'changed',
        () => bundle.runs.clear(),
        () => bundle.exchanges.clear(),
        () => bundle.profiles.clear(),
      ]) {
        expect(mutate, throwsUnsupportedError);
      }
      final detachedReport = benchmarkReport(bundle, captures);
      (detachedReport['groups'] as List).clear();
      expect(jsonEncode(benchmarkReport(bundle, captures)), before);
    },
  );
}
