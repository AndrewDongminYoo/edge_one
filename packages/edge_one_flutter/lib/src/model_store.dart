import 'dart:io';

import 'package:crypto/crypto.dart';

import 'model_manifest.dart';

typedef FreeBytes = Future<int> Function(Directory directory);
typedef CommitModel = Future<void> Function(File partial, File destination);
typedef DownloadProgress = void Function(int received, int total);

final class VerifiedModel {
  const VerifiedModel(this.file, this.manifest);

  final File file;
  final ModelManifest manifest;
}

final class ModelDownloadException extends IOException {
  ModelDownloadException(this.message);

  final String message;

  @override
  String toString() => 'ModelDownloadException: $message';
}

final class ModelResponse {
  const ModelResponse({
    required this.statusCode,
    required this.body,
    this.contentRange,
    this.contentLength,
  });

  final int statusCode;
  final Stream<List<int>> body;
  final String? contentRange;
  final int? contentLength;
}

abstract interface class ModelTransport {
  Future<ModelResponse> get(Uri url, {required int start});
}

final class HttpModelTransport implements ModelTransport {
  HttpModelTransport() : _client = HttpClient();

  final HttpClient _client;

  @override
  Future<ModelResponse> get(Uri url, {required int start}) async {
    final request = await _client.getUrl(url);
    if (start > 0)
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
    final response = await request.close();
    return ModelResponse(
      statusCode: response.statusCode,
      body: response,
      contentRange: response.headers.value(HttpHeaders.contentRangeHeader),
      contentLength: response.contentLength < 0 ? null : response.contentLength,
    );
  }

  void close() => _client.close();
}

/// Download and verify one app-pinned revision before exposing its path.
///
/// [root] must be durable application storage. The platform layer supplies its
/// free-space check and excludes this directory from backups where required.
final class ModelStore {
  ModelStore({
    required this.root,
    required this.manifest,
    required this.transport,
    required this.freeBytes,
    CommitModel? commit,
  }) : _commit = commit ?? _rename;

  final Directory root;
  final ModelManifest manifest;
  final ModelTransport transport;
  final FreeBytes freeBytes;
  final CommitModel _commit;
  Future<VerifiedModel>? _pending;

  Future<VerifiedModel> ensure({DownloadProgress? onProgress}) async {
    if (_pending != null) return _pending!;
    final operation = _ensure(onProgress: onProgress);
    _pending = operation;
    try {
      return await operation;
    } finally {
      _pending = null;
    }
  }

  Future<VerifiedModel> _ensure({DownloadProgress? onProgress}) async {
    await root.create(recursive: true);
    final destination = File(
      '${root.path}/${manifest.id}-${manifest.revision}-${manifest.file}',
    );
    if (await _verified(destination)) {
      return VerifiedModel(destination, manifest);
    }
    if (await freeBytes(root) < manifest.bytes * 2) {
      throw ModelDownloadException(
        'Insufficient free space for model download',
      );
    }
    final partial = File('${destination.path}.part');
    Object? lastFailure;
    for (final url in manifest.downloadUrls) {
      try {
        await _download(url, partial, onProgress);
        if (!await _verified(partial)) {
          await partial.delete();
          throw ModelDownloadException(
            'Downloaded model digest or size mismatch',
          );
        }
        await _commit(partial, destination);
        if (!await _verified(destination)) {
          throw ModelDownloadException('Committed model failed verification');
        }
        return VerifiedModel(destination, manifest);
      } catch (error) {
        lastFailure = error;
      }
    }
    throw ModelDownloadException('All model sources failed: $lastFailure');
  }

  Future<void> _download(
    Uri url,
    File partial,
    DownloadProgress? onProgress,
  ) async {
    var start = await partial.exists() ? await partial.length() : 0;
    if (start > manifest.bytes) {
      await partial.delete();
      start = 0;
    }
    if (start == manifest.bytes) return;
    final response = await transport.get(url, start: start);
    if (response.statusCode == HttpStatus.ok) {
      if (start > 0) {
        await partial.delete();
        start = 0;
      }
    } else if (response.statusCode == HttpStatus.partialContent) {
      final match = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+)$',
      ).firstMatch(response.contentRange ?? '');
      if (match == null ||
          int.parse(match[1]!) != start ||
          int.parse(match[2]!) != manifest.bytes - 1 ||
          int.parse(match[3]!) != manifest.bytes) {
        throw ModelDownloadException('Invalid range response from $url');
      }
    } else {
      throw ModelDownloadException('HTTP ${response.statusCode} from $url');
    }
    final expected = manifest.bytes - start;
    if (response.contentLength != null && response.contentLength != expected) {
      throw ModelDownloadException('Invalid content length from $url');
    }
    var received = start;
    final output = await partial.open(mode: FileMode.append);
    try {
      await for (final chunk in response.body) {
        received += chunk.length;
        if (received > manifest.bytes) {
          throw ModelDownloadException('Model response exceeds expected size');
        }
        await output.writeFrom(chunk);
        onProgress?.call(received, manifest.bytes);
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (received != manifest.bytes) {
      throw ModelDownloadException('Truncated model response from $url');
    }
  }

  Future<bool> _verified(File file) async {
    if (!await file.exists() || await file.length() != manifest.bytes) {
      return false;
    }
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == manifest.sha256;
  }

  static Future<void> _rename(File partial, File destination) async {
    await partial.rename(destination.path);
  }
}
