import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:quick_write/core/utils/rich_text_controller.dart';

/// QwTextField 的统一背景绘制器
///
/// 依次绘制字底色、普通查找匹配、选区、当前匹配；选区颜色按焦点自动切换，失焦选区仅在上下文菜单显示期间绘制。
/// 所有矩形合并进 Path 一次填充，避免半透明重叠与行间 1px 细缝。
/// 光标绘制模式
enum QwCaretMode {
  /// 跟随编辑框内置行为（默认闪烁）
  system,

  /// 常亮，不做闪烁
  steady,

  /// 呼吸式顺滑动画，不透明度在时间轴上平滑起伏
  breathing,
}

/// 在 foreground 层补画光标
///
/// 内置 caret 在部分平台排在自定义 painter 之前，会被字底色盖住；
/// 这里只在原本 caret 位于文字下方时补画，避免和内置 caret 重复。
class QwCaretPainter extends RenderEditablePainter {
  RenderEditable? _attached;
  VoidCallback? _showCursorListener;

  /// 自定义光标行为：默认跟随内置闪烁，可切换为常亮或呼吸式动画
  QwCaretMode mode = QwCaretMode.system;

  /// 光标不透明度，仅 [QwCaretMode.breathing] 与 [QwCaretMode.steady] 使用
  double opacity = 1.0;

  /// 自定义光标颜色，为空时取内置光标颜色
  Color? caretColor;

  void updateCaret({
    QwCaretMode? mode,
    double? opacity,
    Color? caretColor,
  }) {
    final QwCaretMode nextMode = mode ?? this.mode;
    final double nextOpacity = opacity ?? this.opacity;
    final Color? nextColor = caretColor ?? this.caretColor;
    if (nextMode == this.mode &&
        nextOpacity == this.opacity &&
        nextColor == this.caretColor) {
      return;
    }
    this.mode = nextMode;
    this.opacity = nextOpacity;
    this.caretColor = nextColor;
    notifyListeners();
  }

  /// 监听 showCursor 的闪烁切换，触发 foreground 层重绘
  void attach(RenderEditable renderEditable) {
    if (identical(_attached, renderEditable)) return;
    detach();
    _attached = renderEditable;
    _showCursorListener = () => notifyListeners();
    renderEditable.showCursor.addListener(_showCursorListener!);
  }

  void detach() {
    final RenderEditable? renderEditable = _attached;
    final VoidCallback? listener = _showCursorListener;
    if (renderEditable != null && listener != null) {
      renderEditable.showCursor.removeListener(listener);
    }
    _attached = null;
    _showCursorListener = null;
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }

  @override
  bool shouldRepaint(covariant QwCaretPainter oldDelegate) => true;

  @override
  void paint(Canvas canvas, Size size, RenderEditable renderEditable) {
    if (renderEditable.paintCursorAboveText && mode == QwCaretMode.system) {
      return;
    }
    final TextSelection? selection = renderEditable.selection;
    if (selection == null || !selection.isValid || !selection.isCollapsed) return;
    if (mode == QwCaretMode.system) {
      if (!renderEditable.showCursor.value) return;
    } else {
      // 常亮 / 呼吸式光标不跟随内置闪烁状态，改由焦点与自定义不透明度决定
      if (!renderEditable.hasFocus) return;
      if (opacity <= 0.01) return;
    }
    final Color? baseColor = caretColor ?? renderEditable.cursorColor;
    if (baseColor == null || baseColor.a == 0) return;
    final Color color = mode == QwCaretMode.system || opacity >= 0.999
        ? baseColor
        : baseColor.withValues(alpha: (baseColor.a * opacity).clamp(0.0, 1.0));

    final Rect rect = renderEditable
        .getLocalRectForCaret(selection.extent)
        .shift(renderEditable.cursorOffset);
    final Paint paint = Paint()..color = color;
    final Radius? radius = renderEditable.cursorRadius;
    if (radius == null) {
      canvas.drawRect(rect, paint);
    } else {
      canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
    }
  }
}

class QwTextFieldPainter extends RenderEditablePainter {
  QwTextFieldPainter({
    this.controller,
    required this.focusedColor,
    required this.unfocusedColor,
    required this.matchColor,
    required this.currentMatchColor,
    required this.showUnfocusedSelection,
  });

  TextEditingController? controller;
  Color focusedColor;
  Color unfocusedColor;
  Color matchColor;
  Color currentMatchColor;

  /// 是否绘制失焦选区
  bool showUnfocusedSelection;

  void update({
    TextEditingController? controller,
    Color? focusedColor,
    Color? unfocusedColor,
    Color? matchColor,
    Color? currentMatchColor,
    bool? showUnfocusedSelection,
  }) {
    this.controller = controller ?? this.controller;
    this.focusedColor = focusedColor ?? this.focusedColor;
    this.unfocusedColor = unfocusedColor ?? this.unfocusedColor;
    this.matchColor = matchColor ?? this.matchColor;
    this.currentMatchColor = currentMatchColor ?? this.currentMatchColor;
    this.showUnfocusedSelection =
        showUnfocusedSelection ?? this.showUnfocusedSelection;
    notifyListeners();
  }

  @override
  bool shouldRepaint(covariant QwTextFieldPainter oldDelegate) => true;

  @override
  void paint(Canvas canvas, Size size, RenderEditable renderEditable) {
    final int textLength = renderEditable.plainText.length;
    final RichTextEditingController? rich =
        controller is RichTextEditingController
        ? controller as RichTextEditingController
        : null;

    if (rich != null) {
      for (final range in rich.styleRanges) {
        final Color? bg = range.flags.backgroundColor;
        if (bg == null) continue;
        _drawRange(
          canvas,
          renderEditable,
          range.start,
          range.end,
          bg,
          textLength,
          0.2,
          0.0,
        );
      }
      for (var i = 0; i < rich.findMatches.length; i++) {
        if (i == rich.currentMatchIndex) continue;
        final match = rich.findMatches[i];
        _drawRange(
          canvas,
          renderEditable,
          match.start,
          match.end,
          matchColor,
          textLength,
          0.2,
          0.0,
        );
      }
      if (rich.currentMatchIndex >= 0 &&
          rich.currentMatchIndex < rich.findMatches.length) {
        final match = rich.findMatches[rich.currentMatchIndex];
        _drawRange(
          canvas,
          renderEditable,
          match.start,
          match.end,
          currentMatchColor,
          textLength,
          0.2,
          1.0,
        );
      }
    }

    final TextSelection? selection = renderEditable.selection;
    if (selection != null && selection.isValid && !selection.isCollapsed) {
      final bool active =
          renderEditable.hasFocus || _isCurrentFindMatch(selection, rich);
      if (active || showUnfocusedSelection) {
        final Path path = Path();
        _addRangeToPath(
          path,
          renderEditable,
          selection.start,
          selection.end,
          textLength,
          0.2,
          1.0,
        );
        if (renderEditable.selectionWidthStyle == ui.BoxWidthStyle.tight) {
          _addNewlineBlocks(path, renderEditable, selection, textLength);
        }
        canvas.drawPath(
          path,
          Paint()..color = active ? focusedColor : unfocusedColor,
        );
      }
    }

  }

  bool _isCurrentFindMatch(
    TextSelection selection,
    RichTextEditingController? rich,
  ) {
    if (rich == null ||
        rich.currentMatchIndex < 0 ||
        rich.currentMatchIndex >= rich.findMatches.length) {
      return false;
    }
    final TextSelection match = rich.findMatches[rich.currentMatchIndex];
    return selection.start == match.start && selection.end == match.end;
  }

  void _drawRange(
    Canvas canvas,
    RenderEditable renderEditable,
    int start,
    int end,
    Color color,
    int textLength,
    double expandX,
    double expandY,
  ) {
    if (start >= end) return;
    final Path path = Path();
    _addRangeToPath(
      path,
      renderEditable,
      start,
      end,
      textLength,
      expandX,
      expandY,
    );
    canvas.drawPath(path, Paint()..color = color);
  }

  void _addRangeToPath(
    Path path,
    RenderEditable renderEditable,
    int start,
    int end,
    int textLength,
    double expandX,
    double expandY,
  ) {
    final int from = start.clamp(0, textLength);
    final int to = end.clamp(0, textLength);
    if (from >= to) return;
    for (final TextBox box in renderEditable.getBoxesForSelection(
      TextSelection(baseOffset: from, extentOffset: to),
    )) {
      final Rect rect = box.toRect();
      if (rect.width <= 0.1) continue;
      path.addRect(
        Rect.fromLTRB(
          rect.left - expandX,
          rect.top - expandY,
          rect.right + expandX,
          rect.bottom + expandY,
        ),
      );
    }
  }

  void _addNewlineBlocks(
    Path path,
    RenderEditable renderEditable,
    TextSelection selection,
    int textLength,
  ) {
    final String plainText = renderEditable.plainText;
    final int end = selection.end.clamp(0, textLength);
    int index = selection.start.clamp(0, textLength);
    while (index < end) {
      final int newline = plainText.indexOf('\n', index);
      if (newline == -1 || newline >= end) break;
      final List<TextBox> boxes = renderEditable.getBoxesForSelection(
        TextSelection(baseOffset: newline, extentOffset: newline + 1),
      );
      if (boxes.isNotEmpty) {
        final Rect rect = boxes.first.toRect();
        path.addRect(
          Rect.fromLTWH(
            rect.left,
            rect.top - 1.0,
            8.0,
            (rect.height > 0 ? rect.height : 14.0) + 2.0,
          ),
        );
      }
      index = newline + 1;
    }
  }
}
