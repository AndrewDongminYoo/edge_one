import 'package:edge_one/edge_one.dart';
import 'package:edge_one_benchmark/edge_one_benchmark.dart';
import 'package:test/test.dart';

void main() {
  test('Banking77 retains all options and exact intent label', () {
    final names = List.generate(77, (i) => 'synthetic_intent_$i');
    final cases = adaptRows(DatasetAdapter.banking77, [
      {'id': '1', 'text': 'Invented banking request', 'label': names.last},
    ], intentNames: names);
    expect(cases, hasLength(1));
    final question =
        cases.single.request.questions['banking_intent'] as ChoiceQuestion;
    expect(question.criteria.keys, names);
    expect(cases.single.labels, {'banking_intent': names.last});
  });
  test('YNAT seven labels and NLI premise/hypothesis mapping stay stable', () {
    final news = adaptRows(DatasetAdapter.klueYnat, [
      {'id': '1', 'title': '가상의 과학 기사', 'label': 0},
    ]).single;
    expect(
      (news.request.questions['ynat_topic'] as ChoiceQuestion).criteria,
      hasLength(7),
    );
    expect(news.labels, {'ynat_topic': 'IT과학'});
    for (final (i, name) in [
      'entailment',
      'neutral',
      'contradiction',
    ].indexed) {
      final nli = adaptRows(DatasetAdapter.klueNli, [
        {'id': '$i', 'premise': '가상의 전제', 'hypothesis': '가상의 가설', 'label': i},
      ]).single;
      expect(nli.request.state, {'premise': '가상의 전제', 'hypothesis': '가상의 가설'});
      expect(nli.labels, {'nli_relation': name});
    }
  });
  test('NSMC labels become booleans and tickets cover all question types', () {
    for (final label in [0, 1]) {
      final item = adaptRows(DatasetAdapter.nsmc, [
        {'id': '$label', 'document': '완전히 가상의 영화 감상', 'label': label},
      ]).single;
      expect(item.labels, {'positive': label == 1});
    }
    final ticket = adaptRows(DatasetAdapter.tickets, [
      {
        'id': '1',
        'state': {'ticket': 'Invented duplicate charge'},
        'labels': {
          'ticket_topic': 'billing',
          'ticket_refund': true,
          'ticket_urgency': '1',
        },
      },
    ]).single;
    expect(ticket.request.questions.keys, [
      'ticket_topic',
      'ticket_refund',
      'ticket_urgency',
    ]);
    expect(ticket.labels['ticket_urgency'], '1');
  });
  test(
    'source labels use integer IDs and Banking intent names contain text',
    () {
      expect(
        () => adaptRows(DatasetAdapter.nsmc, [
          {'id': '1', 'document': 'invented', 'label': 1.0},
        ]),
        throwsFormatException,
      );
      final names = List.generate(77, (i) => 'intent$i')..[0] = '   ';
      expect(
        () => adaptRows(DatasetAdapter.banking77, [
          {'id': '1', 'text': 'invented', 'label': 'intent1'},
        ], intentNames: names),
        throwsFormatException,
      );
    },
  );
  test('invalid rows fail instead of silently filtering or relabeling', () {
    for (final row in [
      {'id': '1', 'document': '', 'label': 1},
      {'id': '1', 'document': 'invented', 'label': 2},
    ]) {
      expect(
        () => adaptRows(DatasetAdapter.nsmc, [row]),
        throwsFormatException,
      );
    }
    expect(
      () => adaptRows(DatasetAdapter.banking77, [
        {'id': '1', 'text': 'invented', 'label': 'missing'},
      ], intentNames: List.generate(77, (i) => '$i')),
      throwsFormatException,
    );
    expect(
      () => adaptRows(DatasetAdapter.tickets, [
        {
          'id': '1',
          'state': 'invented',
          'labels': {'ticket_topic': 'billing'},
        },
      ]),
      throwsFormatException,
    );
  });
}
