import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// The digest is compiled into the app, so replacing the bundled asset alone
/// cannot change the trusted model or its download endpoints.
const pinnedModelManifestSha256 =
    'e1f063a43727c94436bc429cb87e82cb444b1411ffe074c10bcda721c5538bb0';

final class ModelManifest {
  ModelManifest._({
    required this.id,
    required this.revision,
    required this.file,
    required this.sha256,
    required this.bytes,
    required this.template,
    required this.readout,
    required this.slotTokens,
    required this.limits,
    required this.license,
    required this.source,
    required this.mirrors,
  });

  final String id;
  final String revision;
  final String file;
  final String sha256;
  final int bytes;
  final String template;
  final String readout;
  final Map<String, int> slotTokens;
  final Map<String, int> limits;
  final String license;
  final Uri source;
  final List<Uri> mirrors;

  Iterable<Uri> get downloadUrls sync* {
    yield source;
    yield* mirrors;
  }

  /// Only bytes matching an app-pinned digest may define a model or URL.
  static ModelManifest parseBundled(
    Uint8List bytes, {
    required String expectedSha256,
  }) {
    if (crypto.sha256.convert(bytes).toString() != expectedSha256) {
      throw const FormatException('Bundled model manifest digest mismatch');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Model manifest must be an object');
    }
    final id = _string(decoded, 'id');
    final revision = _string(decoded, 'revision');
    final file = _string(decoded, 'file');
    final hash = _string(decoded, 'sha256');
    final size = _positiveInt(decoded, 'bytes');
    if (!RegExp(r'^[a-z0-9]+(?:[.-][a-z0-9]+)*$').hasMatch(id) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(revision) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(file)) {
      throw const FormatException('Invalid model identity or file');
    }
    final source = _url(decoded['source']);
    if (source.pathSegments.length < 3 ||
        source.pathSegments[source.pathSegments.length - 3] != 'resolve' ||
        source.pathSegments[source.pathSegments.length - 2] != revision ||
        source.pathSegments.last != file) {
      throw const FormatException(
        'Source must use the pinned revision and file',
      );
    }
    final rawMirrors = decoded['mirrors'];
    if (rawMirrors is! List) {
      throw const FormatException('mirrors must be a list');
    }
    final mirrors = rawMirrors.map(_url).toList(growable: false);
    return ModelManifest._(
      id: id,
      revision: revision,
      file: file,
      sha256: hash,
      bytes: size,
      template: _string(decoded, 'template'),
      readout: _string(decoded, 'readout'),
      slotTokens: _intMap(decoded, 'slot_tokens', const [
        'yes',
        'no',
        'verdict_slot',
      ]),
      limits: _intMap(decoded, 'limits', const [
        'max_options',
        'max_levels',
        'n_ctx',
      ]),
      license: _string(decoded, 'license'),
      source: source,
      mirrors: mirrors,
    );
  }

  static String _string(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('$key must be a nonempty string');
    }
    return value;
  }

  static int _positiveInt(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! int || value <= 0) {
      throw FormatException('$key must be a positive integer');
    }
    return value;
  }

  static Map<String, int> _intMap(
    Map<String, dynamic> map,
    String key,
    List<String> requiredKeys,
  ) {
    final value = map[key];
    if (value is! Map<String, dynamic>) {
      throw FormatException('$key must be an object');
    }
    return Map.unmodifiable({
      for (final name in requiredKeys) name: _positiveInt(value, name),
    });
  }

  static Uri _url(Object? value) {
    if (value is! String) {
      throw const FormatException('Model URL must be a string');
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Model URL must be an HTTPS URL');
    }
    return uri;
  }
}
