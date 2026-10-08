import 'dart:convert';
import 'package:edge_one_benchmark/edge_one_benchmark.dart';
import 'package:test/test.dart';

import 'support/bundle.dart';

const maxSafe = 9007199254740991;

BenchmarkBundle timedBundle(int? localUs, int? remoteUs, {int status = 200}) {
  final files = smallFiles();
  final req = request('synthetic evaluation');
  replaceFile(
    files,
    'backend_fixtures.jsonl',
    lines([
      {...exchange(req, 'local', response(.5)), 'elapsed_us': localUs},
      {
        ...exchange(
          {...req, 'state': '[masked]'},
          'remote',
          status == 200
              ? response(.8, model: 'remote-id')
              : {'error': 'fixture'},
          status: status,
        ),
        'elapsed_us': remoteUs,
      },
    ]),
  );
  return parseBenchmarkBundle(files);
}

void main() {
  test(
    'actual hybrid replay rejects an unsafe aggregate before minting captures',
    () async {
      for (final status in [200, 529]) {
        // Each exchange is valid; only the aggregate exceeds the inclusive limit.
        final bundle = timedBundle(maxSafe, 1, status: status);
        await expectLater(replayBenchmark(bundle), throwsFormatException);
      }
    },
  );

  test(
    'exact maximum and zero duration survive capture and report serialization',
    () async {
      for (final pair in [
        (maxSafe - 1, 1),
        (maxSafe, 0),
        (0, maxSafe),
        (0, 0),
      ]) {
        final bundle = timedBundle(pair.$1, pair.$2);
        final captures = await replayBenchmark(bundle);
        final total = pair.$1 + pair.$2;
        expect(captures.last.exchanges.length, 2);
        expect(captures.last.elapsedUs, total);
        final report =
            jsonDecode(jsonEncode(benchmarkReport(bundle, captures))) as Map;
        final capture = (report['captures'] as List).last as Map;
        final group = (report['groups'] as List).last as Map;
        expect(capture['elapsed_us'], total);
        expect((group['latency'] as Map)['answered'], {
          'samples': 1,
          'unmeasured': 0,
          'p50_us': total,
          'p95_us': total,
        });
      }
    },
  );

  test(
    'unknown exchange timing stays null without discarding entered evidence',
    () async {
      for (final pair in [(null, maxSafe), (maxSafe, null), (null, null)]) {
        final bundle = timedBundle(pair.$1, pair.$2);
        final captures = await replayBenchmark(bundle);
        final hybrid = captures.last;
        expect(hybrid.exchanges.length, 2);
        expect(hybrid.elapsedUs, isNull);
        final report = benchmarkReport(bundle, captures);
        final capture = (report['captures'] as List).last as Map;
        final group = (report['groups'] as List).last as Map;
        expect(capture['elapsed_us'], isNull);
        expect((capture['exchanges'] as List).length, 2);
        expect((group['latency'] as Map)['answered'], {
          'samples': 0,
          'unmeasured': 1,
          'p50_us': null,
          'p95_us': null,
        });
        expect(group['cost'], containsPair('dispatches', 1));
      }
    },
  );
}
