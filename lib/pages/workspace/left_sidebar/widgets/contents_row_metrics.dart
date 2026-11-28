import 'package:flutter/material.dart';

/// 目录行高度估算工具
///
/// 目录列表（章节 / 设定）使用 SliverSortableList 懒布局，行高必须提前给出；
/// 章节名、设定名允许换行后，需要按标题实际占用的行数把行高撑开，
/// 否则 SizedBox 会把多行标题裁掉。

/// 估算标题在给定宽度下的行数
///
/// [maxWidth] 为标题可用的实际宽度，小于等于 0 时（首帧尚未测量）按单行处理。
int measureTitleLineCount({
  required String text,
  required TextStyle? style,
  required double maxWidth,
  required TextScaler textScaler,
}) {
  if (text.isEmpty || maxWidth <= 0) return 1;
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: null,
    textScaler: textScaler,
  )..layout(maxWidth: maxWidth);
  final int lines = painter.computeLineMetrics().length;
  painter.dispose();
  return lines <= 0 ? 1 : lines;
}

/// 按标题行数计算目录行高度
///
/// [singleLineExtent] 为单行标题时的行高，[lineExtent] 为每多一行增加的高度；
/// [maxVisibleLines] 限制最多撑开的行数，避免极端长标题把列表撑坏。
double contentsRowExtent({
  required String title,
  required TextStyle? style,
  required double maxWidth,
  required TextScaler textScaler,
  required double singleLineExtent,
  required double lineExtent,
  int maxVisibleLines = 4,
}) {
  final int lines = measureTitleLineCount(
    text: title,
    style: style,
    maxWidth: maxWidth,
    textScaler: textScaler,
  ).clamp(1, maxVisibleLines);
  return singleLineExtent + (lines - 1) * lineExtent;
}
