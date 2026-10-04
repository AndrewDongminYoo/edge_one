import 'dart:convert';

import 'package:edge_one_calibrate/edge_one_calibrate.dart';
import 'package:test/test.dart';

import 'redacted_support.dart';
import 'support.dart';

void main() {
  CalibrationDataset parse(List<Map<String, Object?>> rows) =>
      CalibrationDataset.parse(
        jsonl(rows),
        modelSha256: modelHash,
        redactedRequests: true,
      );

  test(
    'real custom-redacted recordings require the explicit input option',
    () async {
      final rows = await customRedactedRecords();
      expect(rows.map((row) => row['request_sha256']).toSet(), hasLength(8));
      expect(
        rows.map((row) => jsonEncode(row['request'])).toSet(),
        hasLength(1),
      );
      expect(rows.every((row) => row.length == 6), isTrue);
      expect(
        () => CalibrationDataset.parse(jsonl(rows), modelSha256: modelHash),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('raw request digest mismatch'),
          ),
        ),
      );
      expect(parse(rows).records, hasLength(8));
    },
  );

  test('custom-redacted input stays deterministic under reordering', () async {
    final rows = await customRedactedRecords();
    final forward = fitCalibration(parse(rows), seed: 42);
    final reverse = fitCalibration(parse(rows.reversed.toList()), seed: 42);
    expect(forward.report, reverse.report);
    expect(forward.profile.toJson(), reverse.profile.toJson());
    final split = splitDataset(parse(rows), seed: 42);
    final fitting = split.fitting.map((r) => r.requestSha256).toSet();
    final validation = split.validation.map((r) => r.requestSha256).toSet();
    expect(fitting, hasLength(4));
    expect(validation, hasLength(4));
    expect(fitting.intersection(validation), isEmpty);
  });

  test('input mode does not change admitted rows or report identity', () {
    final rows = fixture();
    final strict = fitCalibration(
      CalibrationDataset.parse(jsonl(rows), modelSha256: modelHash),
    );
    final optedIn = fitCalibration(parse(rows));
    expect(optedIn.report, strict.report);
    expect(optedIn.profile.toJson(), strict.profile.toJson());
  });

  test(
    'duplicate original digests stay rejected with redaction enabled',
    () async {
      final rows = await customRedactedRecords(count: 2);
      rows.last['request_sha256'] = rows.first['request_sha256'];
      (rows.last['labels'] as Map)['flag'] = false;
      expect(
        () => parse(rows),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('duplicate request_sha256'),
          ),
        ),
      );
    },
  );

  test(
    'redaction mode preserves strict schema and semantic validation',
    () async {
      final original = await customRedactedRecords(count: 2);
      for (final mutate in <void Function(Map<String, Object?>)>[
        (row) => row['model_sha256'] = 'b' * 64,
        (row) => row['request_sha256'] = 'invalid',
        (row) => row['request_redacted'] = true,
        (row) => row['version'] = 2,
        (row) => row['labels'] = {},
        (row) => (row['labels'] as Map)['flag'] = 'true',
        (row) => (row['response'] as Map)['answers'] = {},
        (row) => (row['response'] as Map)['model'] = 'other',
        (row) =>
            (((row['request'] as Map)['questions'] as Map)['topic']
                    as Map)['instructions'] =
                'changed',
        (row) =>
            ((((row['response'] as Map)['answers'] as Map)['level']
                        as Map)['legend']
                    as Map)['1'] =
                'changed',
        (row) =>
            (((row['response'] as Map)['answers'] as Map)['flag']
                    as Map)['noul'] =
                0,
      ]) {
        final rows = original.map(copy).toList();
        mutate(rows.last);
        expect(() => parse(rows), throwsFormatException);
      }
    },
  );

  test(
    'redaction mode still requires each question in both partitions',
    () async {
      final rows = await customRedactedRecords(count: 2);
      ((rows.last['request'] as Map)['questions'] as Map).remove('flag');
      ((rows.last['response'] as Map)['answers'] as Map).remove('flag');
      (rows.last['labels'] as Map).remove('flag');
      expect(
        () => fitCalibration(parse(rows)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('both fitting and validation'),
          ),
        ),
      );
    },
  );
}
