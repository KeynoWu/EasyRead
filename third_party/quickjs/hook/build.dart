// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// 本地 fork：适配 native_assets_cli 0.18 API（Flutter 3.44 hooks 协议）
// ignore_for_file: unnecessary_null_comparison
import 'dart:io';

import 'package:native_assets_cli/code_assets.dart';
import 'package:native_assets_cli/native_assets_cli.dart';
import 'package:path/path.dart' as p;

const packageName = 'easy_quickjs';
const _repoLibName = 'libquickjs.so';

/// Implements the protocol from `package:native_assets_cli` by building
/// the C code in `src/` and reporting what native assets it built.
void main(List<String> args) async {
  await build(args, _build);
}

Future<void> _build(BuildInput input, BuildOutputBuilder output) async {
  final pkgRoot = input.packageRoot;
  final srcDir = pkgRoot.resolve('src');
  // 平台未请求 code assets（如部分 iOS 配置）时静默跳过，不产出库。
  // 注意：不可直接访问 input.config.code（空配置时 getter 内部抛错），
  // 必须先按 buildAssetTypes 判断
  if (!input.config.buildAssetTypes.contains('code_assets/code')) return;
  final os = input.config.code.targetOS;
  // iOS 需交叉编译（宿主 clang 无法直接产出 iOS 目标）；
  // Android 用 NDK clang 交叉编译，每个 ABI 独立 OBJDIR 避免 .o 冲突
  final makeArgs = <String>['-j'];
  Map<String, String> env;
  switch (os) {
    case OS.iOS:
      env = await _iosBuildEnv(input);
      final ios = input.config.code.iOS;
      // make 命令行变量优先级高于 Makefile 的 CC=$(CROSS_PREFIX)clang 赋值
      makeArgs.addAll([
        'CC=xcrun --sdk ${ios.targetSdk.type} clang',
        'OBJDIR=.obj-ios-${ios.targetSdk.type}',
        _repoLibName,
      ]);
    case OS.macOS:
      // macOS 宿主编译：显式部署目标，避免 SDK 默认 minos 泄漏
      env = {
        'CFLAGS':
            '-mmacosx-version-min=${input.config.code.macOS.targetVersion}',
      };
      makeArgs.add(_repoLibName);
    case OS.android:
      env = await _androidBuildEnv(input);
      final arch = input.config.code.targetArchitecture;
      makeArgs.addAll(['OBJDIR=.obj-android-$arch', 'LIBS=-lm', _repoLibName]);
    default:
      env = const <String, String>{};
      makeArgs.add(_repoLibName);
  }
  final proc = await Process.start(
    'make',
    makeArgs,
    workingDirectory: srcDir.path,
    environment: env,
  );
  stdout.addStream(proc.stdout);
  stderr.addStream(proc.stderr);
  final code = await proc.exitCode;
  if (code != 0) {
    exit(code);
  }

  final linkMode =
      input.config.code.linkModePreference == LinkModePreference.dynamic
          ? DynamicLoadingBundled()
          : StaticLinking();
  final libName = os.libraryFileName('quickjs', linkMode);
  final libUri = input.outputDirectory.resolve(libName);
  File(p.join(srcDir.path, _repoLibName)).renameSync(libUri.toFilePath());

  output.assets.code.add(CodeAsset(
    package: packageName,
    name: 'src/lib_quickjs.dart',
    linkMode: linkMode,
    file: libUri,
  ));

  final src = [
    'src/quickjs.c',
    'src/libregexp.c',
    'src/libunicode.c',
    'src/cutils.c',
    'src/libc.c',
    'src/libbf.c',
  ];
  output.addDependencies([
    ...src.map((s) => pkgRoot.resolve(s)),
    pkgRoot.resolve('hook/build.dart'),
  ]);
}

/// iOS 交叉编译环境：按 hook 配置的目标 SDK（真机/模拟器）、最低系统版本与
/// 目标架构构造 clang 参数。修复历史缺陷：硬编码 iphonesimulator、缺部署
/// 目标 flag（minos 泄漏 SDK 默认值）、OBJDIR 跨 SDK 串档。
Future<Map<String, String>> _iosBuildEnv(BuildInput input) async {
  final ios = input.config.code.iOS;
  final sdkType = ios.targetSdk.type; // 'iphoneos' | 'iphonesimulator'
  final sdk = (await Process.run(
    'xcrun',
    ['--sdk', sdkType, '--show-sdk-path'],
  )).stdout.toString().trim();
  // Architecture.x64.name 为 'x64'，iOS clang 需要 'x86_64'
  final arch = switch (input.config.code.targetArchitecture) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'x86_64',
    final other => other.name,
  };
  final minFlag = sdkType == 'iphoneos'
      ? 'miphoneos-version-min'
      : 'miphonesimulator-version-min';
  return {
    'CFLAGS':
        '-isysroot $sdk -arch $arch -fPIC -$minFlag=${ios.targetVersion}',
  };
}

/// Android 交叉编译环境：NDK clang（wrapper 自带 target/sysroot），
/// 通过 CROSS_PREFIX 让 Makefile 自动选 clang/ar
Future<Map<String, String>> _androidBuildEnv(BuildInput input) async {
  final ndk = await _locateNdk();
  final triple = _androidTriple(input.config.code.targetArchitecture);
  final api = _androidApiLevel(ndk, triple, input.config.code.android.targetNdkApi);
  final binDir = _ndkBinDir(ndk);
  return {
    'CROSS_PREFIX': p.join(binDir, '$triple$api-'),
  };
}

/// 定位 NDK 根目录：ANDROID_NDK_HOME/ANDROID_NDK_ROOT 优先，
/// 其次 SDK 的 ndk/ 目录（取版本最大），最后 macOS 默认安装位置
Future<String> _locateNdk() async {
  final candidates = <String>[];
  final env = Platform.environment;
  final direct = env['ANDROID_NDK_HOME'] ?? env['ANDROID_NDK_ROOT'];
  if (direct != null && direct.isNotEmpty) candidates.add(direct);
  final sdkCandidates = [
    env['ANDROID_SDK_ROOT'],
    env['ANDROID_HOME'],
    if (Platform.isMacOS && env['HOME'] != null)
      p.join(env['HOME']!, 'Library/Android/sdk'),
  ];
  for (final sdk in sdkCandidates) {
    if (sdk == null || sdk.isEmpty) continue;
    final ndkDir = Directory(p.join(sdk, 'ndk'));
    if (!ndkDir.existsSync()) continue;
    final versions = ndkDir
        .listSync()
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .toList()
      ..sort();
    if (versions.isNotEmpty) candidates.add(p.join(ndkDir.path, versions.last));
  }
  for (final candidate in candidates) {
    if (Directory(p.join(candidate, 'toolchains/llvm/prebuilt')).existsSync()) {
      return candidate;
    }
  }
  throw StateError(
    '找不到 Android NDK。请设置 ANDROID_NDK_HOME 或 ANDROID_HOME/ndk，'
    '或安装到默认位置（macOS: ~/Library/Android/sdk/ndk）。尝试过: $candidates',
  );
}

String _ndkBinDir(String ndkRoot) {
  final prebuilt = Directory(p.join(ndkRoot, 'toolchains/llvm/prebuilt'));
  final dirs = prebuilt
      .listSync()
      .whereType<Directory>()
      .map((d) => d.path)
      .toList()
    ..sort();
  if (dirs.isEmpty) {
    throw StateError('NDK 缺少 toolchains/llvm/prebuilt 目录: $ndkRoot');
  }
  return p.join(dirs.last, 'bin');
}

String _androidTriple(Architecture arch) {
  switch (arch) {
    case Architecture.arm64:
      return 'aarch64-linux-android';
    case Architecture.arm:
      return 'armv7a-linux-androideabi';
    case Architecture.x64:
      return 'x86_64-linux-android';
    case Architecture.ia32:
      return 'i686-linux-android';
    case Architecture.riscv64:
      return 'riscv64-linux-android';
    default:
      throw StateError('不支持的 Android 架构: $arch');
  }
}

/// 选择存在的 clang wrapper API level：优先 >= 目标 API 的最小值，
/// 找不到则退回最大可用版本（NDK 28 提供 21-35）
int _androidApiLevel(String ndkRoot, String triple, int targetNdkApi) {
  final binDir = _ndkBinDir(ndkRoot);
  final re = RegExp('^$triple([0-9]+)-clang\$');
  final available = <int>[];
  for (final entry in Directory(binDir).listSync()) {
    final m = re.firstMatch(p.basename(entry.path));
    if (m != null) available.add(int.parse(m.group(1)!));
  }
  if (available.isEmpty) {
    throw StateError('NDK 缺少 $triple 的 clang wrapper: $binDir');
  }
  available.sort();
  for (final api in available) {
    if (api >= targetNdkApi) return api;
  }
  return available.last;
}
