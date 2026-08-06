import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/purification/purify_pattern_guard.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/purification_rule.dart';
import '../../domain/usecases/manage_purification_rules.dart';
import '../providers/purify_pipeline_provider.dart';

class PurificationRulesPage extends ConsumerStatefulWidget {
  const PurificationRulesPage({super.key});

  @override
  ConsumerState<PurificationRulesPage> createState() => _PurificationRulesPageState();
}

class _PurificationRulesPageState extends ConsumerState<PurificationRulesPage> {
  final _manager = ManagePurificationRules();
  late Future<List<PurificationRule>> _rulesFuture;

  @override
  void initState() {
    super.initState();
    // 先确保内置规则导入（首次进入净化规则页时规则库可能为空）
    _manager.ensureDefaults().then((_) {
      if (mounted) _reload();
    });
    _rulesFuture = _manager.getAll();
  }

  void _reload() {
    setState(() {
      _rulesFuture = _manager.getAll();
    });
  }

  /// 规则变更后刷新页面并让阅读管线重新加载规则
  void _refreshPipeline() {
    ref.invalidate(purifyPipelineProvider);
    _reload();
  }

  Future<void> _addRule() async {
    await _showRuleDialog();
  }

  Future<void> _editRule(PurificationRule rule) async {
    await _showRuleDialog(rule: rule);
  }

  Future<void> _showRuleDialog({PurificationRule? rule}) async {
    final nameController = TextEditingController(text: rule?.name ?? '');
    final patternController = TextEditingController(text: rule?.pattern ?? '');
    final replacementController = TextEditingController(text: rule?.replacement ?? '');

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(rule == null ? '添加规则' : '编辑规则'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '规则名称')),
            const SizedBox(height: 12),
            TextField(controller: patternController, decoration: const InputDecoration(labelText: '正则表达式'), maxLines: 2),
            const SizedBox(height: 12),
            TextField(controller: replacementController, decoration: const InputDecoration(labelText: '替换为'), maxLines: 2),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              // 保存前校验正则合法性
              if (patternController.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入正则表达式')),
                );
                return;
              }
              try {
                RegExp(patternController.text);
              } catch (_) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('正则表达式无效，请检查')),
                );
                return;
              }
              // ReDoS 预检：拒绝嵌套量词等可能灾难性回溯的模式
              if (PurifyPatternGuard.hasCatastrophicBacktracking(patternController.text)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('正则存在灾难性回溯风险（如嵌套量词），请简化表达式')),
                );
                return;
              }
              Navigator.pop(context, true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result == true) {
      final newRule = PurificationRule(
        id: rule?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        name: nameController.text.isEmpty ? '未命名规则' : nameController.text,
        pattern: patternController.text,
        replacement: replacementController.text,
        enabled: rule?.enabled ?? true,
      );
      if (rule == null) {
        await _manager.add(newRule);
      } else {
        await _manager.update(newRule);
      }
      _refreshPipeline();
    }
  }

  Future<void> _deleteRule(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除规则'),
        content: const Text('确定删除该净化规则吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _manager.delete(id);
    _refreshPipeline();
  }

  Future<void> _toggleRule(PurificationRule rule) async {
    await _manager.update(rule.copyWith(enabled: !rule.enabled));
    _refreshPipeline();
  }

  /// 导入净化规则：弹窗选择「从网络链接导入」或「从剪贴板导入」
  Future<void> _importRules() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('从网络链接导入'),
              onTap: () => Navigator.pop(context, 'url'),
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('从剪贴板导入'),
              onTap: () => Navigator.pop(context, 'clipboard'),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    if (source == 'url') {
      await _importFromUrlDialog();
    } else {
      await _importFromClipboard();
    }
  }

  Future<void> _importFromUrlDialog() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从网络链接导入'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '净化规则 JSON 链接',
            hintText: 'https://example.com/jinghua.json',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('导入')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final url = controller.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入链接')),
      );
      return;
    }

    try {
      final count = await _manager.importFromUrl(url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 $count 条净化规则')),
      );
      _refreshPipeline();
    } on DioException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：${_friendlyError(e)}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：${e.toString().replaceFirst('FormatException: ', '')}')),
      );
    }
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data == null || data.text == null || data.text!.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('剪贴板为空')),
      );
      return;
    }
    try {
      final count = await _manager.importFromJson(data.text!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 $count 条净化规则')),
      );
      _refreshPipeline();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：${e.toString().replaceFirst('FormatException: ', '')}')),
      );
    }
  }

  /// Dio 异常转友好文案（不含服务器细节）
  static String _friendlyError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '连接超时';
      case DioExceptionType.connectionError:
        return '无法连接服务器';
      case DioExceptionType.badResponse:
        return '服务器响应异常（${e.response?.statusCode}）';
      case DioExceptionType.cancel:
        return '已取消';
      default:
        return '请求失败';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('净化规则'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _importRules,
            tooltip: '导入规则',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addRule,
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<PurificationRule>>(
        future: _rulesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final rules = snapshot.data ?? [];
          if (rules.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.cleaning_services, size: 64, color: AppColors.textSecondary),
                  SizedBox(height: 16),
                  Text('暂无净化规则', style: TextStyle(fontSize: 16)),
                  SizedBox(height: 8),
                  Text('点击右下角添加规则', style: TextStyle(color: AppColors.textSecondary)),
                ],
              ),
            );
          }
          return ListView.builder(
            itemCount: rules.length,
            itemBuilder: (context, index) {
              final rule = rules[index];
              return Card(
                child: ListTile(
                  leading: Switch(
                    value: rule.enabled,
                    onChanged: (_) => _toggleRule(rule),
                  ),
                  title: Text(rule.name),
                  subtitle: Text(rule.pattern, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _editRule(rule),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteRule(rule.id),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
