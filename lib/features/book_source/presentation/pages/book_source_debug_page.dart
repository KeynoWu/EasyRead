import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../reader/data/repositories/reader_repository_impl.dart';
import '../../../search/data/repositories/search_repository_impl.dart';
import '../../domain/entities/book_source.dart';
import '../../domain/entities/book_source_debug_result.dart';
import '../../domain/repositories/book_source_repository.dart';

/// 书源调试页：查看原始响应与规则解析示例。
class BookSourceDebugPage extends StatefulWidget {
  final BookSource source;

  const BookSourceDebugPage({super.key, required this.source});

  @override
  State<BookSourceDebugPage> createState() => _BookSourceDebugPageState();
}

class _BookSourceDebugPageState extends State<BookSourceDebugPage> {
  final _keywordController = TextEditingController(text: '测试');
  final _detailController = TextEditingController();
  BookSourceDebugResult? _result;
  bool _loading = false;
  bool _debugRunning = false;
  String? _tocResult;
  String? _contentResult;

  @override
  void dispose() {
    _keywordController.dispose();
    _detailController.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final keyword = _keywordController.text.trim();
    if (keyword.isEmpty) return;
    setState(() {
      _loading = true;
      _result = null;
    });
    final result = await SearchRepositoryImpl().debugSearch(
      keyword,
      widget.source,
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _loading = false;
    });
  }

  ReaderRepositoryImpl _readerRepo() {
    return ReaderRepositoryImpl(sourceRepo: _SingleSourceRepo(widget.source));
  }

  Future<void> _debugToc() async {
    final url = _detailController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _debugRunning = true;
      _tocResult = null;
      _contentResult = null;
    });
    try {
      final catalog = await _readerRepo().getCatalog(
        bookId: 'debug',
        sourceId: widget.source.id,
        detailUrl: url,
      );
      final first = catalog.chapters.take(5).map((c) => c.title).join('\n');
      if (!mounted) return;
      setState(() {
        _tocResult = '解析到 ${catalog.chapters.length} 章\n$first';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _tocResult = '目录调试失败：$e');
    } finally {
      if (mounted) setState(() => _debugRunning = false);
    }
  }

  Future<void> _debugContent() async {
    final url = _detailController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _debugRunning = true;
      _tocResult = null;
      _contentResult = null;
    });
    try {
      final chapter = await _readerRepo().getChapter(
        bookId: 'debug',
        chapterIndex: 0,
        sourceId: widget.source.id,
        detailUrl: url,
      );
      if (!mounted) return;
      setState(() {
        _contentResult =
            '标题：${chapter.title}\n内容长度：${chapter.content.length}\n${chapter.content.substring(0, chapter.content.length.clamp(0, 500).toInt())}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _contentResult = '正文调试失败：$e');
    } finally {
      if (mounted) setState(() => _debugRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('书源调试')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _keywordController,
                  decoration: const InputDecoration(
                    labelText: '调试关键词',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _loading ? null : _run,
                child: const Text('调试'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _detailController,
            decoration: const InputDecoration(
              labelText: '详情页 URL',
              hintText: '用于调试目录和正文',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _debugRunning ? null : _debugToc,
                  child: const Text('调试目录'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _debugRunning ? null : _debugContent,
                  child: const Text('调试正文'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_debugRunning)
            const Center(child: CircularProgressIndicator())
          else if (_tocResult != null) ...[
            const Text('目录结果', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SelectableText(_tocResult!),
          ],
          if (_contentResult != null) ...[
            const SizedBox(height: 16),
            const Text('正文结果', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SelectableText(_contentResult!),
          ],
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (result != null) ...[
            _ResultHeader(result: result),
            if (result.results.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('解析示例', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              for (final item in result.results)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(item.name),
                  subtitle: Text('${item.author ?? '未知作者'} · ${item.detailUrl ?? ''}'),
                ),
            ],
            if (result.rawHtml != null) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('原始响应', style: TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: '复制响应',
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: result.rawHtml!),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('响应已复制')),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.separator.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  result.rawHtml!,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _SingleSourceRepo implements BookSourceRepository {
  final BookSource source;

  _SingleSourceRepo(this.source);

  @override
  Future<List<BookSource>> getAll() async => [source];

  @override
  Future<BookSource?> getById(String id) async =>
      id == source.id ? source : null;

  @override
  Future<void> save(BookSource source) async {}

  @override
  Future<void> delete(String id) async {}

  @override
  Future<void> importFromJson(String jsonString) async {}

  @override
  Future<void> importFromUrl(String url) async {}

  @override
  Future<List<BookSource>> getEnabled() async =>
      source.enabled ? [source] : [];
}

class _ResultHeader extends StatelessWidget {
  final BookSourceDebugResult result;

  const _ResultHeader({required this.result});

  @override
  Widget build(BuildContext context) {
    final ok = result.success;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (ok ? Colors.green : Colors.redAccent).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        ok
            ? '调试成功，解析到 ${result.results.length} 条示例'
            : '调试失败：${result.error}',
        style: TextStyle(
          color: ok ? Colors.green.shade700 : Colors.redAccent.shade700,
        ),
      ),
    );
  }
}
