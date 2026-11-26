import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quick_write/core/models/name_gen/name_dictionary.dart';
import 'package:quick_write/core/models/name_gen/name_gen_options.dart';
import 'package:quick_write/core/services/cache_services/name_gen_cache_service.dart';
import 'package:quick_write/core/services/cloud_sync/cloud_sync_service.dart';
import 'package:quick_write/core/services/name_gen/name_generator.dart';
import 'package:quick_write/shared/widgets/qw_dialogs.dart';
import 'package:quick_write/shared/widgets/qw_snackbar.dart';
import 'package:quick_write/pages/workspace/name_gen/widgets/name_dictionary_editor_dialog.dart';
import 'package:quick_write/pages/workspace/name_gen/widgets/name_dictionary_panel.dart';
import 'package:quick_write/pages/workspace/name_gen/widgets/name_options_panel.dart';
import 'package:quick_write/pages/workspace/name_gen/widgets/name_result_panel.dart';

/// 显示随机取名对话框
///
/// 点击任意名字即复制到剪贴板并关闭对话框，被点击的名字作为返回值返回；
/// 对话框被取消时返回 null，由调用方决定是否插入编辑器。
Future<String?> showNameGeneratorDialog({
  required BuildContext context,
}) {
  return showDialogBase<String>(
    context: context,
    title: '随机取名',
    subtitle: '从词典词条中随机抽取名字，点击即复制并关闭',
    titleIcon: Icons.casino_outlined,
    width: 880,
    height: 600,
    content: const _NameGeneratorDialog(),
  );
}

/// 随机取名对话框主体
///
/// 左侧为类别切换与词典管理，右侧为参数配置与生成结果。
/// 每次生成的名字数量
///
/// 结果区一行一个名字，固定生成七条，不再提供自定义数量。
const int _batchCount = 7;

class _NameGeneratorDialog extends StatefulWidget {
  const _NameGeneratorDialog();

  @override
  State<_NameGeneratorDialog> createState() => _NameGeneratorDialogState();
}

class _NameGeneratorDialogState extends State<_NameGeneratorDialog> {
  /// 缓存服务
  final NameGenCacheService _cache = NameGenCacheService.instance;

  /// 云同步服务：词典文件由同步直接落盘，需要据此重新读盘
  final CloudSyncService _syncService = CloudSyncService.instance;

  /// 已处理过的同步版本号，避免同步进度通知反复触发读盘
  int _handledSyncRevision = 0;

  /// 随机数发生器
  final Random _random = Random();

  /// 自定义姓氏输入控制器
  final TextEditingController _surnameController = TextEditingController();

  /// 自定义后缀输入控制器
  final TextEditingController _suffixController = TextEditingController();

  /// 自定义姓氏输入框焦点节点
  final FocusNode _surnameFocusNode = FocusNode();

  /// 自定义后缀输入框焦点节点
  final FocusNode _suffixFocusNode = FocusNode();

  /// 当前类别
  // 章节式词典不再区分类别，统一用 other 承载全部自建词典
  NameCategory _category = NameCategory.other;

  /// 当前生成参数
  NameGenOptions _options = const NameGenOptions();

  /// 各类别的词典列表
  final Map<NameCategory, List<NameDictionary>> _dictionaries = {};

  /// 各类别选中的词典 ID
  final Map<NameCategory, String> _selectedIds = {};

  /// 本次生成结果
  List<String> _results = const [];

  @override
  void initState() {
    super.initState();
    _options = _cache.getOptions();
    _surnameController.text = _options.customSurname;
    _suffixController.text = _options.customSuffix;
    _reloadDictionaries();
    // 打开界面时立即生成一次结果
    _results = _generateNames();

    _handledSyncRevision = _syncService.syncRevision;
    _syncService.addListener(_onCloudSyncChanged);
    // 云同步可能已把新词典写进 dict 目录，先按内存渲染首帧，再从磁盘校正
    _refreshDictionariesFromDisk();
  }

  @override
  void dispose() {
    _syncService.removeListener(_onCloudSyncChanged);
    _surnameController.dispose();
    _suffixController.dispose();
    _surnameFocusNode.dispose();
    _suffixFocusNode.dispose();
    super.dispose();
  }

  // ================= 数据读取 =================

  /// 云同步结束后重新读盘
  ///
  /// 同步服务在同步进度、忙碌状态变化时会频繁通知，只有数据真正落地后
  /// 版本号才会递增，据此避免无谓的磁盘扫描
  void _onCloudSyncChanged() {
    final revision = _syncService.syncRevision;
    if (revision == _handledSyncRevision) return;
    _handledSyncRevision = revision;
    _refreshDictionariesFromDisk();
  }

  /// 从磁盘重载词典并刷新界面
  Future<void> _refreshDictionariesFromDisk() async {
    await _cache.reloadDictionaries();
    if (!mounted) return;
    setState(_reloadDictionaries);
  }

  /// 重新加载词典列表与选中项
  ///
  /// 章节式词典不区分类别：内置词典不再展示，全部自建词典合并成一个列表。
  void _reloadDictionaries() {
    final List<NameDictionary> all = <NameDictionary>[];
    for (final category in NameCategory.values) {
      all.addAll(_cache.getDictionaries(category).where((d) => !d.isBuiltin));
    }
    _dictionaries[NameCategory.other] = all;

    // 优先沿用 other 的选中项，其次沿用任何类别中仍存在的选中项
    String selected = _cache.getSelectedDictionaryId(NameCategory.other);
    if (all.every((d) => d.id != selected)) {
      selected = '';
      for (final category in NameCategory.values) {
        final String id = _cache.getSelectedDictionaryId(category);
        if (all.any((d) => d.id == id)) {
          selected = id;
          break;
        }
      }
    }
    _selectedIds[NameCategory.other] = selected;
  }

  /// 获取当前类别选中的词典
  NameDictionary? get _currentDictionary {
    final list = _dictionaries[_category] ?? const [];
    final id = _selectedIds[_category];
    final index = list.indexWhere((d) => d.id == id);
    return index >= 0 ? list[index] : null;
  }

  // ================= 生成与结果操作 =================

  /// 依据当前词典与参数生成一批名字
  ///
  /// 仅供生成使用，不写入历史；词典不存在或词条不足时返回空列表。
  List<String> _generateNames() {
    final dictionary = _currentDictionary;
    if (dictionary == null) return const [];

    // 章节式词典：每条词条即完整结果，直接随机抽取，不做任何组合
    if (dictionary.isEntryList) {
      return NameGenerator.pickEntries(
        dictionary,
        count: _batchCount,
        random: _random,
      );
    }
    return NameGenerator.generateBatch(
      dictionary,
      options: _options.copyWith(batchCount: _batchCount),
      count: _batchCount,
      random: _random,
    );
  }

  /// 点击生成按钮
  ///
  /// 批量生成名字并替换当前结果；无法生成时提示用户。
  void _generate() {
    if (_currentDictionary == null) {
      SnackBarService.show(context, '请先在左侧选择或新建一个词典');
      return;
    }
    final names = _generateNames();
    if (names.isEmpty) {
      SnackBarService.show(context, '词典词条不足，无法生成，请补充词条');
      return;
    }
    setState(() => _results = names);
  }

  /// 选中名字
  ///
  /// 复制名字到剪贴板并关闭对话框，把名字作为结果返回给调用方，
  /// 由调用方判断正文是否处于光标焦点并决定是否直接插入。
  Future<void> _selectName(String name) async {
    await Clipboard.setData(ClipboardData(text: name));
    if (!mounted) return;
    Navigator.of(context).pop(name);
  }

  /// 清空生成结果
  void _clearResults() => setState(() => _results = const []);

  // ================= 词典管理 =================

  /// 选中词典
  ///
  /// 切换后立即按新词典生成一次结果。
  void _selectDictionary(String id) {
    _cache.saveSelectedDictionaryId(_category, id);
    setState(() {
      _selectedIds[_category] = id;
      _results = _generateNames();
    });
  }

  /// 拖动排序词典
  ///
  /// 列表顺序变化后立即刷新界面，并把新顺序写回缓存与磁盘。
  Future<void> _reorderDictionaries(int oldIndex, int newIndex) async {
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    final list = List<NameDictionary>.of(_dictionaries[_category] ?? const []);
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (target < 0) target = 0;
    if (target >= list.length) target = list.length - 1;
    if (target == oldIndex) return;

    final moved = list.removeAt(oldIndex);
    list.insert(target, moved);
    setState(() => _dictionaries[_category] = list);
    await _cache.reorderDictionaries(list.map((d) => d.id).toList());
  }

  /// 新建词典
  Future<void> _createDictionary() async {
    final result = await showNameDictionaryEditorDialog(context: context);
    if (result == null) return;
    await _cache.saveDictionary(result);
    if (!mounted) return;
    setState(() {
      _reloadDictionaries();
      _selectedIds[NameCategory.other] = result.id;
      _category = NameCategory.other;
      _results = _generateNames();
    });
  }

  /// 编辑词典
  Future<void> _editDictionary(NameDictionary dictionary) async {
    final result = await showNameDictionaryEditorDialog(
      context: context,
      dictionary: dictionary,
    );
    if (result == null) return;
    await _cache.saveDictionary(result);
    if (!mounted) return;
    setState(() {
      _reloadDictionaries();
      // 词条可能已变化，按新内容重新生成一批结果
      _results = _generateNames();
    });
  }

  /// 删除词典
  Future<void> _deleteDictionary(NameDictionary dictionary) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: '删除词典',
      description: '确定要删除词典「${dictionary.name}」吗？',
      type: ConfirmType.delete,
      confirmText: '删除',
      cancelText: '取消',
    );
    if (!confirmed) return;
    await _cache.deleteDictionary(dictionary.id);
    if (!mounted) return;
    setState(() {
      _reloadDictionaries();
      // 选中的词典可能已被删除，重新生成结果避免展示旧词典内容
      _results = _generateNames();
    });
  }

  // ================= 参数变化 =================

  /// 参数变化处理
  void _onOptionsChanged(NameGenOptions options) {
    _cache.saveOptions(options);
    setState(() => _options = options);
  }

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        // 左侧：类别切换 + 词典管理
        SizedBox(
          width: 244,
          child: Column(
            children: [
              const SizedBox(height: 16),
              Expanded(
                child: NameDictionaryPanel(
                  dictionaries: _dictionaries[_category] ?? const [],
                  selectedId: _selectedIds[_category] ?? '',
                  onSelected: _selectDictionary,
                  onEdit: _editDictionary,
                  onDelete: _deleteDictionary,
                  onCreate: _createDictionary,
                  onReorder: _reorderDictionaries,
                ),
              ),
            ],
          ),
        ),
        // 竖直分隔线
        Container(width: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
        // 右侧：参数配置 + 生成 + 结果
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 参数行 + 生成按钮
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: NameOptionsPanel(
                        category: _category,
                        dictionary: _currentDictionary,
                        options: _options,
                        surnameController: _surnameController,
                        suffixController: _suffixController,
                        surnameFocusNode: _surnameFocusNode,
                        suffixFocusNode: _suffixFocusNode,
                        onChanged: _onOptionsChanged,
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _generate,
                      icon: const Icon(Icons.casino_rounded, size: 18),
                      label: const Text('生成'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // 结果区
                Expanded(
                  child: NameResultPanel(
                    names: _results,
                    onSelect: _selectName,
                    onClear: _clearResults,
                    emptyHint: '点击"生成"按钮开始取名，点击名字即可复制并关闭',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
