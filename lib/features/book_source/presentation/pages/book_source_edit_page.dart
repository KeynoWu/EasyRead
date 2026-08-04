import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/book_source.dart';
import '../../domain/repositories/book_source_repository.dart';
import '../../domain/usecases/test_book_source.dart';

/// 可视化书源编辑器
class BookSourceEditPage extends StatefulWidget {
  final BookSource? source;
  final BookSourceRepository repository;

  const BookSourceEditPage({
    super.key,
    this.source,
    required this.repository,
  });

  @override
  State<BookSourceEditPage> createState() => _BookSourceEditPageState();
}

class _BookSourceEditPageState extends State<BookSourceEditPage> {
  late final Map<String, TextEditingController> _controllers;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final s = widget.source;
    _enabled = s?.enabled ?? true;
    _searchable = s?.rules['searchable'] == null || s!.rules['searchable'] == true;
    _controllers = {
      'name': TextEditingController(text: s?.name ?? ''),
      'group': TextEditingController(text: s?.bookSourceGroup ?? ''),
      'url': TextEditingController(text: s?.bookSourceUrl ?? ''),
      'searchUrl': TextEditingController(text: s?.rules['searchUrl']?.toString() ?? ''),
      'bookList': TextEditingController(text: s?.rules['bookList']?.toString() ?? ''),
      'bookName': TextEditingController(text: s?.rules['bookName']?.toString() ?? ''),
      'bookAuthor': TextEditingController(text: s?.rules['bookAuthor']?.toString() ?? ''),
      'coverUrl': TextEditingController(text: s?.rules['coverUrl']?.toString() ?? ''),
      'bookDetailUrl': TextEditingController(text: s?.rules['bookDetailUrl']?.toString() ?? ''),
      'contentUrl': TextEditingController(text: s?.rules['contentUrl']?.toString() ?? ''),
      'chapterList': TextEditingController(text: s?.rules['chapterList']?.toString() ?? ''),
      'chapterName': TextEditingController(text: s?.rules['chapterName']?.toString() ?? ''),
      'chapterUrl': TextEditingController(text: s?.rules['chapterUrl']?.toString() ?? ''),
      'chapterContent': TextEditingController(text: s?.rules['chapterContent']?.toString() ?? ''),
      'weight': TextEditingController(text: s?.rules['weight']?.toString() ?? ''),
      'header': TextEditingController(text: s?.rules['header']?.toString() ?? ''),
      'cookie': TextEditingController(text: s?.rules['cookie']?.toString() ?? ''),
      'loginUrl': TextEditingController(text: s?.rules['loginUrl']?.toString() ?? ''),
    };
  }

  late bool _searchable;

  /// 表单规则：保留原书源中未展示的规则字段，表单字段覆盖
  Map<String, dynamic> _buildRules() {
    final base = Map<String, dynamic>.from(widget.source?.rules ?? {});
    const editableKeys = [
      'searchUrl', 'bookList', 'bookName', 'bookAuthor', 'coverUrl', 'bookDetailUrl',
      'contentUrl', 'chapterList', 'chapterName', 'chapterUrl', 'chapterContent',
      'weight', 'header', 'cookie', 'loginUrl',
    ];
    for (final k in editableKeys) {
      final text = _controllers[k]!.text.trim();
      if (text.isEmpty) {
        base.remove(k);
      } else if (k == 'weight') {
        // weight 以数字存储，非数字输入直接丢弃
        final weight = int.tryParse(text);
        if (weight != null) base[k] = weight;
      } else {
        base[k] = text;
      }
    }
    base['searchable'] = _searchable;
    return base;
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _test() async {
    final name = _controllers['name']!.text.trim();
    final keywordController = TextEditingController(text: '测试');

    final keyword = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('测试书源'),
        content: TextField(
          controller: keywordController,
          decoration: const InputDecoration(hintText: '输入测试关键词'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, keywordController.text.trim()), child: const Text('测试')),
        ],
      ),
    );
    if (keyword == null || keyword.isEmpty || !mounted) return;

    // 构建测试书源（含完整规则）
    final rules = _buildRules();
    final source = TestBookSource().buildTestSource(
      name: name.isEmpty ? '测试' : name,
      url: _controllers['url']!.text.trim().isEmpty ? null : _controllers['url']!.text.trim(),
      group: _controllers['group']!.text.trim().isEmpty ? null : _controllers['group']!.text.trim(),
      rules: rules,
    );

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('测试中...'),
          ],
        ),
      ),
    );

    final result = await TestBookSource().testSearch(source, keyword);
    if (!mounted) return;
    Navigator.pop(context); // 关闭加载对话框
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(result.success ? '✓ 测试成功' : '✗ 测试失败'),
        content: Text(result.message),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('确定')),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final name = _controllers['name']!.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入书源名称')),
      );
      return;
    }

    final rules = _buildRules();

    final source = BookSource(
      id: widget.source?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      bookSourceUrl: _controllers['url']!.text.trim().isEmpty ? null : _controllers['url']!.text.trim(),
      bookSourceGroup: _controllers['group']!.text.trim().isEmpty ? null : _controllers['group']!.text.trim(),
      enabled: _enabled,
      rules: rules,
    );

    await widget.repository.save(source);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.source == null ? '新建书源' : '编辑书源'),
        actions: [
          IconButton(
            icon: const Icon(Icons.science_outlined),
            onPressed: _test,
            tooltip: '测试书源',
          ),
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('基本信息'),
          _buildField('名称', 'name', hint: '书源名称'),
          _buildField('分组', 'group', hint: '如：通用、小说'),
          _buildField('书源地址', 'url', hint: 'https://example.com'),
          SwitchListTile(
            title: const Text('启用'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          SwitchListTile(
            title: const Text('参与聚合搜索'),
            subtitle: const Text('关闭后仅手动搜索该源'),
            value: _searchable,
            onChanged: (v) => setState(() => _searchable = v),
          ),
          const Divider(),
          _sectionTitle('搜索规则'),
          _buildField('搜索 URL', 'searchUrl', hint: 'https://example.com/search?keyword={{key}}'),
          _buildField('书籍列表', 'bookList', hint: 'CSS 选择器'),
          _buildField('书名规则', 'bookName', hint: 'h3.title@text'),
          _buildField('作者规则', 'bookAuthor', hint: 'span.author@text'),
          _buildField('封面规则', 'coverUrl', hint: 'img.cover@src'),
          _buildField('详情链接规则', 'bookDetailUrl', hint: 'a.detail@href'),
          const Divider(),
          _sectionTitle('目录规则'),
          _buildField('内容 URL', 'contentUrl', hint: 'https://example.com/chapter/{{id}}.html'),
          _buildField('章节列表', 'chapterList', hint: 'ul.chapter-list > li'),
          _buildField('章节名规则', 'chapterName', hint: 'a@text'),
          _buildField('章节链接规则', 'chapterUrl', hint: 'a@href'),
          const Divider(),
          _sectionTitle('内容规则'),
          _buildField('章节内容', 'chapterContent', hint: 'div#content@html', maxLines: 3),
          const Divider(),
          _sectionTitle('高级设置'),
          _buildField('搜索权重', 'weight', hint: '数值越大优先级越高（默认 0）', keyboardType: TextInputType.number),
          _buildField('请求头', 'header', hint: 'JSON 格式，如 {"Referer": "https://example.com"}', maxLines: 3),
          _buildField('Cookie', 'cookie', hint: '登录后 Cookie'),
          _buildField('登录 URL', 'loginUrl', hint: '需要登录时填写的登录地址'),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        title,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _buildField(String label, String key, {String? hint, int maxLines = 1, TextInputType? keyboardType}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: _controllers[key],
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        maxLines: maxLines,
      ),
    );
  }
}
