import 'dart:async';

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:uuid/uuid.dart';

import 'package:quick_write/core/models/name_gen/name_dictionary.dart';
import 'package:quick_write/core/services/settings_service.dart';
import 'package:quick_write/core/utils/color_utils.dart';
import 'package:quick_write/core/utils/ime_cursor_fixer.dart';
import 'package:quick_write/core/utils/platform_capabilities.dart';
import 'package:quick_write/core/utils/typography_extension.dart';
import 'package:quick_write/shared/widgets/qw_dropdown.dart';
import 'package:quick_write/shared/widgets/qw_switch.dart';
import 'package:quick_write/shared/widgets/qw_text_field.dart';

/// 打开词典编辑页
///
/// [dictionary] 为空表示新建词典，否则表示编辑该词典；
/// [initialCategory] 指定新建词典的默认类别。
/// 返回编辑后的词典对象；用户返回时返回 null。
///
/// 采用与章节编辑器同源的 re_editor 内核承载词条，而不是逐池堆叠输入框：
/// 单个编辑器实例只渲染可视区域内的行，数千条词条也只有一屏的绘制开销，
/// 切换词组池等价于切换章节，输入、滚动、长按选区都由同一套内核处理。
Future<NameDictionary?> pushNameDictionaryEditorPage({
  required BuildContext context,
  NameDictionary? dictionary,
  NameCategory initialCategory = NameCategory.person,
}) {
  return Navigator.of(context).push<NameDictionary>(
    MaterialPageRoute<NameDictionary>(
      builder: (_) => NameDictionaryEditorPage(
        dictionary: dictionary,
        initialCategory: initialCategory,
      ),
    ),
  );
}

/// 词典编辑页
///
/// 顶部维护词典名与类别相关设置，中部为词组池标签（相当于章节标签），
/// 下部的编辑区用 re_editor 承载当前池的全部词条。
class NameDictionaryEditorPage extends StatefulWidget {
  /// 待编辑的词典，为空表示新建
  final NameDictionary? dictionary;

  /// 新建词典时的默认类别
  final NameCategory initialCategory;

  const NameDictionaryEditorPage({
    super.key,
    this.dictionary,
    required this.initialCategory,
  });

  @override
  State<NameDictionaryEditorPage> createState() => _NameDictionaryEditorPageState();
}

class _NameDictionaryEditorPageState extends State<NameDictionaryEditorPage> with WidgetsBindingObserver {
  /// 词条计数刷新延迟，避免每次按键都重建界面
  static const Duration _countDebounce = Duration(milliseconds: 200);

  late final TextEditingController _nameController;
  late final FocusNode _nameFocusNode;
  late final FocusNode _editorFocusNode;
  late final CodeLineEditingController _editor;

  late NameCategory _category;
  late bool _givenFirst;
  late int _partCount;

  /// 当前类别下的词组池键，顺序即标签顺序
  late List<String> _poolKeys;

  /// 各池的文本草稿，切换池时先落草稿再换编辑器内容
  final Map<String, String> _drafts = <String, String>{};

  late String _activeKey;

  Timer? _countTimer;
  int _activeCount = 0;

  /// 全词典词条数缓存
  ///
  /// 只在内容变化、切换池、改池数量时重算，避免每帧 build 都全量解析
  int _totalCountCache = 0;

  /// 词条编辑区是否处于输入状态
  ///
  /// 仅在编辑区获得焦点时收起顶部设置区；不能用键盘高度判断，
  /// 键盘高度变化会逐帧重建整棵树，把输入框和编辑器连根拔掉导致输入法秒关。
  bool _editorFocused = false;

  /// 键盘是否可见（仅在变化时更新，用于编辑结束收起键盘后恢复设置区）
  bool _keyboardVisible = false;

  /// 是否进入紧凑模式：编辑区持有焦点且键盘可见
  ///
  /// 此时收起顶部设置区与底部统计栏，把竖向空间让给编辑区
  bool get _compactMode => _editorFocused && _keyboardVisible;

  /// 是否编辑既有词典（编辑时类别与池数量锁定，避免词条分组错位）
  bool get _isEditing => widget.dictionary != null;

  @override
  void initState() {
    super.initState();
    final NameDictionary? dictionary = widget.dictionary;
    _nameController = TextEditingController(text: dictionary?.name ?? '');
    _nameFocusNode = FocusNode();
    _editorFocusNode = FocusNode();
    _category = dictionary?.category ?? widget.initialCategory;
    _givenFirst = dictionary?.givenFirst ?? false;
    _partCount = _resolvePartCount(dictionary);
    _poolKeys = NamePoolKeys.keysOf(_category, partCount: _partCount);
    for (final String key in _poolKeys) {
      _drafts[key] = dictionary?.pool(key).join('、') ?? '';
    }
    _activeKey = _poolKeys.first;
    _activeCount = _parsePool(_drafts[_activeKey] ?? '').length;
    _editor = CodeLineEditingController.fromText(_drafts[_activeKey]);
    _editor.addListener(_onEditorChanged);
    _totalCountCache = _sumPools();
    _editorFocusNode.addListener(_handleEditorFocusChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _countTimer?.cancel();
    _editor.removeListener(_onEditorChanged);
    _editorFocusNode.removeListener(_handleEditorFocusChanged);
    WidgetsBinding.instance.removeObserver(this);
    _editor.dispose();
    _nameController.dispose();
    _nameFocusNode.dispose();
    _editorFocusNode.dispose();
    super.dispose();
  }

  /// 读取词典的词组池数量，非其他类别固定为默认值
  int _resolvePartCount(NameDictionary? dictionary) {
    if (dictionary == null || dictionary.category != NameCategory.other) {
      return NamePoolKeys.defaultPartCount;
    }
    return dictionary.partCount
        .clamp(NamePoolKeys.minPartCount, NamePoolKeys.maxPartCount)
        .toInt();
  }

  /// 解析词条文本
  ///
  /// 词条之间以顿号分隔，同时兼容换行、空格、逗号（含全角），
  /// 粘贴进来的一整段也能正确拆开，自动去空与去重。
  List<String> _parsePool(String raw) {
    final Set<String> result = <String>{};
    for (final String token in raw.split(RegExp(r'[\s,，、]+'))) {
      final String value = token.trim();
      if (value.isNotEmpty) result.add(value);
    }
    return result.toList();
  }

  /// 汇总全部池的词条总数
  int _sumPools() {
    int total = 0;
    for (final String key in _poolKeys) {
      total += _parsePool(_drafts[key] ?? '').length;
    }
    return total;
  }

  /// 编辑器内容变化时刷新词条计数
  void _onEditorChanged() {
    _countTimer?.cancel();
    _countTimer = Timer(_countDebounce, () {
      if (!mounted) return;
      _drafts[_activeKey] = _editor.text;
      final int count = _parsePool(_editor.text).length;
      final int total = _sumPools();
      if (count == _activeCount && total == _totalCountCache) return;
      setState(() {
        _activeCount = count;
        _totalCountCache = total;
      });
    });
  }

  /// 回车键写入顿号
  ///
  /// 词条以顿号分隔，回车不应产生换行（换行会在文本中留下空行，
  /// 解析时虽被忽略，但视觉上把一段词条割裂成多行），此处直接替换为分隔符。
  void _handleNewLine() {
    _editor.replaceSelection('、');
  }

  /// 切换词组池
  void _switchPool(String key) {
    if (key == _activeKey) return;
    _drafts[_activeKey] = _editor.text;
    setState(() {
      _activeKey = key;
      _activeCount = _parsePool(_drafts[key] ?? '').length;
      _totalCountCache = _sumPools();
    });
    _editor.codeLines = CodeLines.fromText(_drafts[key] ?? '');
    _editor.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
    _editorFocusNode.requestFocus();
  }

  /// 切换类别（仅新建时可用）
  void _onCategoryChanged(NameCategory category) {
    if (category == _category) return;
    setState(() {
      _category = category;
      _givenFirst = false;
      _partCount = NamePoolKeys.defaultPartCount;
      _poolKeys = NamePoolKeys.keysOf(_category, partCount: _partCount);
      _drafts
        ..clear()
        ..addEntries(_poolKeys.map((key) => MapEntry<String, String>(key, '')));
      _activeKey = _poolKeys.first;
      _activeCount = 0;
      _totalCountCache = 0;
    });
    _editor.codeLines = CodeLines.empty();
  }

  /// 调整其他类别的词组池数量
  ///
  /// 保留仍在范围内的池文本，超出范围的草稿丢弃。
  void _onPartCountChanged(int count) {
    if (count == _partCount) return;
    _drafts[_activeKey] = _editor.text;
    final List<String> keys = NamePoolKeys.keysOf(_category, partCount: count);
    setState(() {
      _partCount = count;
      _poolKeys = keys;
      _drafts.removeWhere((key, _) => !keys.contains(key));
      for (final String key in keys) {
        _drafts.putIfAbsent(key, () => '');
      }
      if (!keys.contains(_activeKey)) {
        _activeKey = keys.first;
      }
      _activeCount = _parsePool(_drafts[_activeKey] ?? '').length;
      _totalCountCache = _sumPools();
    });
    _editor.codeLines = CodeLines.fromText(_drafts[_activeKey] ?? '');
    _editor.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
  }

  /// 汇总全部池的词条数与文本
  Map<String, List<String>> _collectPools() {
    _drafts[_activeKey] = _editor.text;
    final Map<String, List<String>> pools = <String, List<String>>{};
    for (final String key in _poolKeys) {
      pools[key] = _parsePool(_drafts[key] ?? '');
    }
    return pools;
  }

  /// 完成编辑并返回词典对象
  void _handleSave() {
    final Map<String, List<String>> pools = _collectPools();
    final String name = _nameController.text.trim();
    final NameDictionary dictionary = NameDictionary(
      id: widget.dictionary?.id ?? const Uuid().v4(),
      name: name.isEmpty ? _category.label : name,
      category: _category,
      isBuiltin: widget.dictionary?.isBuiltin ?? false,
      // 依据词条内容判定生成方式并写入词典，避免运行时再推断
      isCharBased: NameDictionary.inferCharBased(_category, pools),
      givenFirst: _category == NameCategory.person && _givenFirst,
      pools: pools,
    );
    Navigator.of(context).pop(dictionary);
  }

  /// 词条编辑区焦点变化
  ///
  /// 焦点只在整个编辑过程中变化数次，用它驱动顶部设置区收起，
  /// 相比监听键盘高度（弹起动画期逐帧变化）不会拖垮整棵组件树。
  void _handleEditorFocusChanged() {
    final bool focused = _editorFocusNode.hasFocus;
    if (focused == _editorFocused) return;
    setState(() => _editorFocused = focused);
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final bool visible = View.of(context).viewInsets.bottom > 0;
    if (visible == _keyboardVisible) return;
    setState(() => _keyboardVisible = visible);
  }

  @override
  Widget build(BuildContext context) {
    // 编辑词条时收起顶部设置区与底部统计栏，把竖向空间让给编辑区，
    // 避免输入法把可编辑区域压到只剩几行。
    // 注意必须用 Offstage 而非条件删除：删除会让 Column 子节点位移、
    // 输入框与编辑器被重建，焦点丢失导致输入法弹出即关闭。
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑词典' : '新建词典'),
        actions: <Widget>[
          TextButton(
            onPressed: _handleSave,
            child: const Text('完成'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Offstage(offstage: _compactMode, child: _buildHeader(context)),
            _buildPoolTabs(context),
            Expanded(child: _buildEditor(context, editorFocused: _compactMode)),
            Offstage(offstage: _compactMode, child: _buildStatusBar(context)),
          ],
        ),
      ),
    );
  }

  /// 顶部设置区：词典名与类别相关开关
  Widget _buildHeader(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ImeCursorFixerWrapper(
            controller: _nameController,
            focusNode: _nameFocusNode,
            child: QwTextField(
              controller: _nameController,
              focusNode: _nameFocusNode,
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
              style: context.bodyMedium,
              maxLines: 1,
              decoration: InputDecoration(
                hintText: '请输入词典名称',
                hintStyle: context.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              if (!_isEditing) ...<Widget>[
                Expanded(
                  child: CustomDropdown(
                    width: double.infinity,
                    value: _category.id,
                    items: NameCategory.values
                        .map((NameCategory c) => DropdownItem(displayText: c.label, value: c.id))
                        .toList(),
                    onChanged: (String value) =>
                        _onCategoryChanged(NameCategory.fromId(value)),
                  ),
                ),
                const SizedBox(width: 12),
              ] else ...<Widget>[
                Expanded(
                  child: Text(
                    _category.label,
                    style: context.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
              if (_category == NameCategory.person)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text('名在前', style: context.bodySmall),
                    const SizedBox(width: 8),
                    QwSwitch(
                      value: _givenFirst,
                      onChanged: (bool value) => setState(() => _givenFirst = value),
                    ),
                  ],
                ),
              if (_category == NameCategory.other)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text('词组池', style: context.bodySmall),
                    const SizedBox(width: 8),
                    CustomDropdown(
                      width: 96,
                      value: '$_partCount',
                      items: <DropdownItem>[
                        for (int count = NamePoolKeys.minPartCount;
                            count <= NamePoolKeys.maxPartCount;
                            count++)
                          DropdownItem(displayText: '$count 个', value: '$count'),
                      ],
                      onChanged: (String value) => _onPartCountChanged(int.parse(value)),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 词组池标签行，形如章节标签，点击切换编辑对象
  Widget _buildPoolTabs(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _poolKeys.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final String key = _poolKeys[index];
          final bool selected = key == _activeKey;
          return GestureDetector(
            onTap: () => _switchPool(key),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: selected
                    ? colorScheme.primaryContainer
                    : colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                NamePoolKeys.labelOf(_category, key),
                style: context.bodySmall?.copyWith(
                  color: selected ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 词条编辑区
  ///
  /// 与正文编辑器同源的 re_editor：按行虚拟化渲染，滚动与选区由内核处理，
  /// 数千条词条不会像多输入框方案那样一次性构建全部文本控件。
  ///
  /// 光标样式与正文保持一致：静态光标常亮，呼吸光标按同一余弦曲线起伏，
  /// 两者都需显式传参，否则编辑器只走默认闪烁。
  Widget _buildEditor(BuildContext context, {required bool editorFocused}) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final bool breathing = PlatformCapabilities.isMobile &&
        SettingsService.instance.settings.breathingCursorEnabled;
    return Container(
      margin: EdgeInsets.fromLTRB(16, editorFocused ? 6 : 10, 16, 0),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: CodeEditor(
        controller: _editor,
        focusNode: _editorFocusNode,
        // 进入页面不主动唤起键盘，避免遮挡词条列表
        autofocus: false,
        wordWrap: true,
        hint: '词条之间用「、」分隔',
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        staticCursor: SettingsService.instance.settings.staticCursorEnabled,
        breathingCursor: breathing,
        onNewLine: _handleNewLine,
        style: CodeEditorStyle(
          fontSize: 16,
          fontHeight: 1.6,
          textColor: ColorUtils.getFontColorForTheme(context),
          backgroundColor: Colors.transparent,
          cursorColor: ColorUtils.getCursorColorForTheme(context, colorScheme.primary),
          cursorWidth: 2,
          selectionColor: colorScheme.primary.withValues(alpha: 0.25),
          highlightColor: colorScheme.primary.withValues(alpha: 0.25),
        ),
      ),
    );
  }

  /// 底部统计栏
  Widget _buildStatusBar(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Text(
        '当前池 $_activeCount 条 · 全词典 $_totalCountCache 条',
        style: context.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
      ),
    );
  }
}
