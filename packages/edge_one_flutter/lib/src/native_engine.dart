import 'dart:async';
import 'dart:isolate';

import 'local_exception.dart';
import 'native_api.dart';

/// Owns one long-lived evaluation isolate and a separate cancellation isolate.
/// No handle can be destroyed until both sets of native callers have returned.
final class NativeEngine {
  NativeEngine._(this._evaluationWorker, this._controlWorker);

  final _Worker _evaluationWorker;
  final _Worker _controlWorker;
  Future<String>? _evaluation;
  Future<void>? _disposal;
  bool _closing = false;
  bool _cancellable = false;

  static Future<NativeEngine> open({
    required String modelPath,
    required String manifestJson,
    String? libraryPath,
  }) async {
    final evaluation = await _Worker.spawn({
      'modelPath': modelPath,
      'manifestJson': manifestJson,
      'libraryPath': libraryPath,
    });
    try {
      final control = await _Worker.spawn({
        'address': evaluation.address,
        'libraryPath': libraryPath,
      });
      return NativeEngine._(evaluation, control);
    } catch (_) {
      await evaluation.shutdown('close');
      rethrow;
    }
  }

  Future<String> evaluate(String requestJson) {
    if (_closing) return Future.error(StateError('Engine is disposed'));
    if (_evaluation != null) {
      return Future.error(const LocalEngineException(409));
    }
    _cancellable = true;
    final operation = _evaluate(requestJson);
    _evaluation = operation;
    return operation;
  }

  Future<String> _evaluate(String json) async {
    try {
      return await _evaluationWorker.call('evaluate', json) as String;
    } finally {
      _cancellable = false;
      // An arm message may arrive before eo_evaluate has entered native code.
      // Disarm joins every preceding cancel and ends the retry timer before
      // another evaluation can reset the native cancellation flag.
      try {
        await _controlWorker.call('disarm');
      } finally {
        _evaluation = null;
      }
    }
  }

  /// Latches cancellation until the current evaluation completes.
  /// Idle cancellation does not affect the next evaluation.
  Future<void> cancel() async {
    if (_closing) throw StateError('Engine is disposed');
    if (_cancellable) await _controlWorker.call('arm');
  }

  /// Prevents new calls immediately, cancels, joins, and closes exactly once.
  Future<void> dispose() {
    _closing = true;
    return _disposal ??= _dispose();
  }

  Future<void> _dispose() async {
    (Object, StackTrace)? failure;
    Future<void> cleanup(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        failure ??= (error, stack);
      }
    }

    final evaluation = _evaluation;
    if (evaluation != null) {
      if (_cancellable) {
        await cleanup(() async => await _controlWorker.call('arm'));
      }
      try {
        await evaluation;
      } catch (_) {
        // The evaluation caller receives its own status/error.
      }
    }
    await cleanup(() => _controlWorker.shutdown('stop'));
    await cleanup(() => _evaluationWorker.shutdown('close'));
    if (failure != null) {
      final (error, stack) = failure!;
      Error.throwWithStackTrace(error, stack);
    }
  }
}

final class _Worker {
  _Worker() {
    _messages.listen(_receive);
  }

  final _messages = ReceivePort();
  final _ready = Completer<void>();
  final _exited = Completer<void>();
  final _pending = <int, Completer<Object?>>{};
  SendPort? _port;
  int address = 0;
  int _nextId = 1;
  bool _failed = false;
  Isolate? _isolate;

  static Future<_Worker> spawn(Map<String, Object?> configuration) async {
    final worker = _Worker();
    try {
      worker._isolate = await Isolate.spawn(
        _workerMain,
        {...configuration, 'reply': worker._messages.sendPort},
        onError: worker._messages.sendPort,
        onExit: worker._messages.sendPort,
        errorsAreFatal: true,
        debugName: configuration.containsKey('address')
            ? 'edge-one-cancel'
            : 'edge-one-evaluate',
      );
    } catch (_) {
      worker._closePorts();
      rethrow;
    }
    try {
      await worker._ready.future;
      return worker;
    } catch (_) {
      await worker.join();
      rethrow;
    }
  }

  void _receive(dynamic message) {
    if (message == null) {
      _fail();
      _exited.complete();
      return;
    }
    if (message is List) {
      _fail();
      return;
    }
    final data = message as Map;
    final id = data['id'] as int;
    if (id == 0) {
      if (data['status'] != null) {
        _ready.completeError(LocalEngineException(data['status'] as int));
      } else {
        _port = data['port'] as SendPort;
        address = data['address'] as int;
        _ready.complete();
      }
      return;
    }
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (data['status'] != null) {
      completer.completeError(LocalEngineException(data['status'] as int));
    } else {
      completer.complete(data['value']);
    }
  }

  Future<Object?> call(String command, [String? value]) {
    if (_failed) return Future.error(const LocalEngineException(503));
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _port!.send({'id': id, 'command': command, 'value': value});
    return completer.future;
  }

  void _fail() {
    _failed = true;
    if (!_ready.isCompleted) {
      _ready.completeError(const LocalEngineException(503));
    }
    for (final pending in _pending.values) {
      pending.completeError(const LocalEngineException(503));
    }
    _pending.clear();
  }

  Future<void> join() async {
    await _exited.future;
    _closePorts();
  }

  Future<void> shutdown(String command) async {
    try {
      await call(command);
    } finally {
      await join();
    }
  }

  void _closePorts() {
    _messages.close();
  }
}

void _workerMain(Map<String, Object?> configuration) {
  final reply = configuration['reply'] as SendPort;
  final control = configuration.containsKey('address');
  late NativeApi api;
  var address = 0;
  try {
    api = NativeApi(configuration['libraryPath'] as String?);
    address = control
        ? configuration['address'] as int
        : api.open(
            configuration['modelPath'] as String,
            configuration['manifestJson'] as String,
          );
  } catch (error) {
    reply.send({'id': 0, 'status': _status(error)});
    return;
  }
  final commands = ReceivePort();
  Timer? cancellation;
  reply.send({'id': 0, 'port': commands.sendPort, 'address': address});
  commands.listen((dynamic message) {
    final data = message as Map;
    final id = data['id'] as int;
    try {
      Object? result;
      switch (data['command']) {
        case 'evaluate':
          result = api.evaluate(address, data['value'] as String);
        case 'arm':
          api.cancel(address);
          cancellation ??= Timer.periodic(
            const Duration(milliseconds: 1),
            (_) => api.cancel(address),
          );
        case 'disarm':
          cancellation?.cancel();
          cancellation = null;
        case 'stop':
          cancellation?.cancel();
          commands.close();
        case 'close':
          api.close(address);
          commands.close();
        default:
          throw StateError('Unknown worker command');
      }
      reply.send({'id': id, 'value': result});
    } catch (error) {
      reply.send({'id': id, 'status': _status(error)});
    } finally {
      if (data['command'] == 'close' || data['command'] == 'stop') {
        commands.close();
      }
    }
  });
}

int _status(Object error) =>
    error is LocalEngineException ? error.statusCode : 503;

// Internal fault-injection seam. A kill during FFI is observed only after the
// native call returns; onExit remains the synchronization boundary.
Future<void> terminateControlWorker(NativeEngine engine) async {
  engine._controlWorker._isolate!.kill(priority: Isolate.immediate);
  await engine._controlWorker._exited.future;
}
