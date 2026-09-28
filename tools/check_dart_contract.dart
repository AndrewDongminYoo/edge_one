import 'dart:convert';

import 'package:edge_one/edge_one.dart';

void main() {
  final probability = jsonDecode('1') as num;
  final latency = jsonDecode('120') as num;
  final answer = ChoiceAnswer(
    choice: 'yes',
    probabilities: {'yes': probability},
    confidence: probability,
  );
  final response = SystemOneResponse(
    model: 'model-revision',
    answers: {'decision': answer},
    usage: const Usage(inputTokens: 12, outputTokens: 2),
    xLatencyMs: latency,
  );
  assert(response.xLatencyMs == 120);
  assert(answer.probabilities['yes'] == 1);
}
