import 'package:flutter/material.dart';
import 'package:quick_write/core/services/settings_service.dart';
import 'package:quick_write/core/utils/typography_extension.dart';
import 'package:quick_write/shared/widgets/qw_tooltip.dart';

/// 结果面板
///
/// 随机取名弹窗下方的结果区；名字以紧凑标签纵向排布，一行一个，
/// 字号跟随章节正文字体设置，点击任意名字即复制并关闭弹窗。
class NameResultPanel extends StatelessWidget {
  /// 展示的名字列表
  final List<String> names;

  /// 点击名字回调
  final Future<void> Function(String name) onSelect;

  /// 清空结果回调
  final VoidCallback? onClear;

  /// 空列表时的提示文字
  final String emptyHint;

  const NameResultPanel({
    super.key,
    required this.names,
    required this.onSelect,
    required this.emptyHint,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 数量 + 清空
        Row(
          children: [
            Text(
              '生成结果',
              style: context.bodyMedium?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (names.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                '${names.length} 个',
                style: context.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
            const Spacer(),
            if (onClear != null && names.isNotEmpty)
              CursorTooltipTarget(
                tooltipContent: const Text('清空结果'),
                child: IconButton(
                  onPressed: onClear,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        // 名字标签：一行一个，纵向铺满
        Expanded(
          child: names.isEmpty
              ? Center(
                  child: Text(
                    emptyHint,
                    textAlign: TextAlign.center,
                    style: context.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                )
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final name in names) ...[
                        _NameChip(name: name, onTap: () => onSelect(name)),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// 单个名字标签
///
/// 悬浮时高亮，点击即复制名字并关闭弹窗。
class _NameChip extends StatefulWidget {
  final String name;
  final VoidCallback onTap;

  const _NameChip({required this.name, required this.onTap});

  @override
  State<_NameChip> createState() => _NameChipState();
}

class _NameChipState extends State<_NameChip> {
  /// 标签内容的最小宽度参考字数
  static const int _minContentChars = 4;

  /// 鼠标是否悬浮在标签上
  bool _hovered = false;

  /// 计算参考字数在当前文字样式下的宽度
  ///
  /// 作为标签内容的最小宽度：字数不足时在标签内居中，超出时按内容自适应。
  double _resolveMinContentWidth(BuildContext context, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: '字' * _minContentChars, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 字号与字体跟随章节正文字体设置，与正文观感保持一致
    final settings = SettingsService.instance;
    final textStyle = TextStyle(
      fontSize: settings.fontSize,
      fontFamily: settings.fontFamily,
      letterSpacing: settings.letterSpacing,
      color: colorScheme.onSurface,
    );

    return CursorTooltipTarget(
      tooltipContent: const Text('点击复制并关闭'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: _hovered
                  ? colorScheme.primary.withValues(alpha: 0.12)
                  : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _hovered
                    ? colorScheme.primary.withValues(alpha: 0.4)
                    : colorScheme.outlineVariant.withValues(alpha: 0.3),
              ),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: _resolveMinContentWidth(context, textStyle),
              ),
              child: Text(
                widget.name,
                textAlign: TextAlign.center,
                style: textStyle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
