// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// 本地 fork：适配 native_assets_cli 0.18 API（Flutter 3.44 hooks 协议）
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
  final proc = await Process.start(
    'make',
    [
      '-j',
      _repoLibName,
    ],
    workingDirectory: srcDir.path,
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
  final os = input.config.code.targetOS;
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
