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
  /// [content] 为原始正文（段落以换行分隔），[pageHeight] 为可容纳正文的高度，
  /// 不含页脚等固定 UI；返回结果不包含章末过渡页，由调用方自行追加。
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

    final List<ReaderPageSlice> pages = <ReaderPageSlice>[];
    List<ReaderBlock> blocks = <ReaderBlock>[];
    bool pageHasTitle = showTitle && chapterTitle.trim().isNotEmpty;
    double used = 0;

    void flush() {
      pages.add(ReaderPageSlice(blocks: blocks, hasTitle: pageHasTitle));
      blocks = <ReaderBlock>[];
      pageHasTitle = false;
      used = 0;
    }

    if (pageHasTitle) {
      used = titleTopMargin +
          measureSpan(TextSpan(text: chapterTitle, style: titleStyle), maxWidth: maxWidth);
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

      // 常规段落：整体放入当前页，放不下则换页
      if (measured <= pageHeight) {
        final double height = measured + (showSeparator ? separatorHeight : 0);
        if (blocks.isNotEmpty && used + height > pageHeight) flush();
        blocks.add(ReaderBlock(paragraphIndex: i, start: 0, end: raw.length, height: height));
        used += height;
        continue;
      }

      // 超长段落：按实际排行切块，逐块填充页面
      final List<ReaderBlock> split = _splitByLine(
        text: text,
        paragraphIndex: i,
        startOffset: starts[i],
        ranges: ranges,
        bodyStyle: bodyStyle,
        maxWidth: maxWidth,
        pageHeight: pageHeight,
        showSeparator: showSeparator,
        separatorHeight: separatorHeight,
        firstLineIndent: firstLineIndent,
      );
      for (final ReaderBlock block in split) {
        if (blocks.isNotEmpty && used + block.height > pageHeight) flush();
        blocks.add(block);
        used += block.height;
      }
    }

    if (blocks.isNotEmpty || pages.isEmpty) flush();
    return pages;
  }

  /// 把单个超长段落按行切分为若干块
  static List<ReaderBlock> _splitByLine({
    required String text,
    required int paragraphIndex,
    required int startOffset,
    required List<HighlightRange> ranges,
    required TextStyle bodyStyle,
    required double maxWidth,
    required double pageHeight,
    required bool showSeparator,
    required double separatorHeight,
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
    // LineMetrics 不提供 startIndex，需自行换算每行在段落内的字符起点：
    // 取行垂直中心处的字符位置，再用 getLineBoundary 收缩为该视觉行范围，
    // 最后减掉首行缩进前缀长度，得到相对段落原文的偏移。
    final int prefixLength = firstLineIndent.length;
    final List<int> lineStarts = <int>[];
    double topEdge = 0;
    for (int i = 0; i < lines.length; i++) {
      final LineMetrics line = lines[i];
      if (i == 0) {
        lineStarts.add(0);
      } else {
        final double centerY = topEdge + line.height / 2;
        final TextPosition pos =
            painter.getPositionForOffset(Offset(0, centerY));
        final TextRange range = painter.getLineBoundary(pos);
        final int rawStart = range.start < 0 ? pos.offset : range.start;
        lineStarts.add((rawStart - prefixLength).clamp(0, text.length));
      }
      topEdge += line.height;
    }
    // 防御：行起点必须单调不减，异常时回退到上一行起点
    for (int i = 1; i < lineStarts.length; i++) {
      if (lineStarts[i] < lineStarts[i - 1]) {
        lineStarts[i] = lineStarts[i - 1];
      }
    }

    final List<ReaderBlock> blocks = <ReaderBlock>[];
    int blockStart = 0;
    double accumulated = 0;

    for (int i = 0; i < lines.length; i++) {
      final double lineHeight = lines[i].height;
      if (accumulated > 0 && accumulated + lineHeight > pageHeight) {
        final int blockEnd = lineStarts[i];
        if (blockEnd > blockStart) {
          blocks.add(ReaderBlock(
            paragraphIndex: paragraphIndex,
            start: blockStart,
            end: blockEnd,
            height: accumulated + (showSeparator ? separatorHeight : 0),
          ));
        }
        accumulated = 0;
      }
      if (accumulated == 0) blockStart = lineStarts[i];
      accumulated += lineHeight;
    }

    if (accumulated > 0) {
      blocks.add(ReaderBlock(
        paragraphIndex: paragraphIndex,
        start: blockStart,
        end: text.length,
        height: accumulated + (showSeparator ? separatorHeight : 0),
      ));
    }
    painter.dispose();
    return blocks;
  }
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
    this.isChapterEnd = false,
  });

  /// 页内文本块
  final List<ReaderBlock> blocks;

  /// 是否在本页顶部渲染章节标题
  final bool hasTitle;

  /// 是否为章末过渡页
  final bool isChapterEnd;

  /// 本页首个文本块所属段落序号（为空表示无正文）
  int get firstParagraphIndex => blocks.isEmpty ? -1 : blocks.first.paragraphIndex;
}
