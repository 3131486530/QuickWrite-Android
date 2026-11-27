import 'package:flutter/widgets.dart';

/// 弹层（弹窗、底部面板等）打开前后保持编辑器光标焦点的工具。
///
/// 弹层路由弹入时会接管焦点，导致章节编辑器、大纲编辑器的光标消失，
/// 关闭后也无法直接继续输入。这里统一在弹层打开前记录当前焦点节点，
/// 关闭后再把焦点还给原节点，键盘随之恢复。
class EditorFocusKeep {
  EditorFocusKeep._();

  /// 最近一次持有焦点的编辑器正文输入节点
  static FocusNode? _lastEditorFocus;

  /// 最近一次持有焦点的标题类输入节点（章节标题、大纲标题）
  static FocusNode? _lastTitleFocus;

  /// 已登记监听的正文输入节点，避免同一节点重复挂载监听
  static final Set<FocusNode> _tracked = <FocusNode>{};

  /// 已登记的标题类输入节点及其文本控制器
  static final Map<FocusNode, TextEditingController> _titleInputs =
      <FocusNode, TextEditingController>{};

  /// 焦点记录序号：每次有输入节点获得焦点时递增，用于判断正文与标题的先后
  static int _focusSeq = 0;
  static int _editorSeq = 0;
  static int _titleSeq = 0;

  /// 打开中的弹层层数
  static int _overlayDepth = 0;

  /// 因弹层打开而被挂起取焦能力的输入节点
  static final Set<FocusNode> _suspended = <FocusNode>{};

  /// 登记编辑器正文输入节点
  ///
  /// 节点每次获得焦点时更新「最近聚焦」记录：点击顶部快捷键或左右抽屉时
  /// 编辑器会先失去焦点，此时仍需知道光标原本落在哪个输入框上。
  static void track(FocusNode node) {
    if (!_tracked.add(node)) return;
    node.addListener(() {
      if (node.hasFocus) {
        _lastEditorFocus = node;
        _editorSeq = ++_focusSeq;
      }
    });
  }

  /// 登记标题类输入节点
  ///
  /// 标题输入框（章节标题、大纲标题）与正文一样会被工具面板夺走焦点，
  /// 登记后既能把光标还给标题，也能判断随机取名等操作应插入标题还是正文。
  static void trackTitleInput(FocusNode node, TextEditingController controller) {
    if (_titleInputs.containsKey(node)) return;
    _titleInputs[node] = controller;
    node.addListener(() {
      if (node.hasFocus) {
        _lastTitleFocus = node;
        _titleSeq = ++_focusSeq;
      }
    });
  }

  /// 注销标题类输入节点
  ///
  /// 编辑器销毁时调用，避免已卸载的节点残留在登记表与「最近聚焦」记录里。
  static void untrackTitleInput(FocusNode node) {
    _titleInputs.remove(node);
    _suspended.remove(node);
    if (identical(_lastTitleFocus, node)) _lastTitleFocus = null;
  }

  /// 最近一次聚焦且仍挂在界面上的编辑器正文输入节点
  static FocusNode? get lastEditorFocus {
    final node = _lastEditorFocus;
    if (node == null || node.context == null) return null;
    return node;
  }

  /// 最近一次聚焦且仍挂在界面上的标题输入节点
  static FocusNode? get lastTitleFocus {
    final node = _lastTitleFocus;
    if (node == null || node.context == null) return null;
    return node;
  }

  /// 最近一次聚焦的标题输入框对应的文本控制器
  static TextEditingController? get lastTitleController {
    final node = lastTitleFocus;
    if (node == null) return null;
    return _titleInputs[node];
  }

  /// 最近一次聚焦的输入位置是否为标题输入框
  ///
  /// 正文与标题共用一个序号，谁最后获得焦点谁优先，避免把名字插错位置。
  static bool get titleIsMostRecent => lastTitleFocus != null && _titleSeq > _editorSeq;

  /// 是否有弹层正在打开
  ///
  /// 弹层打开期间应屏蔽编辑器的自动抢回焦点，否则输入法会被反复唤起，
  /// 表现为底部面板先弹出、再被输入法顶一下就回落。
  static bool get overlayOpen => _overlayDepth > 0;

  /// 标记弹层开始打开，需与 [endOverlay] 成对调用
  static void beginOverlay() {
    _overlayDepth++;
  }

  /// 标记弹层已关闭
  static void endOverlay() {
    if (_overlayDepth > 0) _overlayDepth--;
  }

  /// 把焦点还给最近一次聚焦的编辑器正文输入节点
  ///
  /// 从未聚焦过编辑器、节点已不在界面上或弹层仍在打开时不做任何处理，
  /// 返回是否已归还。
  static bool restoreLastEditorFocus() {
    if (overlayOpen) return false;
    final node = lastEditorFocus;
    if (node == null) return false;
    if (!node.hasFocus) node.requestFocus();
    return true;
  }

  /// 把焦点还给最近一次聚焦的标题输入节点
  ///
  /// 与 [restoreLastEditorFocus] 对应，用于随机取名等操作插入标题后归还光标。
  static bool restoreLastTitleFocus() {
    if (overlayOpen) return false;
    final node = lastTitleFocus;
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

  /// 让当前输入框主动失焦
  ///
  /// 打开底部面板期间调用：工具卡片弹层销毁时 Flutter 会把焦点还给原来的
  /// 输入框，标准 TextField 一获得焦点就重建输入法连接，键盘随即弹出把面板
  /// 顶起。这里把输入框按下去，键盘就不会被重新拉起；最近聚焦记录仍然保留，
  /// 面板关闭后照样能把光标还回原位、把名字插到正确位置。
  static void releaseInputFocus() {
    final FocusNode? title = lastTitleFocus;
    if (title != null && title.hasFocus) title.unfocus();
    final FocusNode? editor = lastEditorFocus;
    if (editor != null && editor.hasFocus) editor.unfocus();
  }

  /// 弹层打开期间挂起输入框的取焦能力
  ///
  /// 只把焦点挪走并不能阻止弹层路由销毁、编辑器帧末补焦点等逻辑再次请求焦点：
  /// 标准 TextField 一拿到焦点就重建输入法连接，键盘重新弹出把底部面板顶起。
  /// 这里直接把已登记输入节点的 [FocusNode.canRequestFocus] 置为 false，
  /// 期间任何 requestFocus 都不会生效，面板位置因此不会再抖动。
  static void suspendInputFocus() {
    final List<FocusNode?> nodes = <FocusNode?>[lastTitleFocus, lastEditorFocus];
    for (final FocusNode? node in nodes) {
      if (node == null) continue;
      if (node.hasFocus) node.unfocus();
      if (node.canRequestFocus) {
        node.canRequestFocus = false;
        _suspended.add(node);
      }
    }
  }

  /// 弹层关闭后恢复输入框的取焦能力
  ///
  /// 与 [suspendInputFocus] 成对调用，必须早于归还焦点的动作，否则请求会被吞掉。
  static void resumeInputFocus() {
    for (final FocusNode node in _suspended) {
      node.canRequestFocus = true;
    }
    _suspended.clear();
  }

  /// 弹层关闭后恢复焦点
  ///
  /// 节点已从组件树卸载、或弹层仍在打开时跳过，避免对已废弃节点请求焦点
  /// 以及抢在弹层关闭动画之前唤起输入法。
  static void restore(FocusNode? node) {
    if (overlayOpen) return;
    // 最近一次输入落在标题上时优先还回标题：[capture] 记录的节点可能已被
    // 弹层路由还给了正文，照它恢复会把光标落到正文，后续插入也会插错位置
    final FocusNode? title = lastTitleFocus;
    if (title != null && titleIsMostRecent) {
      if (!title.hasFocus) title.requestFocus();
      return;
    }
    if (node == null) return;
    if (node.context == null) return;
    node.requestFocus();
  }
}
