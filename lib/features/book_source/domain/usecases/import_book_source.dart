import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:either_dart/either.dart';
import '../../../../core/network/dio_client.dart';
import '../entities/book_source.dart';
import '../repositories/book_source_repository.dart';
import 'parse_book_source_rule.dart';

/// 导入书源（支持 JSON 文件/网络链接/剪贴板）
class ImportBookSource {
  final BookSourceRepository repository;
  final ParseBookSourceRule parser;
  final DioClient _client;

  ImportBookSource({
    required this.repository,
    required this.parser,
    DioClient? client,
  }) : _client = client ?? DioClient();

  /// 从文件导入
  Future<Either<String, List<BookSource>>> fromFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      allowMultiple: true,
    );
    if (result == null) return const Left('未选择文件');

    final sources = <BookSource>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) continue;
      final content = String.fromCharCodes(bytes);
      final parsed = parser.execute(content);
      if (parsed.isRight) {
        parsed.fold((l) => null, (r) => sources.add(r));
      }
    }
    if (sources.isEmpty) return const Left('未解析到有效书源');

    for (final source in sources) {
      await repository.save(source);
    }
    return Right(sources);
  }

  /// 从网络链接导入（支持单个书源 JSON 或书源列表 JSON 数组）
  Future<Either<String, List<BookSource>>> fromUrl(String url) async {
    try {
      final content = await _client.getString(url);
      return _parseContent(content);
    } catch (e) {
      return Left('网络请求失败: $e');
    }
  }

  /// 从剪贴板导入
  Future<Either<String, List<BookSource>>> fromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data == null || data.text == null || data.text!.isEmpty) {
      return const Left('剪贴板为空');
    }
    return _parseContent(data.text!);
  }

  /// 解析内容（支持单个书源对象或书源数组）
  Either<String, List<BookSource>> _parseContent(String content) {
    final text = content.trim();
    if (text.isEmpty) return const Left('内容为空');

    // 尝试解析为数组
    if (text.startsWith('[')) {
      try {
        final list = (jsonDecode(text) as List);
        final sources = <BookSource>[];
        for (final item in list) {
          final parsed = parser.execute(jsonEncode(item));
          parsed.fold((l) => null, (r) => sources.add(r));
        }
        if (sources.isEmpty) return const Left('未解析到有效书源');
        return Right(sources);
      } catch (e) {
        return Left('书源格式错误: $e');
      }
    }

    // 单个书源对象
    final parsed = parser.execute(text);
    return parsed.fold(
      (l) => Left(l),
      (r) => Right([r]),
    );
  }
}
