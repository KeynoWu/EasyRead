import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/book_source.dart';
import '../../domain/usecases/run_single_rule.dart';
import '../providers/book_source_provider.dart';

/// “不使用书源”占位（DropdownButton 不允许 null 项值）
const _noSource = Object();

/// “选择规则字段”占位
const _noField = 'noField';

/// 规则测试器：书源规则实时调试工具页（单条规则，比整源调试更聚焦）。
///
/// - 书源选择（可选）：选中后自动使用其 baseUrl，并可一键载入规则字段
/// - 样本输入：大 TextField，HTML 或 JSON 自动识别（首字符 { / [ 判 JSON）
/// - 规则类型 SegmentedButton：CSS/XPath、JSONPath、JS 规则、URL 模板
/// - 结果区：匹配数量 + 每项结果列表 + 耗时 / 错误信息，可滚动
class RuleTesterPage extends ConsumerStatefulWidget {
  /// 从书源菜单进入时携带该书源（提供 baseUrl/charset/规则字段）；可为空
  final BookSource? source;

  const RuleTesterPage({super.key, this.source});

  @override
  ConsumerState<RuleTesterPage> createState() => _RuleTesterPageState();
}

class _RuleTesterPageState extends ConsumerState<RuleTesterPage> {
  final _sampleController = TextEditingController();
  final _ruleController = TextEditingController();
  final _baseUrlController = TextEditingController();

  BookSource? _source;
  RuleTesterType _type = RuleTesterType.css;
  SingleRuleRunResult? _result;
  bool _running = false;
  String? _selectedField;

  /// 书源规则字段下拉：标签 → 取规则文本
  static final List<(String, String Function(BookSource))> _ruleFields = [
    ('搜索 URL（模板）', (s) => s.searchUrl ?? ''),
    ('搜索列表 bookList', (s) => s.bookListRule ?? ''),
    ('书名 bookName', (s) => s.bookNameRule ?? ''),
    ('作者 bookAuthor', (s) => s.bookAuthorRule ?? ''),
    ('封面 coverUrl', (s) => s.coverUrlRule ?? ''),
    ('详情 URL bookDetailUrl', (s) => s.bookDetailUrlRule ?? ''),
    ('简介 intro', (s) => s.introRule ?? ''),
    ('分类 kind', (s) => s.kindRule ?? ''),
    ('最新章节 lastChapter', (s) => s.lastChapterRule ?? ''),
    ('字数 wordCount', (s) => s.wordCountRule ?? ''),
    ('目录列表 chapterList', (s) => s.chapterListRule ?? ''),
    ('章节名 chapterName', (s) => s.chapterNameRule ?? ''),
    ('章节 URL chapterUrl', (s) => s.chapterUrlRule ?? ''),
    ('正文 chapterContent', (s) => s.chapterContentRule ?? ''),
    ('正文 URL contentUrl', (s) => s.contentUrl ?? ''),
  ];

  @override
  void initState() {
    super.initState();
    _source = widget.source;
    if (widget.source != null) {
      _baseUrlController.text = widget.source!.bookSourceUrl ?? '';
    }
  }

  @override
  void dispose() {
    _sampleController.dispose();
    _ruleController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  /// 样本是否 JSON（首字符 { 或 [）
  bool get _sampleIsJson {
    final t = _sampleController.text.trim();
    return t.startsWith('{') || t.startsWith('[');
  }

  /// 根据规则文本猜测规则类型（载入书源规则字段时自动切换）
  RuleTesterType _guessType(String rule) {
    final t = rule.trim();
    if (t.startsWith(r'$') || t.toLowerCase().startsWith('@json:')) {
      return RuleTesterType.jsonPath;
    }
    if (t.startsWith('<js') || t.startsWith('@js:')) {
      return RuleTesterType.js;
    }
    if (t.contains('{{')) return RuleTesterType.template;
    return RuleTesterType.css;
  }

  void _loadRuleField(String label, String Function(BookSource) getter) {
    final source = _source;
    if (source == null) return;
    final text = getter(source).trim();
    setState(() {
      _selectedField = text.isEmpty ? null : label;
      _ruleController.text = text;
      if (text.isNotEmpty) _type = _guessType(text);
    });
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _result = null;
    });
    final result = await const RunSingleRule().run(
      sample: _sampleController.text,
      rule: _ruleController.text,
      type: _type,
      source: _source,
      baseUrl: _baseUrlController.text.trim().isEmpty
          ? null
          : _baseUrlController.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sourcesAsync = ref.watch(bookSourceListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('规则测试')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  sourcesAsync.when(
                    data: (sources) => _buildSourceSelector(sources),
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('书源加载失败：$e'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _baseUrlController,
                    decoration: const InputDecoration(
                      labelText: 'baseUrl（可选）',
                      hintText: '模板相对路径展开 / JS 规则上下文使用',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _sampleController,
                    maxLines: 8,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: '样本（HTML 或 JSON，自动识别）',
                      hintText: '粘贴网页 HTML 或 JSON 数据',
                      alignLabelWithHint: true,
                      border: const OutlineInputBorder(),
                      suffixText: _sampleIsJson ? '已识别：JSON' : '已识别：HTML',
                      suffixStyle: TextStyle(
                        fontSize: 12,
                        color: _sampleIsJson
                            ? AppColors.tint
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<RuleTesterType>(
                    segments: [
                      for (final type in RuleTesterType.values)
                        ButtonSegment(
                          value: type,
                          label: Text(type == RuleTesterType.css
                              ? 'CSS'
                              : type == RuleTesterType.jsonPath
                                  ? 'JSONPath'
                                  : type == RuleTesterType.js
                                      ? 'JS'
                                      : '模板'),
                        ),
                    ],
                    selected: {_type},
                    onSelectionChanged: (selection) =>
                        setState(() => _type = selection.first),
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_source != null) ...[
                    _buildRuleFieldSelector(),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _ruleController,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: '规则（${_type.label}）',
                      alignLabelWithHint: true,
                      border: const OutlineInputBorder(),
                      hintText: _type == RuleTesterType.css
                          ? '如 div.book@href 或 //h3 或 :正则&&正则'
                          : _type == RuleTesterType.jsonPath
                              ? r'如 $.books[?(@.price>10)].name'
                              : _type == RuleTesterType.js
                                  ? '如 <js>result.match(/书名/)[0]</js>'
                                  : r'如 https://x.com/search?q={{$.q}}',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _running ? null : _run,
                    icon: _running
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    label: Text(_running ? '运行中…' : '运行'),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildResultPane(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceSelector(List<BookSource> sources) {
    // 传入的书源实例可能已不在仓库列表（防御：不在列表则视为未选择）
    final selected = sources.contains(_source) ? _source : null;
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: '书源（可选）',
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<Object>(
          value: selected ?? _noSource,
          isExpanded: true,
          items: [
            const DropdownMenuItem<Object>(
              value: _noSource,
              child: Text('不使用书源（手动填写 baseUrl）'),
            ),
            for (final s in sources)
              DropdownMenuItem<Object>(
                value: s,
                child: Text(s.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (value) {
            setState(() {
              _source = identical(value, _noSource) ? null : value as BookSource;
              _baseUrlController.text = _source?.bookSourceUrl ?? '';
              _selectedField = null;
            });
          },
        ),
      ),
    );
  }

  Widget _buildRuleFieldSelector() {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: '载入书源规则字段（自动切换规则类型）',
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedField ?? _noField,
          isExpanded: true,
          items: [
            const DropdownMenuItem<String>(
              value: _noField,
              child: Text('选择规则字段载入'),
            ),
            for (final (label, _) in _ruleFields)
              DropdownMenuItem<String>(value: label, child: Text(label)),
          ],
          onChanged: (value) {
            if (value == null || value == _noField) return;
            final entry = _ruleFields.firstWhere((e) => e.$1 == value);
            _loadRuleField(entry.$1, entry.$2);
          },
        ),
      ),
    );
  }

  Widget _buildResultPane(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final result = _result;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.separator),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            result == null
                ? '结果'
                : '结果 · ${result.count} 项 · ${result.elapsed.inMilliseconds} ms',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildResultBody(result)),
        ],
      ),
    );
  }

  Widget _buildResultBody(SingleRuleRunResult? result) {
    if (_running) {
      return const Center(child: CircularProgressIndicator());
    }
    if (result == null) {
      return Center(
        child: Text(
          '输入样本与规则后点击运行',
          style: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.8)),
        ),
      );
    }
    final error = result.error;
    if (error != null) {
      return ListView(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  error.kind.label,
                  style: const TextStyle(
                    color: AppColors.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(error.message),
              ],
            ),
          ),
          if (result.note != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              result.note!,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ],
      );
    }
    if (result.values.isEmpty) {
      return Center(
        child: Text(
          result.note == null ? '无匹配结果' : '${result.note}\n（无匹配结果）',
          style: const TextStyle(color: AppColors.textSecondary),
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      itemCount: result.values.length,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 22,
              margin: const EdgeInsets.only(top: 2),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.tintSoft,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${index + 1}',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.tint,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: SelectableText(result.values[index])),
          ],
        ),
      ),
    );
  }
}
