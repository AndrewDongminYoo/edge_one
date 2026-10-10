import 'dart:ffi';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final os = code.targetOS;
    if (os != OS.macOS && os != OS.iOS && os != OS.linux) {
      throw UnsupportedError(
        'The edge_one CMake hook supports macOS, iOS, and Linux',
      );
    }
    final core = input.packageRoot.resolve('../edge_one_core/');
    if (!Directory.fromUri(core).existsSync()) {
      throw StateError(
        'Build edge_one_flutter from the repository workspace with edge_one_core',
      );
    }
    final buildDir = input.outputDirectory.resolve('cmake/');
    final cmake = input.userDefines['cmake'] as String? ?? 'cmake';
    final flags = <String>[
      '-G', 'Unix Makefiles',
      '-S', core.toFilePath(), '-B', buildDir.toFilePath(),
      '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_TESTING=OFF',
      // Bundle one shared core; its pinned llama/ggml dependencies are static.
      '-DBUILD_SHARED_LIBS=OFF', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
      '-DGGML_METAL=OFF', '-DGGML_BLAS=OFF', '-DGGML_OPENMP=OFF',
      '-DGGML_CPU_ALL_VARIANTS=OFF',
    ];
    if (os == OS.macOS || os == OS.iOS) {
      if (code.targetArchitecture != Architecture.arm64 &&
          code.targetArchitecture != Architecture.x64) {
        throw UnsupportedError('Apple targets require arm64 or x64');
      }
      flags.addAll([
        '-DCMAKE_OSX_ARCHITECTURES=${code.targetArchitecture == Architecture.arm64 ? 'arm64' : 'x86_64'}',
        '-DCMAKE_INSTALL_NAME_DIR=@rpath',
      ]);
      if (os == OS.iOS) {
        flags.addAll([
          '-DCMAKE_SYSTEM_NAME=iOS',
          '-DCMAKE_OSX_SYSROOT=${code.iOS.targetSdk == IOSSdk.iPhoneOS ? 'iphoneos' : 'iphonesimulator'}',
          '-DCMAKE_OSX_DEPLOYMENT_TARGET=${code.iOS.targetVersion}.0',
        ]);
      } else {
        flags.add(
          '-DCMAKE_OSX_DEPLOYMENT_TARGET=${code.macOS.targetVersion}.0',
        );
      }
    } else {
      final hostArchitecture = Abi.current() == Abi.linuxArm64
          ? Architecture.arm64
          : Architecture.x64;
      if (!Platform.isLinux || code.targetArchitecture != hostArchitecture) {
        throw UnsupportedError('Linux cross compilation is not configured');
      }
    }
    await _run(cmake, flags);
    await _run(cmake, [
      '--build',
      buildDir.toFilePath(),
      '--target',
      'edge_one_core',
      '--parallel',
      '2',
    ]);
    final name = os.dylibFileName('edge_one_core');
    final library = input.outputDirectory.resolve(name);
    await File.fromUri(buildDir.resolve(name)).copy(library.toFilePath());
    if (os == OS.macOS || os == OS.iOS) {
      await _run('install_name_tool', [
        '-id',
        '@rpath/$name',
        library.toFilePath(),
      ]);
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/generated/edge_one_native.dart',
        linkMode: DynamicLoadingBundled(),
        file: library,
      ),
    );
    // Directory dependencies capture additions (including a future scorer).
    output.dependencies.add(core);
    await for (final entry in Directory.fromUri(core).list(recursive: true)) {
      if (entry is File) output.dependencies.add(entry.uri);
    }
  });
}

Future<void> _run(String executable, List<String> arguments) async {
  final process = await Process.start(executable, arguments);
  final stdoutDone = stdout.addStream(process.stdout);
  final stderrDone = stderr.addStream(process.stderr);
  final code = await process.exitCode;
  await Future.wait([stdoutDone, stderrDone]);
  if (code != 0)
    throw ProcessException(executable, arguments, 'Native build failed', code);
}
