import 'dart:convert';
import 'dart:io';

/// Publishes the two CLI outputs, restoring prior entries on synchronous failure.
///
/// Both files are staged before any destination changes. This is not a crash-
/// atomic transaction and requires exclusive ownership of the destination paths.
/// The CLI must first reject canonical aliases among input and output paths.
/// Cleanup failures after publication return warnings, without undoing the pair.
List<String> writeCalibrationOutputs({
  required String artifactPath,
  required Object? artifact,
  required String reportPath,
  required Object? report,
}) {
  const encoder = JsonEncoder.withIndent('  ');
  // Serialization must finish for both outputs before any filesystem changes.
  final outputs = [
    _Output(artifactPath, '${encoder.convert(artifact)}\n'),
    _Output(reportPath, '${encoder.convert(report)}\n'),
  ];
  for (final output in outputs) {
    output.inspectDestination();
  }
  try {
    for (final output in outputs) {
      output.stage();
    }
    for (final output in outputs) {
      output.publish();
    }
  } on FileSystemException catch (error) {
    final failures = <String>[];
    for (final output in outputs.reversed) {
      try {
        output.restore();
      } on FileSystemException catch (rollbackError) {
        failures.add('rollback failed: $rollbackError');
      }
    }
    if (failures.isNotEmpty) {
      // An unrestored backup may be the only remaining copy. Keep all staging
      // directories for recovery, even when other destinations were restored.
      throw FileSystemException(
        '$error; ${failures.join('; ')}; recovery directories: '
        '${outputs.map((output) => output.temporary?.path).whereType<String>().join(', ')}',
        error.path,
        error.osError,
      );
    }
    final cleanupFailures = _cleanup(outputs);
    if (cleanupFailures.isNotEmpty) {
      throw FileSystemException(
        '$error; original outputs restored; ${cleanupFailures.join('; ')}',
        error.path,
        error.osError,
      );
    }
    rethrow;
  }
  // Publication is complete. Cleanup may already have removed another backup;
  // never enter rollback after this point.
  return _cleanup(
    outputs,
  ).map((warning) => 'Both outputs published; $warning').toList();
}

List<String> _cleanup(List<_Output> outputs) {
  final warnings = <String>[];
  for (final output in outputs) {
    final temporary = output.temporary;
    if (temporary == null) continue;
    try {
      temporary.deleteSync(recursive: true);
    } on FileSystemException catch (error) {
      warnings.add('cleanup failed at ${temporary.path}: $error');
    }
  }
  return warnings;
}

class _Output {
  _Output(String path, this.contents) : destination = File(path);

  final File destination;
  final String contents;
  late FileSystemEntityType originalType;
  Directory? temporary;
  FileSystemEntity? backup;
  bool published = false;

  void inspectDestination() {
    originalType = FileSystemEntity.typeSync(
      destination.path,
      followLinks: false,
    );
    if (originalType == FileSystemEntityType.file ||
        (originalType == FileSystemEntityType.link &&
            FileSystemEntity.typeSync(destination.path) !=
                FileSystemEntityType.directory))
      return;
    if (originalType == FileSystemEntityType.notFound) {
      // Dart can report devices/FIFOs as notFound. Check directory entries before
      // treating a destination as absent; an unreadable parent fails closed.
      final name = destination.uri.pathSegments.last;
      final exists = destination.parent
          .listSync(followLinks: false)
          .any((entry) => entry.uri.pathSegments.last == name);
      if (!exists) return;
    }
    throw FileSystemException(
      'Output destination must be a regular file, non-directory link, or absent',
      destination.path,
    );
  }

  void stage() {
    temporary = destination.parent.createTempSync('.edge-one-calibrate-');
    File(
      '${temporary!.path}/output.json',
    ).writeAsStringSync(contents, flush: true);
  }

  void publish() {
    final previous = '${temporary!.path}/previous';
    if (originalType == FileSystemEntityType.link) {
      backup = Link(destination.path).renameSync(previous);
    } else if (originalType == FileSystemEntityType.file) {
      backup = destination.renameSync(previous);
    }
    File('${temporary!.path}/output.json').renameSync(destination.path);
    published = true;
  }

  void restore() {
    if (published) {
      destination.deleteSync();
      published = false;
    }
    final previous = backup;
    if (previous != null) {
      previous.renameSync(destination.path);
      backup = null;
    }
  }
}
