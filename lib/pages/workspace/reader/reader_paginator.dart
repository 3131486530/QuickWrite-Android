import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:quick_write/core/utils/highlight_range_resolver.dart';

/// 阅读模式正文分页器
///
/// 样式与章节编辑器保持同源：字体、字号、行高、字间距、字重、斜体、下划线、
/// 字体颜色、对话高亮与自定义关键词高亮全部沿用同一份排版设置，
/// 章节标题沿用布局设置中的标题字体、字号、颜色与对齐方式。
///
/// 分页按 [TextPainter] 实测高度切分（而非按字数估算），
/// 页末不会出现半行文字被裁掉；超长段落按行进一步切块，避免整段被挤出页面。
class ReaderPaginator {
  ReaderPaginator._();

  /// 空段落的占位文本（渲染时也用它，保证空行占据一行高度）
  static const String blankLine = ' ';

  /// 测量单段文本在给定宽度下的排版高度
  static double measureSpan(InlineSpan span, {required double maxWidth}) {
    final TextPainter painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      // 正文排版固定不随系统字体缩放，与编辑器的 textScaler: noScaling 一致
      textScaler: TextScaler.noScaling,
      maxLines: null,
    )..layout(maxWidth: maxWidth);
    final double height = painter.height;
    painter.dispose();
    return height;
  }

  /// 按高亮范围切分段落文本，生成带样式的行内片段
  ///
  /// [startOffset] 为该段落在整章正文中的起始偏移，[ranges] 为整章解析后的高亮范围；
  /// 只取与当前段落相交的范围，边界处切分，未覆盖部分沿用基础样式。
  static List<InlineSpan> buildSpans({
    required String text,
    required int startOffset,
    required List<HighlightRange> ranges,
    required TextStyle baseStyle,
    String indentPrefix = '',
  }) {
    final List<InlineSpan> spans = <InlineSpan>[];
    // 段首缩进：由编辑器排版绘制、不写入正文的两个全角空格，这里以同样方式加在段首
    if (indentPrefix.isNotEmpty) spans.add(TextSpan(text: indentPrefix));

    if (ranges.isEmpty || text.isEmpty) {
      spans.add(TextSpan(text: text));
      return spans;
    }

    final int endOffset = startOffset + text.length;
    int cursor = startOffset;

    for (final HighlightRange range in ranges) {
      if (range.end <= startOffset) continue;
      if (range.start >= endOffset) break;

      final int start = math.max(range.start, startOffset);
      final int end = math.min(range.end, endOffset);
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor - startOffset, start - startOffset)));
      }
      if (end > start) {
        spans.add(TextSpan(
          text: text.substring(start - startOffset, end - startOffset),
          style: _rangeStyle(range),
        ));
      }
      cursor = end;
    }

    if (cursor < endOffset) {
      spans.add(TextSpan(text: text.substring(cursor - startOffset)));
    }
    return spans;
  }

  /// 高亮范围对应的叠加样式
  ///
  /// [HighlightRange.background] 为 true 时作为文字底色，否则覆盖文字颜色；
  /// 字重与装饰线（敏感词标红使用删除线）按范围配置叠加到基础样式上。
  static TextStyle _rangeStyle(HighlightRange range) {
    return TextStyle(
      color: range.background ? null : range.color,
      backgroundColor: range.background ? range.color : null,
      fontWeight: range.fontWeight,
      decoration: range.decoration,
      decorationColor: range.decorationColor,
    );
  }

  /// 把整章正文切分为若干页
  ///
  /// [content] 为原始正文（段落以换行分隔），[pageHeight] 为可容纳正文的高度；
  /// 每页顶部都会渲染章节标题，故每页可用高度都已扣掉标题高度。
  static List<ReaderPageSlice> paginate({
    required String chapterTitle,
    required String content,
    required List<HighlightRange> ranges,
    required TextStyle bodyStyle,
    required TextStyle titleStyle,
    required double titleTopMargin,
    required bool showTitle,
    required double maxWidth,
    required double pageHeight,
    required bool showSeparator,
    required double separatorHeight,
    String firstLineIndent = '',
    required void Function(List<int> starts) onParagraphsResolved,
  }) {
    final List<String> paragraphs = content.split('\n');
    final List<int> starts = List<int>.filled(paragraphs.length, 0);
    int offset = 0;
    for (int i = 0; i < paragraphs.length; i++) {
      starts[i] = offset;
      offset += paragraphs[i].length + 1;
    }
    onParagraphsResolved(starts);

    // 章节标题在每一页都显示，因此它的高度要在每一页扣掉
    final bool titleShown = showTitle && chapterTitle.trim().isNotEmpty;
    final double titleHeight = titleShown
        ? titleTopMargin +
            measureSpan(TextSpan(text: chapterTitle, style: titleStyle), maxWidth: maxWidth)
        : 0;

    final List<ReaderPageSlice> pages = <ReaderPageSlice>[];
    List<ReaderBlock> blocks = <ReaderBlock>[];
    double used = titleHeight;

    void flush() {
      pages.add(ReaderPageSlice(blocks: blocks, hasTitle: titleShown));
      blocks = <ReaderBlock>[];
      used = titleHeight;
    }

    for (int i = 0; i < paragraphs.length; i++) {
      final String raw = paragraphs[i];
      final String text = raw.isEmpty ? blankLine : raw;
      final InlineSpan span = TextSpan(
        style: bodyStyle,
        children: buildSpans(
          text: text,
          startOffset: starts[i],
          ranges: ranges,
          baseStyle: bodyStyle,
          indentPrefix: raw.isEmpty ? '' : firstLineIndent,
        ),
      );
      final double measured = measureSpan(span, maxWidth: maxWidth);
      final double separator = showSeparator ? separatorHeight : 0;

      // 整段能放进当前页剩余空间时直接整段放置，避免无谓的行级切分
      if (measured + separator <= pageHeight - used + 0.01) {
        blocks.add(ReaderBlock(
          paragraphIndex: i,
          start: 0,
          end: raw.length,
          height: measured + separator,
        ));
        used += measured + separator;
        continue;
      }

      // 剩余空间放不下整段：按行切块，把当前页剩余空间填满后再翻页
      final _LineLayout layout = _layoutLines(
        text: text,
        startOffset: starts[i],
        ranges: ranges,
        bodyStyle: bodyStyle,
        maxWidth: maxWidth,
        firstLineIndent: raw.isEmpty ? '' : firstLineIndent,
      );

      // 实测某个字符区间的排版高度
      //
      // 按行累加得到的高度只是「整段一次性排版」时的行高之和，切块后单独渲染会
      // 重新换行，行数与高度可能不同；这里对切块文本做一次实测，保证分页高度与
      // 实际渲染高度一致，避免页面底部内容超出可视区而陷入屏幕外。
      double measureChunk(int from, int to) => measureSpan(
            TextSpan(
              style: bodyStyle,
              children: buildSpans(
                text: text.substring(from, to),
                startOffset: starts[i] + from,
                ranges: ranges,
                baseStyle: bodyStyle,
                indentPrefix: from == 0 && raw.isNotEmpty ? firstLineIndent : '',
              ),
            ),
            maxWidth: maxWidth,
          );

      int lineIndex = 0;
      while (lineIndex < layout.heights.length) {
        final double remaining = pageHeight - used;
        int lineEnd = lineIndex;
        double chunkHeight = 0;
        while (lineEnd < layout.heights.length &&
            chunkHeight + layout.heights[lineEnd] <= remaining + 0.01) {
          chunkHeight += layout.heights[lineEnd];
          lineEnd++;
        }
        if (lineEnd == lineIndex) {
          // 一行都放不下：本页已有内容则换页重来，否则强制放一行防止死循环
          if (blocks.isNotEmpty) {
            flush();
            continue;
          }
          chunkHeight = layout.heights[lineIndex];
          lineEnd = lineIndex + 1;
        } else {
          // 按实测高度校正切块：超出剩余空间时逐行回退
          int end = lineEnd;
          double measured = chunkHeight;
          while (end > lineIndex + 1) {
            final int chunkEnd =
                end >= layout.heights.length ? raw.length : layout.starts[end];
            final double height =
                measureChunk(layout.starts[lineIndex], chunkEnd);
            if (height <= remaining + 0.01) {
              measured = height;
              break;
            }
            end--;
          }
          lineEnd = end;
          chunkHeight = measured;
        }
        final bool reachesEnd = lineEnd >= layout.heights.length;
        final double blockHeight = chunkHeight + (reachesEnd ? separator : 0);
        blocks.add(ReaderBlock(
          paragraphIndex: i,
          start: layout.starts[lineIndex],
          end: reachesEnd ? raw.length : layout.starts[lineEnd],
          height: blockHeight,
        ));
        used += blockHeight;
        lineIndex = lineEnd;
        if (lineIndex < layout.heights.length) flush();
      }
    }

    if (blocks.isNotEmpty || pages.isEmpty) flush();
    return pages;
  }

  /// 实测段落每一行的排版高度与行首字符偏移
  ///
  /// [LineMetrics] 不含字符偏移，行首偏移由行垂直中心处的字符位置经
  /// [TextPainter.getLineBoundary] 收缩到视觉行范围后，再扣掉首行缩进前缀长度得到。
  static _LineLayout _layoutLines({
    required String text,
    required int startOffset,
    required List<HighlightRange> ranges,
    required TextStyle bodyStyle,
    required double maxWidth,
    required String firstLineIndent,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        style: bodyStyle,
        children: buildSpans(
          text: text,
          startOffset: startOffset,
          ranges: ranges,
          baseStyle: bodyStyle,
          indentPrefix: firstLineIndent,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: null,
    )..layout(maxWidth: maxWidth);

    final List<LineMetrics> lines = painter.computeLineMetrics();
    final int prefixLength = firstLineIndent.length;
    final List<double> heights = <double>[];
    final List<int> starts = <int>[];
    double topEdge = 0;
    for (int i = 0; i < lines.length; i++) {
      final LineMetrics line = lines[i];
      heights.add(line.height);
      if (i == 0) {
        starts.add(0);
      } else {
        final double centerY = topEdge + line.height / 2;
        final TextPosition pos = painter.getPositionForOffset(Offset(0, centerY));
        final TextRange range = painter.getLineBoundary(pos);
        final int rawStart = range.start < 0 ? pos.offset : range.start;
        starts.add((rawStart - prefixLength).clamp(0, text.length));
      }
      topEdge += line.height;
    }
    // 行首偏移必须单调不减，异常时回退到上一行
    for (int i = 1; i < starts.length; i++) {
      if (starts[i] < starts[i - 1]) starts[i] = starts[i - 1];
    }
    painter.dispose();
    return _LineLayout(heights: heights, starts: starts, textLength: text.length);
  }
}

/// 段落按行拆解后的行高与行首偏移
class _LineLayout {
  const _LineLayout({
    required this.heights,
    required this.starts,
    required this.textLength,
  });

  final List<double> heights;
  final List<int> starts;
  final int textLength;
}

/// 页内文本块
///
/// [start] / [end] 为块在所属段落内的字符区间（UTF-16），
/// 普通段落整段一个块，超长段落按行拆成多个块。
@immutable
class ReaderBlock {
  const ReaderBlock({
    required this.paragraphIndex,
    required this.start,
    required this.end,
    required this.height,
  });

  /// 所属段落在正文中的序号
  final int paragraphIndex;

  /// 块在段落内的起始偏移
  final int start;

  /// 块在段落内的结束偏移（不含）
  final int end;

  /// 块的排版高度（含行分隔线）
  final double height;
}

/// 一页的内容切片
@immutable
class ReaderPageSlice {
  const ReaderPageSlice({
    required this.blocks,
    required this.hasTitle,
  });

  /// 页内文本块
  final List<ReaderBlock> blocks;

  /// 是否在本页顶部渲染章节标题
  final bool hasTitle;

  /// 本页首个文本块所属段落序号（为空表示无正文）
  int get firstParagraphIndex => blocks.isEmpty ? -1 : blocks.first.paragraphIndex;
}
