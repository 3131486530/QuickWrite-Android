import 'package:flutter/widgets.dart';

/// 弹层（弹窗、底部面板等）打开前后保持编辑器光标焦点的工具。
///
/// 弹层路由弹入时会接管焦点，导致章节编辑器、大纲编辑器的光标消失，
/// 关闭后也无法直接继续输入。这里统一在弹层打开前记录当前焦点节点，
/// 关闭后再把焦点还给原节点，键盘随之恢复。
class EditorFocusKeep {
  EditorFocusKeep._();

  /// 记录弹层打开前的焦点节点
  ///
  /// 需在打开弹层前调用，返回值为关闭弹层后用于恢复焦点的节点。
  static FocusNode? capture() {
    return FocusManager.instance.primaryFocus;
  }

  /// 弹层关闭后恢复焦点
  ///
  /// 节点已从组件树卸载时跳过，避免对已废弃节点请求焦点。
  static void restore(FocusNode? node) {
    if (node == null) return;
    if (node.context == null) return;
    node.requestFocus();
  }
}
