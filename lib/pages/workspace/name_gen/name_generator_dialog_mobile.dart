import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quick_write/core/constants/material_icons.dart';
import 'package:quick_write/core/models/name_gen/name_dictionary.dart';
import 'package:quick_write/core/models/name_gen/name_gen_options.dart';
import 'package:quick_write/core/services/cache_services/name_gen_cache_service.dart';
import 'package:quick_write/core/services/cloud_sync/cloud_sync_service.dart';
import 'package:quick_write/core/services/name_gen/name_generator.dart';
import 'package:quick_write/core/services/settings_service.dart';
import 'package:quick_write/core/utils/typography_extension.dart';
import 'package:quick_write/pages/workspace/name_gen/widgets/name_dictionary_editor_dialog.dart';
import 'package:quick_write/pages/workspace/name_gen/widgets/name_dictionary_sheet.dart';
import 'package:quick_write/pages/workspace/name_gen/widgets/name_result_panel.dart';
import 'package:quick_write/shared/widgets/widgets.dart';
import 'package:quick_write/shared/widgets/qw_text_field.dart';

/// 结果标签之间的间距
const double _chipGap = 8;

/// 结果标签的左右内边距
const double _chipHorizontalPadding = 8;

/// 每次生成的名字数量
///
/// 结果区一行一个名字，固定生成七条，不再提供自定义数量。
const int _batchCount = 7;

/// 显示移动端随机取名弹窗
///
/// 以卡片式弹窗承载随机取名功能：弹窗内自上而下为类别切换、词典入口、
/// 生成参数、结果区与生成按钮，四周保留留白。词典的选中、新建、
/// 编辑与删除通过底部弹窗完成。
///
/// 点击任意名字即复制到剪贴板并关闭弹窗，被点击的名字作为返回值返回；
/// 弹窗被取消时返回 null，由调用方决定是否插入编辑器。
Future<String?> showMobileNameGeneratorDialog({required BuildContext context}) {
  return showDialogBase<String>(
    context: context,
    title: '随机取名',
    subtitle: '点击名字即复制并关闭，光标在正文时直接插入',
    titleIcon: Icons.casino_outlined,
    width: 420,
    height: 620,
    content: const _MobileNameGeneratorDialog(),
  );
}

/// 移动端随机取名弹窗内容
class _MobileNameGeneratorDialog extends StatefulWidget {
  const _MobileNameGeneratorDialog();

  @override
  State<_MobileNameGeneratorDialog> createState() => _MobileNameGeneratorDialogState();
}

class _MobileNameGeneratorDialogState extends State<_MobileNameGeneratorDialog> {
  /// 内容区左右留白
  static const double _horizontalPadding = 20;

  /// 底部主按钮的高度
  static const double _primaryButtonHeight = 42;

  /// 缓存服务
  final NameGenCacheService _cache = NameGenCacheService.instance;

  /// 云同步服务：词典文件由同步直接落盘，需要据此重新读盘
  final CloudSyncService _syncService = CloudSyncService.instance;

  /// 已处理过的同步版本号，避免同步进度通知反复触发读盘
  int _handledSyncRevision = 0;

  /// 随机数发生器
  final Random _random = Random();

  /// 自定义姓氏输入控制器

  /// 自定义后缀输入控制器

  /// 当前类别
  // 章节式词典不再区分类别，统一用 other 承载全部自建词典
  NameCategory _category = NameCategory.other;

  /// 各类别的词典列表
  final Map<NameCategory, List<NameDictionary>> _dictionaries = {};

  /// 各类别选中的词典 ID
  final Map<NameCategory, String> _selectedIds = {};

  /// 本次生成结果
  List<String> _results = const [];

  @override
  void initState() {
    super.initState();
    _reloadDictionaries();
    // 打开弹窗时立即生成一次结果
    _results = _generateNames();

    _handledSyncRevision = _syncService.syncRevision;
    _syncService.addListener(_onCloudSyncChanged);
    // 云同步可能已把新词典写进 dict 目录，先按内存渲染首帧，再从磁盘校正
    _refreshDictionariesFromDisk();
  }

  @override
  void dispose() {
    _syncService.removeListener(_onCloudSyncChanged);
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
      options: const NameGenOptions(batchCount: _batchCount),
      count: _batchCount,
      random: _random,
    );
  }

  /// 点击生成按钮
  ///
  /// 批量生成名字并替换当前结果，保持弹窗位置不变；无法生成时提示用户。
  void _generate() {
    if (_currentDictionary == null) {
      SnackBarService.show(context, '请先选择或新建一个词典');
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
  /// 复制名字到剪贴板并关闭弹窗，把名字作为结果返回给调用方，
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

  /// 打开词典管理弹窗并处理其中选择的操作
  Future<void> _openDictionarySheet() async {
    final action = await showNameDictionarySheet(
      context: context,
      dictionaries: _dictionaries[_category] ?? const [],
      selectedId: _selectedIds[_category] ?? '',
    );
    if (!mounted) return;
    // 弹窗内可能拖动调整过词典顺序，返回后按磁盘顺序刷新
    setState(_reloadDictionaries);
    if (action == null) return;

    switch (action.type) {
      case NameDictionarySheetActionType.select:
        _selectDictionary(action.dictionary!.id);
        break;
      case NameDictionarySheetActionType.edit:
        await _editDictionary(action.dictionary!);
        break;
      case NameDictionarySheetActionType.delete:
        await _deleteDictionary(action.dictionary!);
        break;
      case NameDictionarySheetActionType.create:
        await _createDictionary();
        break;
    }
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
    setState(_reloadDictionaries);
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
    setState(_reloadDictionaries);
  }

  // ================= 参数变化 =================

  /// 退出输入框焦点
  void _unfocus() => FocusScope.of(context).unfocus();

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 主内容区可滚动；生成按钮固定于底部，便于随时触发生成
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(_horizontalPadding, 12, _horizontalPadding, 4),
            children: [
              _buildDictionarySelector(),
              const SizedBox(height: 16),
              _buildResultsSection(),
            ],
          ),
        ),
        _buildGenerateBar(),
      ],
    );
  }

  /// 构建词典选择入口
  ///
  /// 展示当前词典名称与词典数量，点击打开词典管理弹窗。
  Widget _buildDictionarySelector() {
    final colorScheme = Theme.of(context).colorScheme;
    final dictionary = _currentDictionary;
    final count = _dictionaries[_category]?.length ?? 0;

    return Material(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: _openDictionarySheet,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(MaterialIcons.book_4, size: 20, color: colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '当前词典',
                      style: context.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      dictionary?.name ?? '暂无词典',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.titleSmall?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '$count 个',
                style: context.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 20, color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建结果区
  ///
  /// 以标签列表展示名字，一行一个；点击任意名字即复制并关闭弹窗。
  Widget _buildResultsSection() {
    final colorScheme = Theme.of(context).colorScheme;

    if (_results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text(
            '点击"生成"按钮开始取名，点击名字即可复制并关闭',
            textAlign: TextAlign.center,
            style: context.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: _results.length,
      separatorBuilder: (context, index) => const SizedBox(height: _chipGap),
      itemBuilder: (context, index) => _NameChip(
        name: _results[index],
        onTap: () => _selectName(_results[index]),
      ),
    );
  }

  /// 构建底部操作栏
  ///
  /// 左侧为生成按钮，右侧为清空结果的按钮，两者等高；
  /// 没有结果时清空按钮不可用。
  Widget _buildGenerateBar() {
    final colorScheme = Theme.of(context).colorScheme;
    final hasNames = _results.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(_horizontalPadding, 8, _horizontalPadding, 12),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: _primaryButtonHeight,
              child: FilledButton.icon(
                onPressed: _generate,
                icon: const Icon(Icons.casino_rounded, size: 20),
                label: const Text('生成'),
                style: FilledButton.styleFrom(padding: EdgeInsets.zero),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _primaryButtonHeight,
            height: _primaryButtonHeight,
            child: Tooltip(
              message: '清空结果',
              child: PressScale(
                onTap: hasNames ? _clearResults : null,
                child: Center(
                  child: Icon(
                    Icons.delete_sweep_outlined,
                    size: 24,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: hasNames ? 1 : 0.3),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

}

/// 单个名字标签
///
/// 宽度铺满所在行，文字居中；字号与字体跟随章节正文字体设置，
/// 点击即复制名字并关闭弹窗。
class _NameChip extends StatelessWidget {
  /// 名字文本
  final String name;

  /// 点击回调
  final VoidCallback onTap;

  const _NameChip({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final settings = SettingsService.instance;

    return Material(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _chipHorizontalPadding,
              vertical: 10,
            ),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: settings.fontSize,
                fontFamily: settings.fontFamily,
                letterSpacing: settings.letterSpacing,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
