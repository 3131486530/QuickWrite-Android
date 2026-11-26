import 'package:flutter/widgets.dart';

/// 弹层（弹窗、底部面板等）打开前后保持编辑器光标焦点的工具。
///
/// 弹层路由弹入时会接管焦点，导致章节编辑器、大纲编辑器的光标消失，
/// 关闭后也无法直接继续输入。这里统一在弹层打开前记录当前焦点节点，
/// 关闭后再把焦点还给原节点，键盘随之恢复。
class EditorFocusKeep {
  EditorFocusKeep._();

  /// 最近一次持有焦点的编辑器输入节点
  static FocusNode? _lastEditorFocus;

  /// 已登记监听的输入节点，避免同一节点重复挂载监听
  static final Set<FocusNode> _tracked = <FocusNode>{};

  /// 登记编辑器输入节点
  ///
  /// 节点每次获得焦点时更新「最近聚焦」记录：点击顶部快捷键或左右抽屉时
  /// 编辑器会先失去焦点，此时仍需知道光标原本落在哪个输入框上。
  static void track(FocusNode node) {
    if (!_tracked.add(node)) return;
    node.addListener(() {
      if (node.hasFocus) _lastEditorFocus = node;
    });
  }

  /// 最近一次聚焦且仍挂在界面上的编辑器输入节点
  static FocusNode? get lastEditorFocus {
    final node = _lastEditorFocus;
    if (node == null || node.context == null) return null;
    return node;
  }

  /// 把焦点还给最近一次聚焦的编辑器输入节点
  ///
  /// 从未聚焦过编辑器或节点已不在界面上时不做任何处理，返回是否已归还。
  static bool restoreLastEditorFocus() {
    final node = lastEditorFocus;
    if (node == null) return false;
    if (!node.hasFocus) node.requestFocus();
    return true;
  }

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
