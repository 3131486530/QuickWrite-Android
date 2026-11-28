import 'package:flutter/material.dart';
import 'package:quick_write/core/models/custom_highlight.dart';
import 'package:quick_write/core/services/cache_services/misc_cache_service.dart';
import 'package:quick_write/core/services/workspace/custom_highlight_service.dart';
import 'package:quick_write/core/utils/color_utils.dart';
import 'package:quick_write/core/utils/ime_cursor_fixer.dart';
import 'package:quick_write/core/utils/typography_extension.dart';
import 'package:quick_write/shared/dialogs/color_picker_dialog.dart';
import 'package:quick_write/shared/widgets/qw_dialogs.dart';
import 'package:quick_write/shared/widgets/qw_text_field.dart';
import 'right_sidebar_widgets.dart';

/// 分组编辑结果（返回给调用方用于提示）
class CustomHighlightGroupEditResult {
  /// 因语法非法被忽略的正则条数
  final int invalidRegexCount;

  /// 因已在其他分组中存在而跳过的词条数
  final int conflictCount;

  /// 是否删除了该分组
  final bool deleted;

  /// 是否有实际写入
  final bool saved;

  const CustomHighlightGroupEditResult({
    this.invalidRegexCount = 0,
    this.conflictCount = 0,
    this.deleted = false,
    this.saved = false,
  });

  /// 全部跳过的条数
  int get skippedCount => invalidRegexCount + conflictCount;
}

/// 显示单个自定义高亮分组的编辑弹窗
///
/// 一个分组 = 一种颜色 + 一本独立词库，词库内部用顿号「、」分隔词条，
/// 以「re:」开头的词条按正则表达式匹配（正则词条建议单独一行）。
Future<CustomHighlightGroupEditResult?> showCustomHighlightGroupDialog({
  required BuildContext context,
  required CustomHighlightService service,
  required String groupId,
  required bool isNewGroup,
}) {
  final CustomHighlightGroup? group = service.groupById(groupId);
  if (group == null) return Future.value(null);

  return showDialogBase<CustomHighlightGroupEditResult>(
    context: context,
    title: isNewGroup ? '新建高亮分组' : '编辑高亮分组',
    subtitle: '本组词条共用同一颜色，词条用「、」分隔',
    titleIcon: Icons.format_ink_highlighter,
    width: 520,
    height: 560,
    adaptiveHeight: true,
    content: _CustomHighlightGroupContent(
      service: service,
      groupId: groupId,
      isNewGroup: isNewGroup,
    ),
  );
}

class _CustomHighlightGroupContent extends StatefulWidget {
  final CustomHighlightService service;
  final String groupId;
  final bool isNewGroup;

  const _CustomHighlightGroupContent({
    required this.service,
    required this.groupId,
    required this.isNewGroup,
  });

  @override
  State<_CustomHighlightGroupContent> createState() =>
      _CustomHighlightGroupContentState();
}

class _CustomHighlightGroupContentState
    extends State<_CustomHighlightGroupContent> {
  /// 内容区左右留白
  static const double _horizontalPadding = 20;

  /// 正则词条前缀
  static const String _regexPrefix = 're:';

  late final TextEditingController _nameController;

  late final TextEditingController _wordsController;

  final FocusNode _wordsFocusNode = FocusNode();

  /// 当前分组颜色
  late String _colorHex;

  /// 保存中（防止重复点击）
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final group = widget.service.groupById(widget.groupId);
    _nameController = TextEditingController(text: group?.name ?? '');
    _wordsController = TextEditingController(text: group?.wordsText ?? '');
    _colorHex = group?.colorHex ?? CustomHighlightGroup.defaultColorHex;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _wordsController.dispose();
    _wordsFocusNode.dispose();
    super.dispose();
  }

  /// 解析词库文本
  ///
  /// 规则：
  /// - 按行切分，空行忽略；
  /// - 整行以「re:」开头时，整行作为一个正则词条（正则内可含顿号）；
  /// - 其他行按顿号、逗号、分号切分为多个字面量词条。
  List<CustomHighlightItem> _parseWords(String raw) {
    final items = <CustomHighlightItem>[];
    void addRegex(String pattern) {
      final trimmed = pattern.trim();
      if (trimmed.isEmpty) return;
      items.add(CustomHighlightItem(
        keyword: trimmed,
        colorHex: _colorHex,
        isRegex: true,
      ));
    }

    void addLiteral(String word) {
      final trimmed = word.trim();
      if (trimmed.isEmpty) return;
      if (trimmed.toLowerCase().startsWith(_regexPrefix)) {
        addRegex(trimmed.substring(_regexPrefix.length));
        return;
      }
      items.add(CustomHighlightItem(keyword: trimmed, colorHex: _colorHex));
    }

    for (final rawLine in raw.split(RegExp(r'[\n\r]'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.toLowerCase().startsWith(_regexPrefix)) {
        addRegex(line.substring(_regexPrefix.length));
        continue;
      }
      for (final part in line.split(RegExp(r'[、,，;；]+'))) {
        addLiteral(part);
      }
    }
    return items;
  }

  /// 词条数量（用于实时计数展示）
  int get _liveWordCount => _parseWords(_wordsController.text).length;

  /// 选择分组颜色
  Future<void> _pickColor() async {
    await ColorPickerDialog.show(
      context: context,
      title: '选择分组颜色',
      initialColorHex: _colorHex,
      onColorSelected: (colorHex) {
        // 记忆本次选择，新建分组默认沿用
        MiscCacheService.instance.saveCustomHighlightLastColorHex(colorHex);
        setState(() => _colorHex = colorHex);
      },
    );
  }

  /// 保存分组
  Future<void> _handleSave() async {
    if (_saving) return;
    setState(() => _saving = true);

    final items = _parseWords(_wordsController.text);

    // 跨组去重：同一词条只保留在一个分组里，避免同一个词被两种颜色争抢
    final otherWords = <String>{};
    for (final g in widget.service.groups) {
      if (g.id == widget.groupId) continue;
      for (final item in g.items) {
        otherWords.add(item.isRegex ? 're:${item.keyword}' : item.keyword);
      }
    }
    final kept = <CustomHighlightItem>[];
    int conflictCount = 0;
    final seen = <String>{};
    for (final item in items) {
      final String key = item.isRegex ? 're:${item.keyword}' : item.keyword;
      if (!seen.add(key)) continue;
      if (otherWords.contains(key)) {
        conflictCount++;
        continue;
      }
      kept.add(item);
    }

    // 先落颜色与名称，再覆盖词库（词库颜色取分组色）
    // 只在名称或颜色真正变化时写一次，避免无改动也触发云端同步
    final current = widget.service.groupById(widget.groupId);
    final String name = _nameController.text.trim();
    if (current != null &&
        (current.name != name || current.colorHex != _colorHex)) {
      await widget.service.updateGroup(
        widget.groupId,
        name: name,
        colorHex: _colorHex,
      );
    }
    final int invalidCount =
        await widget.service.replaceGroupItems(widget.groupId, kept);

    if (!mounted) return;
    Navigator.of(context).pop(CustomHighlightGroupEditResult(
      invalidRegexCount: invalidCount,
      conflictCount: conflictCount,
      saved: true,
    ));
  }

  /// 删除分组
  Future<void> _handleDelete() async {
    await widget.service.removeGroup(widget.groupId);
    if (!mounted) return;
    Navigator.of(context).pop(const CustomHighlightGroupEditResult(deleted: true, saved: true));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _horizontalPadding,
        0,
        _horizontalPadding,
        20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildNameField(colorScheme),
          const SizedBox(height: 14),
          _buildColorRow(colorScheme),
          const SizedBox(height: 14),
          _buildWordsHeader(colorScheme),
          const SizedBox(height: 6),
          _buildWordsField(colorScheme),
          const SizedBox(height: 8),
          Text(
            '词条用顿号「、」分隔；以 re: 开头的按正则匹配，正则请单独一行',
            style: context.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          _buildActions(colorScheme),
        ],
      ),
    );
  }

  /// 分组名称输入行
  Widget _buildNameField(ColorScheme colorScheme) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text('分组名称', style: context.titleSmall),
        ),
        Expanded(
          child: QwTextField(
            controller: _nameController,
            style: context.bodyMedium,
            decoration: InputDecoration(
              isDense: true,
              hintText: '如：人物、地名、功法',
              hintStyle: TextStyle(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 颜色行：色点 + 色值 + 选择按钮
  Widget _buildColorRow(ColorScheme colorScheme) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text('高亮颜色', style: context.titleSmall),
        ),
        GestureDetector(
          onTap: _pickColor,
          child: ColorIndicator(color: ColorUtils.parseHex(_colorHex)),
        ),
        const SizedBox(width: 10),
        Text(
          _colorHex,
          style: context.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontFamily: 'monospace',
          ),
        ),
        const Spacer(),
        TextButton(
          onPressed: _pickColor,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          child: const Text('选择颜色'),
        ),
      ],
    );
  }

  /// 词库标题行
  Widget _buildWordsHeader(ColorScheme colorScheme) {
    return Row(
      children: [
        Text('词库', style: context.titleSmall),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '${_liveWordCount} 条',
            style: context.bodySmall?.copyWith(color: colorScheme.primary),
          ),
        ),
        const Spacer(),
        // 清空词库：把输入框内容清掉，保存后生效
        if (_wordsController.text.trim().isNotEmpty)
          TextButton(
            onPressed: () {
              _wordsController.clear();
              setState(() {});
            },
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              foregroundColor: colorScheme.onSurfaceVariant,
            ),
            child: const Text('清空'),
          ),
      ],
    );
  }

  /// 词库输入框
  Widget _buildWordsField(ColorScheme colorScheme) {
    return ImeCursorFixerWrapper(
      controller: _wordsController,
      focusNode: _wordsFocusNode,
      child: QwTextField(
        controller: _wordsController,
        focusNode: _wordsFocusNode,
        onChanged: (_) => setState(() {}),
        style: context.bodyMedium,
        minLines: 6,
        maxLines: 10,
        textAlignVertical: TextAlignVertical.top,
        decoration: InputDecoration(
          hintText: '林轩、苏清月、青云宗\nre:【[^】]*】',
          hintStyle: context.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
          ),
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          contentPadding: const EdgeInsets.all(12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  /// 底部操作区
  Widget _buildActions(ColorScheme colorScheme) {
    return Row(
      children: [
        if (!widget.isNewGroup)
          TextButton.icon(
            onPressed: _saving ? null : _handleDelete,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('删除分组'),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
          ),
        const Spacer(),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        const SizedBox(width: 10),
        FilledButton(
          onPressed: _saving ? null : _handleSave,
          style: FilledButton.styleFrom(backgroundColor: colorScheme.primary),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
