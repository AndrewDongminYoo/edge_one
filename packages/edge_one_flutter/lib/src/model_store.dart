import 'dart:async';
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
  HttpModelTransport({this.responseHeaderTimeout = const Duration(seconds: 60)})
    : _client = HttpClient() {
    _client.connectionTimeout = responseHeaderTimeout;
  }

  final HttpClient _client;
  final Duration responseHeaderTimeout;

  @override
  Future<ModelResponse> get(Uri url, {required int start}) async {
    final request = await _client.getUrl(url);
    if (start > 0)
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
    final response = await request.close().timeout(
      responseHeaderTimeout,
      onTimeout: () {
        final error = TimeoutException(
          'Model response headers timed out',
          responseHeaderTimeout,
        );
        request.abort(error);
        throw error;
      },
    );
    return ModelResponse(
      statusCode: response.statusCode,
      body: response,
      contentRange: response.headers.value(HttpHeaders.contentRangeHeader),
      contentLength:
          response.compressionState ==
                  HttpClientResponseCompressionState.decompressed ||
              response.contentLength < 0
          ? null
          : response.contentLength,
    );
  }

  void close() => _client.close();
}

/// Download and verify one app-pinned revision before exposing its path.
///
/// [root] must be durable application storage. The platform layer supplies its
/// free-space check and excludes this directory from backups where required.
/// Use one store instance per destination; independent instances and isolates are not coordinated here.
final class ModelStore {
  ModelStore({
    required this.root,
    required this.manifest,
    required this.transport,
    required this.freeBytes,
    CommitModel? commit,
    this.idleTimeout = const Duration(seconds: 60),
  }) : _commit = commit ?? _rename;

  final Directory root;
  final ModelManifest manifest;
  final ModelTransport transport;
  final FreeBytes freeBytes;
  final Duration idleTimeout;
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
    final partial = File('${destination.path}.part');
    if (await partial.exists()) {
      final length = await partial.length();
      if (length == manifest.bytes && await _verified(partial)) {
        try {
          await _commit(partial, destination);
          if (await _verified(destination)) {
            return VerifiedModel(destination, manifest);
          }
          throw ModelDownloadException('Committed model failed verification');
        } catch (error) {
          throw ModelDownloadException(
            'Could not commit verified model: $error',
          );
        }
      }
      if (length >= manifest.bytes) await partial.delete();
    }
    if (await freeBytes(root) < manifest.bytes * 2) {
      throw ModelDownloadException(
        'Insufficient free space for model download',
      );
    }
    Object? lastFailure;
    for (final url in manifest.downloadUrls) {
      var retriedFromZero = false;
      while (true) {
        try {
          var resumed = false;
          try {
            resumed = await _download(url, partial, onProgress);
          } catch (_) {
            if (!await _verified(partial)) rethrow;
          }
          if (!await _verified(partial)) {
            await partial.delete();
            if (resumed && !retriedFromZero) {
              retriedFromZero = true;
              continue;
            }
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
          break;
        }
      }
    }
    throw ModelDownloadException('All model sources failed: $lastFailure');
  }

  Future<bool> _download(
    Uri url,
    File partial,
    DownloadProgress? onProgress,
  ) async {
    var start = await partial.exists() ? await partial.length() : 0;
    if (start > manifest.bytes) {
      await partial.delete();
      start = 0;
    }
    if (start == manifest.bytes) return true;
    final response = await transport.get(url, start: start);
    late RandomAccessFile output;
    try {
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
      if (response.contentLength != null &&
          response.contentLength != expected) {
        throw ModelDownloadException('Invalid content length from $url');
      }
      output = await partial.open(mode: FileMode.append);
    } catch (_) {
      await _discardResponse(response);
      rethrow;
    }
    var received = start;
    try {
      await for (final chunk in response.body.timeout(idleTimeout)) {
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
    return start > 0;
  }

  static Future<void> _discardResponse(ModelResponse response) async {
    final subscription = response.body.listen(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    await subscription.cancel();
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
