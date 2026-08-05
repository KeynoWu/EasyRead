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
  // 用独立 OBJDIR 隔离，避免宿主 .obj 混入导致架构不匹配
  final env = os == OS.iOS ? await _iosBuildEnv() : const <String, String>{};
  final makeArgs = [
    '-j',
    if (os == OS.iOS) 'OBJDIR=.obj-ios',
    _repoLibName,
  ];
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

/// iOS 交叉编译环境：使用 iphonesimulator SDK 的 clang
Future<Map<String, String>> _iosBuildEnv() async {
  final sdk = (await Process.run(
    'xcrun',
    ['--sdk', 'iphonesimulator', '--show-sdk-path'],
  )).stdout.toString().trim();
  return {
    'CC': 'xcrun --sdk iphonesimulator clang',
    'CFLAGS': '-isysroot $sdk -arch arm64 -fPIC',
  };
}
