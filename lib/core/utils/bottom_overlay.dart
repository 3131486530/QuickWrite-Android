import 'dart:async';
import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quick_write/core/utils/editor_focus_keep.dart';

/// 底部操作面板统一开合流程
///
/// 所有从屏幕底部滑出的操作面板都必须走这里，否则会出现两类问题：
/// 1. 面板弹出时键盘还没收起，面板被输入法顶起再落下；
/// 2. 面板关闭后路由把焦点还给编辑器输入框，标准 TextField 一拿到焦点
///    就重建输入法连接，键盘再次被拉起，把面板顶一下。
///
/// 流程固定为：挂起输入框取焦能力 → 收起输入法 → 等键盘占位真正归零 →
/// 弹出面板 → 关闭后等退场动画结束 → 恢复取焦能力 → 按打开前的节点归还焦点。
Future<T?> showFocusSafeBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool useSafeArea = true,
  bool isDismissible = true,
  bool enableDrag = true,
  bool showDragHandle = false,
  Color? backgroundColor,
  ShapeBorder? shape,
  Color? barrierColor,
}) {
  return runWithOverlayFocusGuard<T>(
    context: context,
    present: (BuildContext overlayContext) => showModalBottomSheet<T>(
      context: overlayContext,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      showDragHandle: showDragHandle,
      backgroundColor: backgroundColor,
      shape: shape,
      barrierColor: barrierColor,
      builder: builder,
    ),
  );
}

/// 在焦点保护下打开任意弹层
///
/// [present] 收到的是 Navigator 的上下文：叫起方可能在等待键盘收起的
/// 过程中被销毁（如底部快捷输入栏随键盘收起而移除），用 Navigator 的上下文
/// 弹出可避免面板弹不出来。
Future<T?> runWithOverlayFocusGuard<T>({
  required BuildContext context,
  required Future<T?> Function(BuildContext overlayContext) present,
}) async {
  // 键盘占位必须读视图的原始 insets：Scaffold 开启 resizeToAvoidBottomInset 后
  // 会把底部输入法占位从子树 MediaQuery 中剥离，body 内的上下文永远读到 0
  final FlutterView? view = View.maybeOf(context);
  final BuildContext overlayContext = Navigator.of(context).context;
  final FocusNode? previousFocus = EditorFocusKeep.capture();

  EditorFocusKeep.beginOverlay();
  try {
    // 挂起标准输入框的取焦能力并收起键盘：否则路由销毁时的自动还焦点
    // 会让输入框重建输入法连接，把面板顶起
    EditorFocusKeep.suspendInputFocus();
    await _hideImeAndWaitInsets(view);
    if (!overlayContext.mounted) return null;
    return await present(overlayContext);
  } finally {
    // 面板退场动画未结束时路由仍持有焦点作用域，此时请求的焦点会被吞掉
    await Future<void>.delayed(const Duration(milliseconds: 260));
    // 先恢复取焦能力再归还焦点，顺序反了请求会被丢弃
    EditorFocusKeep.resumeInputFocus();
    EditorFocusKeep.endOverlay();
    EditorFocusKeep.restoreAfterOverlay(previousFocus);
  }
}

/// 收起输入法并等待键盘占位归零
///
/// 键盘收起是渐变动画，占位没归零就弹面板仍会被顶起。
Future<void> _hideImeAndWaitInsets(FlutterView? view) async {
  unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  if (view == null) {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return;
  }
  double keyboardInset() => view.viewInsets.bottom / view.devicePixelRatio;
  for (int i = 0; i < 12 && keyboardInset() > 0; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}
