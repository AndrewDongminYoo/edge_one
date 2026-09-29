import 'package:edge_one/edge_one.dart';
import 'package:test/test.dart';

import 'support.dart';

typedef Json = Map<String, Object?>;

void main() {
  final schema = readRepoJson('schemas/system-one-v1.schema.json') as Json;
  final definitions = schema['definitions'] as Json;
  final corpus =
      readRepoJson('schemas/fixtures/system-one-v1-cases.json') as Json;
  final decoders = <String, Object Function(Object?)>{
    'SystemOneRequest': SystemOneJson.decodeRequest,
    'SystemOneResponse': SystemOneJson.decodeResponse,
  };
  final encoders = <String, Json Function(Object)>{
    'SystemOneRequest': (value) =>
        SystemOneJson.encodeRequest(value as SystemOneRequest),
    'SystemOneResponse': (value) =>
        SystemOneJson.encodeResponse(value as SystemOneResponse),
  };
  // Valid cases whose explicit nulls are omitted on encode.
  const nullDroppingCases = {
    'string state and null optional values',
    'null extension values',
  };

  group('shared Ajv corpus', () {
    test('covers the request and response definitions', () {
      expect(corpus.keys, unorderedEquals(decoders.keys));
    });
    for (final MapEntry(key: definition, value: cases) in corpus.entries) {
      final decode = decoders[definition]!;
      final encode = encoders[definition]!;
      for (final valid in (cases as Json)['valid'] as List) {
        final {'name': name, 'value': value} = valid as Json;
        test('$definition accepts $name', () {
          final encoded = encode(decode(value));
          if (!nullDroppingCases.contains(name)) {
            expect(encoded, equals(value));
          }
          expect(encode(decode(encoded)), equals(encoded));
        });
      }
      for (final invalid in cases['invalid'] as List) {
        final {'name': name, 'value': value} = invalid as Json;
        test('$definition rejects $name', () {
          expect(() => decode(value), throwsA(isA<SystemOneFormatException>()));
        });
      }
    }
  });

  group('schema definitions', () {
    // Where each object definition occurs in the first valid corpus document.
    const samples = <String, (String, List<String>)>{
      'SystemOneRequest': ('SystemOneRequest', []),
      'ChoiceQuestion': ('SystemOneRequest', ['questions', 'team']),
      'NoulQuestion': ('SystemOneRequest', ['questions', 'urgent']),
      'ScoreQuestion': ('SystemOneRequest', ['questions', 'impact']),
      'SystemOneResponse': ('SystemOneResponse', []),
      'ChoiceAnswer': ('SystemOneResponse', ['answers', 'team']),
      'NoulAnswer': ('SystemOneResponse', ['answers', 'urgent']),
      'ScoreAnswer': ('SystemOneResponse', ['answers', 'impact']),
      'Usage': ('SystemOneResponse', ['usage']),
    };
    final generatedTypes = {
      'ChoiceQuestion': const ChoiceQuestion(criteria: {}).type,
      'NoulQuestion': const NoulQuestion().type,
      'ScoreQuestion': const ScoreQuestion(criteria: []).type,
      'ChoiceAnswer': const ChoiceAnswer(
        choice: '',
        probabilities: {},
        confidence: 0,
      ).type,
      'NoulAnswer': const NoulAnswer(noul: 0).type,
      'ScoreAnswer': const ScoreAnswer(
        score: 0,
        legend: {},
        probabilities: {},
        confidence: 0,
      ).type,
    };

    test('every object definition has a probe sample', () {
      expect(
        samples.keys,
        unorderedEquals([
          for (final MapEntry(:key, :value) in definitions.entries)
            if ((value as Json).containsKey('properties')) key,
        ]),
      );
    });

    for (final MapEntry(key: name, value: (root, path)) in samples.entries) {
      final definition = definitions[name] as Json;
      final properties = (definition['properties'] as Json).keys;
      final required = (definition['required'] as List).cast<String>();
      final decode = decoders[root]!;
      final sample = ((corpus[root] as Json)['valid'] as List).first as Json;
      final pointer = path.map((key) => '/$key').join();

      Json probe(void Function(Json object) edit) {
        final document = copyJson(sample['value']) as Json;
        var object = document;
        for (final key in path) {
          object = object[key] as Json;
        }
        edit(object);
        return document;
      }

      test('$name sample exercises every declared property', () {
        probe((object) => expect(object.keys, containsAll(properties)));
      });

      for (final property in properties) {
        final isRequired = required.contains(property);
        test(
          '$name ${isRequired ? 'requires' : 'allows omitting'} $property',
          () {
            final document = probe((object) => object.remove(property));
            if (isRequired) {
              expect(() => decode(document), throwsFormatAt(pointer));
            } else {
              expect(() => decode(document), returnsNormally);
            }
          },
        );
      }

      final extensions = definition['patternProperties'] != null;
      test(
        '$name ${extensions ? 'keeps' : 'rejects'} undeclared x_ fields',
        () {
          final document = probe((object) => object['x_probe'] = [1]);
          if (extensions) {
            final response = decode(document) as SystemOneResponse;
            expect(response.xExtensions['x_probe'], [1]);
          } else {
            expect(() => decode(document), throwsFormatAt('$pointer/x_probe'));
          }
        },
      );

      test('$name rejects undeclared fields', () {
        final document = probe((object) => object['probe'] = true);
        expect(() => decode(document), throwsFormatAt('$pointer/probe'));
      });

      final type = (definition['properties'] as Json)['type'] as Json?;
      if (type != null) {
        test('$name type matches the generated class', () {
          expect(generatedTypes[name], type['const']);
        });
      }
    }

    test('x_route accepts exactly the schema enum', () {
      final routes =
          ((definitions['SystemOneResponse'] as Json)['properties']
                  as Json)['x_route']
              as Json;
      final sample =
          ((corpus['SystemOneResponse'] as Json)['valid'] as List).first
              as Json;
      for (final route in routes['enum'] as List) {
        final document = copyJson(sample['value']) as Json..['x_route'] = route;
        expect(SystemOneJson.decodeResponse(document).xRoute, route);
      }
    });
  });
}
