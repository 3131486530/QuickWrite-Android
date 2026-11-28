import 'package:flutter/material.dart';
import 'package:quick_write/core/models/custom_highlight.dart';
import 'package:quick_write/core/services/cache_services/misc_cache_service.dart';
import 'package:quick_write/core/services/workspace/custom_highlight_service.dart';
import 'package:quick_write/core/utils/custom_highlight_regex.dart';
import 'package:quick_write/core/utils/ime_cursor_fixer.dart';
import 'package:quick_write/core/utils/typography_extension.dart';
import 'package:quick_write/shared/widgets/qw_dialogs.dart';
import 'package:quick_write/shared/widgets/qw_snackbar.dart';
import 'package:quick_write/shared/widgets/qw_text_field.dart';

/// 显示自定义高亮的词库编辑弹窗
///
/// 与敏感词检测的「编辑词库」保持一致的使用方式：把全部高亮项摊平成文本，
/// 一行一条，适合一次性增删改大量词条，省去逐条点击与编辑。
/// 每行格式：`关键词`、`关键词=#RRGGBB`、`re:正则表达式=#RRGGBB`。
/// 返回 true 表示已保存并写回配置。
Future<bool> showCustomHighlightLibraryDialog({
  required BuildContext context,
  required CustomHighlightService service,
}) async {
  final result = await showDialogBase<bool>(
    context: context,
    title: '编辑高亮词库',
    subtitle: '一行一条，可用「=颜色」指定色值，「re:」表示正则',
    titleIcon: Icons.format_list_bulleted_rounded,
    width: 520,
    height: 620,
    content: _CustomHighlightLibraryContent(service: service),
  );
  return result ?? false;
}

/// 词库编辑弹窗内容
class _CustomHighlightLibraryContent extends StatefulWidget {
  /// 自定义高亮服务（读取与写回全部高亮项）
  final CustomHighlightService service;

  const _CustomHighlightLibraryContent({required this.service});

  @override
  State<_CustomHighlightLibraryContent> createState() =>
      _CustomHighlightLibraryContentState();
}

class _CustomHighlightLibraryContentState
    extends State<_CustomHighlightLibraryContent> {
  /// 内容区左右留白
  static const double _horizontalPadding = 24;

  /// 词库输入控制器
  late final TextEditingController _controller;

  /// 词库输入框焦点节点
  final FocusNode _focusNode = FocusNode();

  /// 正则前缀
  static const String _regexPrefix = 're:';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _buildInitialText());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 把现有高亮项渲染成文本，颜色始终写出以免批量编辑后丢色
  String _buildInitialText() {
    final buffer = StringBuffer();
    for (final item in widget.service.items) {
      if (buffer.isNotEmpty) buffer.write('\n');
      if (item.isRegex) buffer.write(_regexPrefix);
      buffer
        ..write(item.keyword)
        ..write('=')
        ..write(item.colorHex);
    }
    return buffer.toString();
  }

  /// 退出输入框焦点
  void _unfocus() => FocusScope.of(context).unfocus();

  /// 解析一行文本
  ///
  /// 支持 `关键词`、`关键词=#RRGGBB`、`re:表达式=#RRGGBB` 三种写法；
  /// 未写颜色时沿用同名旧项的颜色，新词则使用上次选择的颜色。
  CustomHighlightItem? _parseLine(String rawLine) {
    var line = rawLine.trim();
    if (line.isEmpty) return null;

    // 提取行尾的颜色（=#RRGGBB 或 =RRGGBB）
    String? colorHex;
    final int eqIndex = line.lastIndexOf('=');
    if (eqIndex > 0) {
      final candidate = line.substring(eqIndex + 1).trim();
      if (RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(candidate)) {
        colorHex = candidate.startsWith('#') ? candidate : '#$candidate';
        line = line.substring(0, eqIndex).trim();
      }
    }
    if (line.isEmpty) return null;

    // 提取正则前缀
    bool isRegex = false;
    if (line.toLowerCase().startsWith(_regexPrefix)) {
      isRegex = true;
      line = line.substring(_regexPrefix.length).trim();
    }
    if (line.isEmpty) return null;

    // 颜色缺省时优先复用旧项颜色，其次使用上次选择的颜色
    if (colorHex == null) {
      for (final item in widget.service.items) {
        if (item.keyword == line) {
          colorHex = item.colorHex;
          break;
        }
      }
      colorHex ??= MiscCacheService.instance.getCustomHighlightLastColorHex();
    }

    return CustomHighlightItem(
      keyword: line,
      colorHex: colorHex!.toUpperCase(),
      isRegex: isRegex,
    );
  }

  /// 保存词库
  Future<void> _handleSave() async {
    final lines = _controller.text.split('\n');
    final items = <CustomHighlightItem>[];
    final seen = <String>{};
    int invalidRegexCount = 0;

    for (final line in lines) {
      final item = _parseLine(line);
      if (item == null) continue;
      // 同名词条只保留第一条，与逐条添加时的去重行为一致
      if (!seen.add(item.keyword)) continue;
      if (item.isRegex && !CustomHighlightRegex.isValid(item.keyword)) {
        invalidRegexCount++;
        continue;
      }
      items.add(item);
    }

    await widget.service.replaceAll(items);
    if (!mounted) return;
    if (invalidRegexCount > 0) {
      SnackBarService.show(
        context,
        '已保存，另有 $invalidRegexCount 条正则表达式无效被忽略',
      );
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _horizontalPadding,
              ),
              child: ImeCursorFixerWrapper(
                controller: _controller,
                focusNode: _focusNode,
                child: QwTextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  onTapOutside: (_) => _unfocus(),
                  style: context.bodyMedium,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    hintText: '关键词=#FFB300\nre:(?<=【)[^】]*(?=】)=#FF5252',
                    hintStyle: context.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.7,
                      ),
                    ),
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.all(12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              _horizontalPadding,
              8,
              _horizontalPadding,
              0,
            ),
            child: Text(
              '一行一条；不写颜色时沿用该词原颜色或上次选择的颜色',
              style: context.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          // 底部按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(
              _horizontalPadding,
              12,
              _horizontalPadding,
              0,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _handleSave,
                  style: FilledButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                  ),
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
