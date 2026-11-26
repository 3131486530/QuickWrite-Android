import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quick_write/core/services/settings_service.dart';
import 'package:quick_write/core/utils/color_utils.dart';
import 'package:quick_write/core/utils/find_match_highlighter.dart';
import 'package:quick_write/core/utils/persistent_selection.dart';
import 'package:quick_write/core/utils/platform_capabilities.dart';
import 'package:quick_write/shared/widgets/context_menu.dart';
import 'package:quick_write/shared/widgets/qw_text_field_painter.dart';

Widget _qwDefaultContextMenuBuilder(
  BuildContext context,
  EditableTextState state,
) {
  if (SystemContextMenu.isSupportedByField(state)) {
    return SystemContextMenu.editableText(editableTextState: state);
  }
  if (PlatformCapabilities.isDesktop) {
    return _QwTextContextMenu(state: state);
  }
  return AdaptiveTextSelectionToolbar.editableText(editableTextState: state);
}

/// 桌面端输入框右键菜单，复用应用统一的 ContextMenu 样式
class _QwTextContextMenu extends StatefulWidget {
  const _QwTextContextMenu({required this.state});

  final EditableTextState state;

  @override
  State<_QwTextContextMenu> createState() => _QwTextContextMenuState();
}

class _QwTextContextMenuState extends State<_QwTextContextMenu> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final EditableTextState state = widget.state;
      ContextMenu.showMenuAt(
        context: context,
        position: state.contextMenuAnchors.primaryAnchor,
        fontSize: 13,
        menuItems: [
          ContextMenuItem(
            labelText: '剪切',
            enabled: state.cutEnabled,
            onTap: () => state.cutSelection(SelectionChangedCause.toolbar),
          ),
          ContextMenuItem(
            labelText: '复制',
            enabled: state.copyEnabled,
            onTap: () => state.copySelection(SelectionChangedCause.toolbar),
          ),
          ContextMenuItem(
            labelText: '粘贴',
            enabled: state.pasteEnabled,
            onTap: () => state.pasteText(SelectionChangedCause.toolbar),
          ),
          ContextMenuItem.divider(),
          ContextMenuItem(
            labelText: '全选',
            enabled: state.selectAllEnabled,
            onTap: () => state.selectAll(SelectionChangedCause.toolbar),
          ),
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 带统一选区与字底色绘制的 TextField 封装
///
/// 内置选区色置透明，改由 [QwTextFieldPainter] 绘制，参数与 TextField 一一对应。
class QwTextField extends StatefulWidget {
  const QwTextField({
    super.key,
    this.groupId = EditableText,
    this.controller,
    this.focusNode,
    this.undoController,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.strutStyle,
    this.textAlign = TextAlign.start,
    this.textAlignVertical,
    this.textDirection,
    this.readOnly = false,
    this.showCursor,
    this.autofocus = false,
    this.statesController,
    this.obscuringCharacter = '•',
    this.obscureText = false,
    this.autocorrect,
    this.smartDashesType,
    this.smartQuotesType,
    this.enableSuggestions = true,
    this.maxLines = 1,
    this.minLines,
    this.expands = false,
    this.maxLength,
    this.maxLengthEnforcement,
    this.onChanged,
    this.onEditingComplete,
    this.onSubmitted,
    this.onAppPrivateCommand,
    this.inputFormatters,
    this.enabled,
    this.ignorePointers,
    this.cursorWidth = 2.0,
    this.cursorHeight,
    this.cursorRadius,
    this.cursorOpacityAnimates,
    this.cursorColor,
    this.cursorErrorColor,
    this.selectionColor,
    this.selectionHeightStyle,
    this.selectionWidthStyle,
    this.keyboardAppearance,
    this.scrollPadding = const EdgeInsets.all(20.0),
    this.dragStartBehavior = DragStartBehavior.start,
    this.enableInteractiveSelection,
    this.selectAllOnFocus,
    this.selectionControls,
    this.onTap,
    this.onTapAlwaysCalled = false,
    this.onTapOutside,
    this.onTapUpOutside,
    this.mouseCursor,
    this.buildCounter,
    this.scrollController,
    this.scrollPhysics,
    this.autofillHints = const <String>[],
    this.contentInsertionConfiguration,
    this.clipBehavior = Clip.hardEdge,
    this.restorationId,
    this.stylusHandwritingEnabled =
        EditableText.defaultStylusHandwritingEnabled,
    this.enableIMEPersonalizedLearning = true,
    this.contextMenuBuilder = _qwDefaultContextMenuBuilder,
    this.canRequestFocus = true,
    this.spellCheckConfiguration,
    this.magnifierConfiguration,
    this.hintLocales,
  });

  final Object groupId;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final UndoHistoryController? undoController;
  final InputDecoration decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign textAlign;
  final TextAlignVertical? textAlignVertical;
  final TextDirection? textDirection;
  final bool readOnly;
  final bool? showCursor;
  final bool autofocus;
  final WidgetStatesController? statesController;
  final String obscuringCharacter;
  final bool obscureText;
  final bool? autocorrect;
  final SmartDashesType? smartDashesType;
  final SmartQuotesType? smartQuotesType;
  final bool enableSuggestions;
  final int? maxLines;
  final int? minLines;
  final bool expands;
  final int? maxLength;
  final MaxLengthEnforcement? maxLengthEnforcement;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEditingComplete;
  final ValueChanged<String>? onSubmitted;
  final AppPrivateCommandCallback? onAppPrivateCommand;
  final List<TextInputFormatter>? inputFormatters;
  final bool? enabled;
  final bool? ignorePointers;
  final double cursorWidth;
  final double? cursorHeight;
  final Radius? cursorRadius;
  final bool? cursorOpacityAnimates;
  final Color? cursorColor;
  final Color? cursorErrorColor;
  final Color? selectionColor;
  final ui.BoxHeightStyle? selectionHeightStyle;
  final ui.BoxWidthStyle? selectionWidthStyle;
  final Brightness? keyboardAppearance;
  final EdgeInsets scrollPadding;
  final DragStartBehavior dragStartBehavior;
  final bool? enableInteractiveSelection;
  final bool? selectAllOnFocus;
  final TextSelectionControls? selectionControls;
  final GestureTapCallback? onTap;
  final bool onTapAlwaysCalled;
  final TapRegionCallback? onTapOutside;
  final TapRegionUpCallback? onTapUpOutside;
  final MouseCursor? mouseCursor;
  final InputCounterWidgetBuilder? buildCounter;
  final ScrollController? scrollController;
  final ScrollPhysics? scrollPhysics;
  final Iterable<String>? autofillHints;
  final ContentInsertionConfiguration? contentInsertionConfiguration;
  final Clip clipBehavior;
  final String? restorationId;
  final bool stylusHandwritingEnabled;
  final bool enableIMEPersonalizedLearning;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final bool canRequestFocus;
  final SpellCheckConfiguration? spellCheckConfiguration;
  final TextMagnifierConfiguration? magnifierConfiguration;
  final List<Locale>? hintLocales;

  @override
  State<QwTextField> createState() => _QwTextFieldState();
}

class _QwTextFieldState extends State<QwTextField>
    with SingleTickerProviderStateMixin {
  final GlobalKey _anchorKey = GlobalKey();
  final QwCaretPainter _caretPainter = QwCaretPainter();
  late final QwTextFieldPainter _painter;

  /// 呼吸式光标动画控制器：0 → 1 往返循环，映射为不透明度起伏
  late final AnimationController _breathController;

  /// 当前生效的光标模式
  QwCaretMode _caretMode = QwCaretMode.system;

  /// 呼吸动画一次完整起伏（亮 → 暗 → 亮）的时长
  ///
  /// 与正文编辑器（re_editor 的 _CodeCursorBlinkController）呼吸周期一致，
  /// 两端光标节奏相同才不会出现大纲忽快忽慢的观感。
  static const int _breathPeriodMs = 1500;

  /// 动画控制器单程时长
  ///
  /// [AnimationController.repeat] 开启 reverse 时 duration 只覆盖 0 → 1 的单程，
  /// 往返一次才是完整的 [_breathPeriodMs]；若把整周期当作单程时长，
  /// 一次起伏会变成 3000ms，大纲光标因此比正文慢一倍。
  static const Duration _breathHalfPeriod =
      Duration(milliseconds: _breathPeriodMs ~/ 2);

  /// 呼吸动画最暗时的不透明度
  static const double _breathMinOpacity = 0.15;

  Color _focusedColor(BuildContext context) =>
      widget.selectionColor ??
      computeFocusedSelectionColor(Theme.of(context).colorScheme);

  Color _unfocusedColor(BuildContext context) =>
      computePersistentSelectionColor(
        context,
        Theme.of(context).colorScheme.primary,
      );

  @override
  void initState() {
    super.initState();
    _breathController = AnimationController(
      vsync: this,
      duration: _breathHalfPeriod,
    )..addListener(_onBreathTick);
    SettingsService.instance.addListener(_onSettingsChanged);
    _painter = QwTextFieldPainter(
      controller: widget.controller,
      focusedColor: Colors.transparent,
      unfocusedColor: Colors.transparent,
      matchColor: Colors.transparent,
      currentMatchColor: Colors.transparent,
      showUnfocusedSelection: ContextMenu.showingListenable.value,
    );
    ContextMenu.showingListenable.addListener(_syncUnfocusedSelection);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPainterColors();
  }

  @override
  void didUpdateWidget(covariant QwTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPainterColors();
  }

  void _syncPainterColors() {
    _painter.update(
      controller: widget.controller,
      focusedColor: _focusedColor(context),
      unfocusedColor: _unfocusedColor(context),
      matchColor: FindMatchHighlighter.getMatchColor(context),
      currentMatchColor: FindMatchHighlighter.getCurrentMatchColor(context),
      showUnfocusedSelection: ContextMenu.showingListenable.value,
    );
  }

  /// 菜单开合时刷新失焦选区的绘制状态
  ///
  /// 失焦选区只在菜单显示期间可见，菜单关闭后立即消失。
  void _syncUnfocusedSelection() {
    _painter.update(
      showUnfocusedSelection: ContextMenu.showingListenable.value,
    );
  }

  /// 框外点击：先取消选区，再沿用默认失焦行为
  ///
  /// 右键保留选区，供上下文菜单复制/剪切；移动端触摸由平台管理焦点，不处理。
  void _handleTapOutside(PointerDownEvent event) {
    final bool ignoreTouch =
        event.kind == PointerDeviceKind.touch && PlatformCapabilities.isMobile;
    if (!ignoreTouch && (event.buttons & kSecondaryButton) == 0) {
      _collapseSelection();
    }
    final TapRegionCallback? onTapOutside = widget.onTapOutside;
    if (onTapOutside != null) {
      onTapOutside(event);
    } else if (!ignoreTouch) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  /// 将非折叠选区折叠为光标，取消选区高亮
  void _collapseSelection() {
    final TextEditingController? controller = widget.controller;
    if (controller == null) return;
    final TextSelection selection = controller.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    controller.selection = TextSelection.collapsed(
      offset: selection.baseOffset.clamp(0, controller.text.length),
    );
  }

  /// 解析当前应使用的光标模式
  ///
  /// 仅移动端支持静态与呼吸式光标；桌面端保持原生闪烁行为不变。
  QwCaretMode _resolveCaretMode() {
    if (!PlatformCapabilities.isMobile) return QwCaretMode.system;
    if (widget.showCursor == false) return QwCaretMode.system;
    final SettingsService settings = SettingsService.instance;
    if (settings.breathingCursorEnabled) return QwCaretMode.breathing;
    if (settings.staticCursorEnabled) return QwCaretMode.steady;
    return QwCaretMode.system;
  }

  /// 应用光标模式：呼吸式启动动画，其余模式停止动画
  void _applyCaretMode(QwCaretMode mode) {
    if (mode != _caretMode) {
      _caretMode = mode;
      if (mode == QwCaretMode.breathing) {
        if (!_breathController.isAnimating) {
          _breathController.repeat(reverse: true);
        }
      } else {
        _breathController
          ..stop()
          ..value = 0;
      }
      // 切换模式需要重建输入框，让内置光标颜色与自定义光标同步
      if (mounted) setState(() {});
    }
    _caretPainter.updateCaret(
      mode: mode,
      opacity: mode == QwCaretMode.breathing ? null : 1.0,
      caretColor: _caretColor(context),
    );
  }

  /// 自定义光标颜色，与内置光标默认取色保持一致
  ///
  /// 优先取组件入参，其次取设置中的自定义光标颜色，最后回退主题主色
  Color _caretColor(BuildContext context) =>
      widget.cursorColor ??
      ColorUtils.getCursorColorForTheme(context, Theme.of(context).colorScheme.primary);

  /// 设置中自定义的光标颜色（未自定义时返回 null，由主题决定）
  Color? _customCursorColor(BuildContext context) {
    final String? hex = ColorUtils.getCursorColorHexForTheme(context);
    if (hex == null || hex.isEmpty) return null;
    return ColorUtils.tryParseHex(hex);
  }

  void _onBreathTick() {
    // 余弦映射：value 0 → 最亮、1 → 最暗，往返即完整一个余弦周期，
    // 与正文编辑器 opacity = min + (1 - min) * (0.5 + 0.5 * cos(2πp)) 同曲线
    final double wave = 0.5 + 0.5 * math.cos(math.pi * _breathController.value);
    _caretPainter.updateCaret(
      opacity: _breathMinOpacity + (1 - _breathMinOpacity) * wave,
    );
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    _applyCaretMode(_resolveCaretMode());
  }

  @override
  void dispose() {
    ContextMenu.showingListenable.removeListener(_syncUnfocusedSelection);
    SettingsService.instance.removeListener(_onSettingsChanged);
    _breathController
      ..removeListener(_onBreathTick)
      ..dispose();
    _painter.dispose();
    _caretPainter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderEditable = findPersistentRenderEditable(_anchorKey);
      if (renderEditable == null) return;
      if (!identical(renderEditable.painter, _painter)) {
        renderEditable.painter = _painter;
      }
      _caretPainter.attach(renderEditable);
      if (!identical(renderEditable.foregroundPainter, _caretPainter)) {
        renderEditable.foregroundPainter = _caretPainter;
      }
      _applyCaretMode(_resolveCaretMode());
    });

    return KeyedSubtree(
      key: _anchorKey,
      child: DefaultSelectionStyle.merge(
        selectionColor: Colors.transparent,
        child: TextField(
          groupId: widget.groupId,
          controller: widget.controller,
          focusNode: widget.focusNode,
          undoController: widget.undoController,
          decoration: widget.decoration,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          textCapitalization: widget.textCapitalization,
          style: widget.style,
          strutStyle: widget.strutStyle,
          textAlign: widget.textAlign,
          textAlignVertical: widget.textAlignVertical,
          textDirection: widget.textDirection,
          readOnly: widget.readOnly,
          showCursor: widget.showCursor,
          autofocus: widget.autofocus,
          statesController: widget.statesController,
          obscuringCharacter: widget.obscuringCharacter,
          obscureText: widget.obscureText,
          autocorrect: widget.autocorrect,
          smartDashesType: widget.smartDashesType,
          smartQuotesType: widget.smartQuotesType,
          enableSuggestions: widget.enableSuggestions,
          maxLines: widget.maxLines,
          minLines: widget.minLines,
          expands: widget.expands,
          maxLength: widget.maxLength,
          maxLengthEnforcement: widget.maxLengthEnforcement,
          onChanged: widget.onChanged,
          onEditingComplete: widget.onEditingComplete,
          onSubmitted: widget.onSubmitted,
          onAppPrivateCommand: widget.onAppPrivateCommand,
          inputFormatters: widget.inputFormatters,
          enabled: widget.enabled,
          ignorePointers: widget.ignorePointers,
          cursorWidth: widget.cursorWidth,
          cursorHeight: widget.cursorHeight,
          cursorRadius: widget.cursorRadius,
          cursorOpacityAnimates: widget.cursorOpacityAnimates,
          cursorColor: _caretMode == QwCaretMode.system
              ? (widget.cursorColor ?? _customCursorColor(context))
              : Colors.transparent,
          cursorErrorColor: widget.cursorErrorColor,
          selectionHeightStyle: widget.selectionHeightStyle,
          selectionWidthStyle: widget.selectionWidthStyle,
          keyboardAppearance: widget.keyboardAppearance,
          scrollPadding: widget.scrollPadding,
          dragStartBehavior: widget.dragStartBehavior,
          enableInteractiveSelection: widget.enableInteractiveSelection,
          selectAllOnFocus: widget.selectAllOnFocus,
          selectionControls: widget.selectionControls,
          onTap: widget.onTap,
          onTapAlwaysCalled: widget.onTapAlwaysCalled,
          onTapOutside: _handleTapOutside,
          onTapUpOutside: widget.onTapUpOutside,
          mouseCursor: widget.mouseCursor,
          buildCounter: widget.buildCounter,
          scrollController: widget.scrollController,
          scrollPhysics: widget.scrollPhysics,
          autofillHints: widget.autofillHints,
          contentInsertionConfiguration: widget.contentInsertionConfiguration,
          clipBehavior: widget.clipBehavior,
          restorationId: widget.restorationId,
          stylusHandwritingEnabled: widget.stylusHandwritingEnabled,
          enableIMEPersonalizedLearning: widget.enableIMEPersonalizedLearning,
          contextMenuBuilder: widget.contextMenuBuilder,
          canRequestFocus: widget.canRequestFocus,
          spellCheckConfiguration: widget.spellCheckConfiguration,
          magnifierConfiguration: widget.magnifierConfiguration,
          hintLocales: widget.hintLocales,
        ),
      ),
    );
  }
}
