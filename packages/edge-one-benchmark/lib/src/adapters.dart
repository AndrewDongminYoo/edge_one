import 'package:edge_one/edge_one.dart';

import 'case.dart';

/// Pure row mappings; no dataset fetching or permission inference.
enum DatasetAdapter { banking77, klueYnat, klueNli, nsmc, tickets }

List<BenchmarkCase> adaptRows(
  DatasetAdapter adapter,
  List<Map<String, Object?>> rows, {
  List<String>? intentNames,
}) {
  if (adapter == DatasetAdapter.banking77 &&
      (intentNames == null ||
          intentNames.length != 77 ||
          intentNames.toSet().length != 77 ||
          intentNames.any((s) => s.trim().isEmpty))) {
    throw const FormatException('Banking77 requires 77 distinct intent names');
  }
  const news = ['IT과학', '경제', '사회', '생활문화', '세계', '스포츠', '정치'];
  const relations = ['entailment', 'neutral', 'contradiction'];
  return [
    for (final row in rows)
      () {
        final id = requiredText(row['id']);
        late Object state;
        late Map<String, SystemOneQuestion> questions;
        late Map<String, Object?> labels;
        void choice(
          String key,
          List<String> names,
          Object? label,
          String instruction,
        ) {
          questions = {
            key: ChoiceQuestion(
              instructions: instruction,
              criteria: {for (final name in names) name: null},
            ),
          };
          labels = {key: label};
        }

        switch (adapter) {
          case DatasetAdapter.banking77:
            state = requiredText(row['text']);
            choice(
              'banking_intent',
              intentNames!,
              row['label'],
              'Select the banking intent.',
            );
          case DatasetAdapter.klueYnat:
            state = requiredText(row['title']);
            choice(
              'ynat_topic',
              news,
              indexedLabel(row['label'], news),
              '뉴스 제목의 주제를 고르세요.',
            );
          case DatasetAdapter.klueNli:
            state = {
              'premise': requiredText(row['premise']),
              'hypothesis': requiredText(row['hypothesis']),
            };
            choice(
              'nli_relation',
              relations,
              indexedLabel(row['label'], relations),
              '전제에 대한 가설의 관계를 고르세요.',
            );
          case DatasetAdapter.nsmc:
            state = requiredText(row['document']);
            if (row['label'] is! int ||
                (row['label'] != 0 && row['label'] != 1)) {
              throw const FormatException('NSMC label must be 0 or 1');
            }
            questions = {
              'positive': NoulQuestion(instructions: '영화에 대한 긍정적인 감상인가요?'),
            };
            labels = {'positive': row['label'] == 1};
          case DatasetAdapter.tickets:
            state =
                row['state'] ??
                (throw const FormatException('missing ticket state'));
            questions = {
              'ticket_topic': ChoiceQuestion(
                instructions: 'Which team should handle the ticket?',
                criteria: {
                  'billing': 'Payments and refunds',
                  'technical': 'Bugs and outages',
                  'sales': 'New purchases',
                },
              ),
              'ticket_refund': NoulQuestion(
                instructions: 'Does the customer request a refund?',
              ),
              'ticket_urgency': ScoreQuestion(
                instructions: 'How urgent is the ticket?',
                criteria: ['low', 'medium', 'high'],
              ),
            };
            labels = jsonObject(row['labels']);
        }
        return BenchmarkCase(
          id: '${adapter.name}:$id',
          datasetId: adapter.name,
          request: SystemOneRequest(
            model: 'benchmark-fixture',
            state: state,
            questions: questions,
          ),
          labels: labels,
          sourceSplit: 'synthetic',
          partition: 'evaluation',
        );
      }(),
  ];
}

String indexedLabel(Object? value, List<String> labels) {
  if (value is! int || value < 0 || value >= labels.length) {
    throw const FormatException('invalid source label index');
  }
  return labels[value];
}
