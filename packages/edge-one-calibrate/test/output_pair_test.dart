import 'dart:convert';
import 'dart:io';

import 'package:edge_one_calibrate/src/output_pair.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late File report;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('calibration-output-test-');
    artifact = File('${temporary.path}/thresholds.json');
    report = File('${temporary.path}/report.json');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  List<String> write() => writeCalibrationOutputs(
    artifactPath: artifact.path,
    artifact: {'new': 'artifact'},
    reportPath: report.path,
    report: {'new': 'report'},
  );
  List<FileSystemEntity> recoveryDirectories() => temporary
      .listSync()
      .where((entry) => entry.path.contains('.edge-one-calibrate-'))
      .toList();

  for (final oldArtifact in [false, true]) {
    for (final oldReport in [false, true]) {
      test(
        'second publication failure restores prior pair ($oldArtifact, $oldReport)',
        () {
          if (oldArtifact) artifact.writeAsStringSync('old artifact');
          if (oldReport) report.writeAsStringSync('old report');
          final faults = _Faults((operation, source, destination) {
            if (operation == 'rename' &&
                source.endsWith('/output.json') &&
                destination == report.path) {
              throw FileSystemException(
                'injected second publication failure',
                source,
              );
            }
          });
          expect(
            () => IOOverrides.runWithIOOverrides(write, faults),
            throwsA(isA<FileSystemException>()),
          );
          expect(artifact.existsSync(), oldArtifact);
          expect(report.existsSync(), oldReport);
          if (oldArtifact) expect(artifact.readAsStringSync(), 'old artifact');
          if (oldReport) expect(report.readAsStringSync(), 'old report');
          expect(recoveryDirectories(), isEmpty);
        },
      );
    }
  }

  for (final failAt in [1, 2]) {
    test(
      'staging write failure $failAt preserves old pair and cleans staging',
      () {
        artifact.writeAsStringSync('old artifact');
        report.writeAsStringSync('old report');
        var writes = 0;
        final faults = _Faults((operation, source, destination) {
          if (operation == 'write' && ++writes == failAt) {
            throw FileSystemException('injected staging failure', source);
          }
        });
        expect(
          () => IOOverrides.runWithIOOverrides(write, faults),
          throwsA(isA<FileSystemException>()),
        );
        expect(artifact.readAsStringSync(), 'old artifact');
        expect(report.readAsStringSync(), 'old report');
        expect(recoveryDirectories(), isEmpty);
      },
    );
  }

  for (final failAt in [1, 2, 3, 4]) {
    test('rename failure $failAt restores both existing entries', () {
      artifact.writeAsStringSync('old artifact');
      report.writeAsStringSync('old report');
      var renames = 0;
      final faults = _Faults((operation, source, destination) {
        if (operation == 'rename' && ++renames == failAt) {
          throw FileSystemException('injected rename failure', source);
        }
      });
      expect(
        () => IOOverrides.runWithIOOverrides(write, faults),
        throwsA(isA<FileSystemException>()),
      );
      expect(artifact.readAsStringSync(), 'old artifact');
      expect(report.readAsStringSync(), 'old report');
      expect(recoveryDirectories(), isEmpty);
    });
  }

  for (final dangling in [false, true]) {
    test(
      'rollback restores exact ${dangling ? 'dangling' : 'relative'} symlink entry',
      () {
        final target = File('${temporary.path}/target');
        if (!dangling) target.writeAsStringSync('target stays unchanged');
        Link(artifact.path).createSync('target');
        report.writeAsStringSync('old report');
        final faults = _Faults((operation, source, destination) {
          if (operation == 'rename' &&
              source.endsWith('/output.json') &&
              destination == report.path) {
            throw FileSystemException(
              'injected second publication failure',
              source,
            );
          }
        });
        expect(
          () => IOOverrides.runWithIOOverrides(write, faults),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          FileSystemEntity.typeSync(artifact.path, followLinks: false),
          FileSystemEntityType.link,
        );
        expect(Link(artifact.path).targetSync(), 'target');
        expect(target.existsSync(), !dangling);
        if (!dangling)
          expect(target.readAsStringSync(), 'target stays unchanged');
        expect(report.readAsStringSync(), 'old report');
        expect(recoveryDirectories(), isEmpty);
      },
    );
  }

  test(
    'failed rollback retains old backup and attempts remaining restoration',
    () {
      artifact.writeAsStringSync('old artifact');
      report.writeAsStringSync('old report');
      final faults = _Faults((operation, source, destination) {
        if (operation == 'rename' && destination == report.path) {
          throw FileSystemException(
            'injected publish or report restore failure',
            source,
          );
        }
      });
      FileSystemException? failure;
      try {
        IOOverrides.runWithIOOverrides(write, faults);
      } on FileSystemException catch (error) {
        failure = error;
      }
      expect(failure, isNotNull);
      expect(artifact.readAsStringSync(), 'old artifact');
      expect(report.existsSync(), isFalse);
      final retained = recoveryDirectories();
      expect(retained, isNotEmpty);
      final backups = retained
          .expand((entry) => Directory(entry.path).listSync())
          .whereType<File>();
      final backup = backups.singleWhere(
        (file) => file.readAsStringSync() == 'old report',
      );
      expect(failure.toString(), contains(backup.parent.path));
      expect(failure.toString(), contains('rollback'));
    },
  );

  test(
    'cleanup failure after success keeps new pair and reports recovery directory',
    () {
      artifact.writeAsStringSync('old artifact');
      report.writeAsStringSync('old report');
      var deletions = 0;
      final faults = _Faults((operation, source, destination) {
        if (operation == 'delete directory' && ++deletions == 2) {
          throw FileSystemException('injected cleanup failure', source);
        }
      });
      final warnings = IOOverrides.runWithIOOverrides(write, faults);
      expect(jsonDecode(artifact.readAsStringSync()), {'new': 'artifact'});
      expect(jsonDecode(report.readAsStringSync()), {'new': 'report'});
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('published'));
      final retained = recoveryDirectories();
      expect(retained, hasLength(1));
      expect(warnings.single, contains(retained.single.path));
      expect(
        File('${retained.single.path}/previous').readAsStringSync(),
        'old report',
      );
    },
  );

  test(
    'failed publication keeps its error when rollback cleanup also fails',
    () {
      artifact.writeAsStringSync('old artifact');
      report.writeAsStringSync('old report');
      var cleanups = 0;
      final faults = _Faults((operation, source, destination) {
        if (operation == 'rename' &&
            source.endsWith('/output.json') &&
            destination == report.path) {
          throw FileSystemException('injected publication failure', source);
        }
        if (operation == 'delete directory' && ++cleanups == 1) {
          throw FileSystemException('injected cleanup failure', source);
        }
      });
      expect(
        () => IOOverrides.runWithIOOverrides(write, faults),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'original failure and cleanup context',
            allOf(
              contains('injected publication failure'),
              contains('original outputs restored'),
              contains('injected cleanup failure'),
            ),
          ),
        ),
      );
      expect(artifact.readAsStringSync(), 'old artifact');
      expect(report.readAsStringSync(), 'old report');
      expect(recoveryDirectories(), hasLength(1));
    },
  );

  test(
    'successful replacement publishes both and removes staging and backups',
    () {
      artifact.writeAsStringSync('old artifact');
      report.writeAsStringSync('old report');
      expect(write(), isEmpty);
      expect(jsonDecode(artifact.readAsStringSync()), {'new': 'artifact'});
      expect(jsonDecode(report.readAsStringSync()), {'new': 'report'});
      expect(recoveryDirectories(), isEmpty);
    },
  );

  test('FIFO destination is rejected without changing either entry', () {
    artifact.writeAsStringSync('old artifact');
    final made = Process.runSync('mkfifo', [report.path]);
    expect(made.exitCode, 0, reason: '${made.stderr}');
    expect(write, throwsA(isA<FileSystemException>()));
    expect(artifact.readAsStringSync(), 'old artifact');
    expect(
      temporary.listSync().any((entry) => entry.path == report.path),
      isTrue,
    );
    expect(recoveryDirectories(), isEmpty);
  }, skip: !Platform.isLinux);

  test('directory-target link is rejected before either output changes', () {
    artifact.writeAsStringSync('old artifact');
    final target = Directory('${temporary.path}/target')..createSync();
    Link(report.path).createSync(target.path);
    expect(write, throwsA(isA<FileSystemException>()));
    expect(artifact.readAsStringSync(), 'old artifact');
    expect(Link(report.path).targetSync(), target.path);
    expect(target.listSync(), isEmpty);
    expect(recoveryDirectories(), isEmpty);
  });
}

typedef _Fault =
    void Function(String operation, String source, String? destination);

final class _Faults extends IOOverrides {
  _Faults(this.fault);
  final _Fault fault;
  @override
  File createFile(String path) => _FaultFile(super.createFile(path), this);
  @override
  Directory createDirectory(String path) =>
      _FaultDirectory(super.createDirectory(path), this);
}

class _FaultFile implements File {
  _FaultFile(this.file, this.faults);
  final File file;
  final _Faults faults;
  @override
  String get path => file.path;
  @override
  Uri get uri => file.uri;
  @override
  Directory get parent => faults.createDirectory(file.parent.path);
  @override
  File renameSync(String newPath) {
    faults.fault('rename', path, newPath);
    return file.renameSync(newPath);
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    faults.fault('write', path, null);
    file.writeAsStringSync(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  void deleteSync({bool recursive = false}) {
    faults.fault('delete file', path, null);
    file.deleteSync(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FaultDirectory implements Directory {
  _FaultDirectory(this.directory, this.faults);
  final Directory directory;
  final _Faults faults;
  @override
  String get path => directory.path;
  @override
  Directory createTempSync([String? prefix]) =>
      directory.createTempSync(prefix);
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => directory.listSync(recursive: recursive, followLinks: followLinks);
  @override
  void deleteSync({bool recursive = false}) {
    faults.fault('delete directory', path, null);
    directory.deleteSync(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
