import 'package:file_picker/file_picker.dart';
import 'package:either_dart/either.dart';
import '../entities/book_source.dart';
import '../repositories/book_source_repository.dart';
import 'parse_book_source_rule.dart';

/// 导入书源（支持 JSON 文件/网络链接/剪贴板）
class ImportBookSource {
  final BookSourceRepository repository;
  final ParseBookSourceRule parser;

  ImportBookSource({
    required this.repository,
    required this.parser,
  });

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

  /// 从网络链接导入
  Future<Either<String, List<BookSource>>> fromUrl(String url) async {
    return const Left('网络导入功能尚未实现');
  }

  /// 从剪贴板导入
  Future<Either<String, BookSource?>> fromClipboard(String content) async {
    final parsed = parser.execute(content);
    if (parsed.isLeft) {
      return Left(parsed.left);
    }
    BookSource? source;
    parsed.fold((l) => null, (r) => source = r);
    if (source != null) {
      await repository.save(source!);
    }
    return Right(source);
  }
}
