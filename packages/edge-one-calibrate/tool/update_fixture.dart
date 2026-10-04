// Regenerates synthetic inputs only. Baselines require explicit review; this
// tool deliberately does not regenerate them as part of a test or CI run.
import 'dart:io';

import '../test/support.dart';

void main() {
  File('test/fixtures/labeled.jsonl')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${jsonl(fixture())}\n');
}
