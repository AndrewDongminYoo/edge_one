import 'dart:convert';
import 'dart:io';

import 'package:edge_one/edge_one.dart';
import 'package:test/test.dart';

/// Reads a JSON file relative to the repository root.
Object? readRepoJson(String path) => jsonDecode(readRepoText(path));

/// Reads a text file relative to the repository root.
String readRepoText(String path) {
  var directory = Directory.current.absolute;
  while (true) {
    final file = File('${directory.path}/$path');
    if (file.existsSync()) {
      return file.readAsStringSync();
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('$path not found above ${Directory.current.path}');
    }
    directory = parent;
  }
}

/// Matches a [SystemOneFormatException] reported at [pointer].
Matcher throwsFormatAt(String pointer) => throwsA(
  isA<SystemOneFormatException>().having((e) => e.pointer, 'pointer', pointer),
);

/// Returns a mutable deep copy of a JSON value.
Object? copyJson(Object? value) => jsonDecode(jsonEncode(value));
