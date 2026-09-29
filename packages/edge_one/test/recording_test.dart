import 'dart:convert';

import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';
import 'package:test/test.dart';

final class FixedBackend implements SystemOneBackend {
  const FixedBackend(this.response);

  final SystemOneResponse response;

  @override
  Future<SystemOneResponse> evaluate(SystemOneRequest request) async =>
      response;
}

void main() {
  const secret = 'Card 4242 was charged twice for Jane Roe';
  final request = SystemOneJson.decodeRequest({
    'state': {'ticket': secret},
    'model': 'test-model',
    'questions': {
      'team': {
        'type': 'choice',
        'criteria': {'billing': null, 'shipping': null},
      },
      'urgent': {'type': 'noul'},
    },
  });
  final other = SystemOneJson.decodeRequest({
    ...SystemOneJson.encodeRequest(request),
    'state': 'A different ticket',
  });
  final engine = FakeEngine(
    weights: {
      'team': {'billing': 3, 'shipping': 1},
    },
  );

  Future<String> record(
    List<SystemOneRequest> requests, {
    SystemOneBackend? backend,
    RequestRedactor redact = redactState,
  }) async {
    final sink = StringBuffer();
    final recorder = RecordingBackend.record(
      backend ?? engine,
      sink,
      redact: redact,
    );
    for (final request in requests) {
      await recorder.evaluate(request);
    }
    return sink.toString();
  }

  Map<String, Object?> line(String jsonl, int index) =>
      jsonDecode(const LineSplitter().convert(jsonl)[index])
          as Map<String, Object?>;

  Matcher throwsRecordingFormat(int line, String message) => throwsA(
    isA<RecordingFormatException>()
        .having((e) => e.line, 'line', line)
        .having((e) => e.message, 'message', contains(message)),
  );

  group('record', () {
    test(
      'writes one versioned line per call and returns the response',
      () async {
        final sink = StringBuffer();
        final response = await RecordingBackend.record(
          engine,
          sink,
        ).evaluate(request);
        expect(
          SystemOneJson.encodeResponse(response),
          SystemOneJson.encodeResponse(await engine.evaluate(request)),
        );
        final first = line(sink.toString(), 0);
        expect(first.keys, [
          'version',
          'request_sha256',
          'request',
          'response',
        ]);
        expect(first['version'], 1);
        expect(
          first['request_sha256'],
          RecordingBackend.requestSha256(request),
        );
        expect(first['response'], SystemOneJson.encodeResponse(response));
      },
    );

    test('redacts the state by default', () async {
      final jsonl = await record([request]);
      expect(jsonl, isNot(contains('4242')));
      expect(jsonl, isNot(contains('Jane Roe')));
      final stored = line(jsonl, 0)['request'] as Map<String, Object?>;
      expect(stored['state'], redactedState);
      expect(
        stored['questions'],
        SystemOneJson.encodeRequest(request)['questions'],
      );
    });

    test('stores the full request with an identity redactor', () async {
      final jsonl = await record([request], redact: (request) => request);
      expect(line(jsonl, 0)['request'], SystemOneJson.encodeRequest(request));
    });

    test('rejects a redactor that changes the questions', () async {
      final sink = StringBuffer();
      final recorder = RecordingBackend.record(
        engine,
        sink,
        redact: (request) => SystemOneRequest(
          state: redactedState,
          model: request.model,
          questions: {'team': request.questions['team']!},
        ),
      );
      await expectLater(recorder.evaluate(request), throwsStateError);
      expect(sink.toString(), isEmpty);
    });

    test('rejects an invalid backend response without writing', () async {
      final sink = StringBuffer();
      final recorder = RecordingBackend.record(
        const FixedBackend(
          SystemOneResponse(
            model: 'm',
            answers: {'urgent': NoulAnswer(noul: 0.5)},
            usage: Usage(inputTokens: 0, outputTokens: 0),
          ),
        ),
        sink,
      );
      await expectLater(
        recorder.evaluate(request),
        throwsA(isA<SystemOneFormatException>()),
      );
      expect(sink.toString(), isEmpty);
    });
  });

  group('replay', () {
    test('returns recorded responses without the backend', () async {
      final jsonl = await record([request, other]);
      final replay = RecordingBackend.replay(jsonl);
      for (final r in [other, request, request, other]) {
        expect(
          SystemOneJson.encodeResponse(await replay.evaluate(r)),
          SystemOneJson.encodeResponse(await engine.evaluate(r)),
        );
      }
    });

    test('drives DecisionClient like the recorded backend', () async {
      final jsonl = await record([request]);
      final client = DecisionClient(
        RecordingBackend.replay(jsonl),
        model: 'unused',
        minConfidence: 0,
      );
      expect(
        await client.evaluateJson(SystemOneJson.encodeRequest(request)),
        SystemOneJson.encodeResponse(await engine.evaluate(request)),
      );
    });

    test('reports requests that were not recorded', () async {
      final replay = RecordingBackend.replay(await record([request]));
      await expectLater(
        replay.evaluate(other),
        throwsA(
          isA<RecordingMissException>().having(
            (e) => e.requestSha256,
            'requestSha256',
            RecordingBackend.requestSha256(other),
          ),
        ),
      );
    });

    test('treats object key order as part of the request', () async {
      final replay = RecordingBackend.replay(await record([request]));
      final reordered = SystemOneJson.decodeRequest({
        'state': {'ticket': secret},
        'model': 'test-model',
        'questions': {
          'urgent': {'type': 'noul'},
          'team': {
            'type': 'choice',
            'criteria': {'billing': null, 'shipping': null},
          },
        },
      });
      await expectLater(
        replay.evaluate(reordered),
        throwsA(isA<RecordingMissException>()),
      );
    });

    test('replays the first of duplicate lines', () async {
      final first = await record([request]);
      final second = await record(
        [request],
        backend: FakeEngine(
          weights: {
            'team': {'shipping': 1},
          },
        ),
      );
      final replay = RecordingBackend.replay('$first$second');
      final answer =
          (await replay.evaluate(request)).answers['team'] as ChoiceAnswer;
      expect(answer.choice, 'billing');
    });

    test('ignores blank lines and CRLF endings', () async {
      final jsonl = await record([request, other]);
      final replay = RecordingBackend.replay(
        '\r\n${jsonl.replaceAll('\n', '\r\n\r\n')}',
      );
      expect(await replay.evaluate(other), isA<SystemOneResponse>());
    });
  });

  group('malformed recordings', () {
    late String valid;
    late Map<String, Object?> fields;

    setUp(() async {
      valid = (await record([request])).trim();
      fields = line(valid, 0);
    });

    String withLine(Object? value) =>
        '$valid\n${value is String ? value : jsonEncode(value)}\n';

    test('reject invalid JSON', () {
      expect(
        () => RecordingBackend.replay(withLine('{"version": 1,')),
        throwsRecordingFormat(2, 'invalid JSON'),
      );
    });

    test('reject a line that is not an object', () {
      expect(
        () => RecordingBackend.replay(withLine([fields])),
        throwsRecordingFormat(2, 'expected an object'),
      );
    });

    test('reject missing and unexpected fields', () {
      expect(
        () => RecordingBackend.replay(withLine({...fields}..remove('request'))),
        throwsRecordingFormat(2, 'missing field "request"'),
      );
      expect(
        () => RecordingBackend.replay(withLine({...fields, 'note': 'x'})),
        throwsRecordingFormat(2, 'unexpected field "note"'),
      );
    });

    test('reject another version', () {
      expect(
        () => RecordingBackend.replay(withLine({...fields, 'version': 2})),
        throwsRecordingFormat(2, 'expected version 1'),
      );
    });

    test('reject malformed digests', () {
      final digest = fields['request_sha256'] as String;
      for (final bad in [digest.toUpperCase(), digest.substring(1), 42]) {
        expect(
          () => RecordingBackend.replay(
            withLine({...fields, 'request_sha256': bad}),
          ),
          throwsRecordingFormat(2, 'request_sha256'),
        );
      }
    });

    test('reject a request outside the contract', () {
      expect(
        () => RecordingBackend.replay(
          withLine({
            ...fields,
            'request': {
              ...fields['request'] as Map<String, Object?>,
              'state': 42,
            },
          }),
        ),
        throwsRecordingFormat(2, 'request /state'),
      );
    });

    test('reject a response outside the contract', () {
      final response = fields['response'] as Map<String, Object?>;
      expect(
        () => RecordingBackend.replay(
          withLine({
            ...fields,
            'response': {
              ...response,
              'answers': {
                ...response['answers'] as Map<String, Object?>,
                'urgent': {'type': 'noul', 'noul': 1.5},
              },
            },
          }),
        ),
        throwsRecordingFormat(2, 'response /answers/urgent/noul'),
      );
    });

    test('reject a response that does not answer the request', () {
      final response = fields['response'] as Map<String, Object?>;
      expect(
        () => RecordingBackend.replay(
          withLine({
            ...fields,
            'response': {
              ...response,
              'answers': {
                'urgent': {'type': 'noul', 'noul': 0.5},
              },
            },
          }),
        ),
        throwsRecordingFormat(2, 'response /answers'),
      );
    });
  });
}
