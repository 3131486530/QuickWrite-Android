import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 查找匹配高亮工具
///
/// 在编辑器的 TextSpan 列表上叠加查找匹配项的背景高亮，
/// 使所有匹配的关键词以浅色标识，当前选中的匹配项以更醒目的颜色标识。
class FindMatchHighlighter {
  /// 将查找匹配高亮应用到一组按文本顺序排列的 TextSpan 上
  ///
  /// [spans] 已构建好的扁平 TextSpan 列表，每个 span 的 [TextSpan.text] 非空
  /// [matches] 匹配范围列表，偏移量相对于 spans 拼接后的完整文本
  /// [currentMatchIndex] 当前选中匹配在 [matches] 中的索引（-1 表示无选中）
  /// [matchColor] 普通匹配项的背景色
  /// [currentMatchColor] 当前选中匹配项的背景色
  ///
  /// 返回新的 TextSpan 列表，匹配范围内的文本被附加了背景色
  static List<TextSpan> apply({
    required List<TextSpan> spans,
    required List<TextSelection> matches,
    required int currentMatchIndex,
    required Color matchColor,
    required Color currentMatchColor,
  }) {
    if (matches.isEmpty || spans.isEmpty) return spans;

    // 匹配项按起点升序排好并把下标一并带上：span 是顺序遍历的，
    // 只需单向推进游标即可，避免每个 span 都把全部匹配扫一遍（O(n×m)）。
    final List<int> order = <int>[];
    for (int i = 0; i < matches.length; i++) {
      // 跳过空范围匹配
      if (matches[i].start < matches[i].end) order.add(i);
    }
    if (order.isEmpty) return spans;
    order.sort((int a, int b) => matches[a].start.compareTo(matches[b].start));

    final result = <TextSpan>[];
    int currentOffset = 0;
    // 已完全落在当前 span 之前的匹配不再参与后续判断
    int cursor = 0;

    for (final span in spans) {
      final spanText = span.text ?? '';
      final spanLength = spanText.length;
      final spanEnd = currentOffset + spanLength;

      while (cursor < order.length && matches[order[cursor]].end <= currentOffset) {
        cursor++;
      }

      // 收集与当前 span 重叠的匹配项索引（起点已超过 span 末尾即可停止）
      final overlapping = <int>[];
      for (int probe = cursor; probe < order.length; probe++) {
        final int idx = order[probe];
        final m = matches[idx];
        if (m.start >= spanEnd) break;
        if (m.end > currentOffset) overlapping.add(idx);
      }

      if (overlapping.isEmpty) {
        // 无重叠：原样保留
        result.add(span);
      } else {
        // 有重叠：按匹配边界分段，对落在匹配范围内的段附加背景色
        int pos = currentOffset;
        for (final idx in overlapping) {
          final m = matches[idx];
          // 将匹配范围裁剪到当前 span 范围内
          final matchStart = math.max(m.start, currentOffset);
          final matchEnd = math.min(m.end, spanEnd);

          // 匹配前的普通段
          if (matchStart > pos) {
            result.add(TextSpan(
              text: spanText.substring(pos - currentOffset, matchStart - currentOffset),
              style: span.style,
            ));
          }

          // 匹配段：当前选中匹配用 currentMatchColor，其他用 matchColor
          final isCurrent = idx == currentMatchIndex;
          result.add(TextSpan(
            text: spanText.substring(matchStart - currentOffset, matchEnd - currentOffset),
            style: span.style?.copyWith(
              backgroundColor: isCurrent ? currentMatchColor : matchColor,
            ),
          ));
          pos = matchEnd;
        }

        // 最后一个匹配之后的普通段
        if (pos < spanEnd) {
          result.add(TextSpan(
            text: spanText.substring(pos - currentOffset),
            style: span.style,
          ));
        }
      }

      currentOffset = spanEnd;
    }

    return result;
  }

  /// 获取普通匹配项的背景色（根据主题亮度自适应）
  static Color getMatchColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 暗色主题使用稍亮的黄色以保证可见性，亮色主题使用较淡的黄色
    return isDark
        ? const Color(0x66FFC107) // amber 500 @ 40%
        : const Color(0x55FFEB3B); // yellow 500 @ 33%
  }

  /// 获取当前选中匹配项的背景色（根据主题亮度自适应）
  static Color getCurrentMatchColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 当前匹配项需要比普通匹配更醒目
    return isDark
        ? const Color(0xFFFFC107) // amber 500 实色
        : const Color(0xFFFFA000); // amber 700 实色
  }
}

/// 当前查找匹配高亮绘制器
///
/// 注入到 RenderEditable 的背景层，按绘制器链的顺序排在选区之后、
/// 文字之前绘制，使当前匹配项的背景色不被文本选区遮盖。
class CurrentMatchHighlightPainter extends RenderEditablePainter {
  /// 本节点内的查找匹配范围列表（偏移量相对于节点文本）
  List<TextSelection> matches = const [];

  /// 当前选中匹配在 [matches] 中的索引（-1 表示无选中）
  int currentMatchIndex = -1;

  /// 当前匹配项的背景色
  Color? color;

  @override
  bool shouldRepaint(covariant RenderEditablePainter oldDelegate) {
    return oldDelegate is! CurrentMatchHighlightPainter ||
        !listEquals(oldDelegate.matches, matches) ||
        oldDelegate.currentMatchIndex != currentMatchIndex ||
        oldDelegate.color != color;
  }

  @override
  void paint(Canvas canvas, Size size, RenderEditable renderEditable) {
    final Color? effectiveColor = color;
    final int index = currentMatchIndex;
    if (effectiveColor == null) return;
    if (index < 0 || index >= matches.length) return;

    final TextSelection match = matches[index];
    if (!match.isValid || match.isCollapsed) return;

    // 裁剪到当前文本长度范围内，防止文本变化后残留的旧区间越界
    final int textLength = renderEditable.plainText.length;
    final int start = match.start.clamp(0, textLength);
    final int end = match.end.clamp(0, textLength);
    if (start >= end) return;

    final Paint paint = Paint()
      ..color = effectiveColor
      ..style = PaintingStyle.fill;

    // 匹配范围可能跨行，逐行绘制对应的矩形
    for (final TextBox box in renderEditable.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end))) {
      final Rect rect = box.toRect();
      if (rect.width <= 0.1) continue;
      // 左右略微外扩，抹平抗锯齿产生的缝隙
      canvas.drawRect(Rect.fromLTRB(rect.left - 0.2, rect.top, rect.right + 0.2, rect.bottom), paint);
    }
  }

  /// 更新绘制状态，状态变化时触发重绘
  void update({
    required List<TextSelection> matches,
    required int currentMatchIndex,
    required Color color,
  }) {
    // 内容未变化时不触发重绘，避免每帧无谓刷新
    if (listEquals(this.matches, matches) && this.currentMatchIndex == currentMatchIndex && this.color == color) {
      return;
    }
    this.matches = matches;
    this.currentMatchIndex = currentMatchIndex;
    this.color = color;
    notifyListeners();
  }
}
