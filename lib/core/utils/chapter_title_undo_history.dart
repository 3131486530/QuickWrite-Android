/// 章节标题的一次编辑记录
class ChapterTitleEdit {
  ChapterTitleEdit({
    required this.textBefore,
    required this.textAfter,
    required this.timestamp,
  });

  /// 编辑前的标题文本
  final String textBefore;

  /// 编辑后的标题文本（连续输入会不断更新为最新文本）
  String textAfter;

  /// 最近一次并入本条记录的时间，用于合并连续输入
  DateTime timestamp;
}

/// 章节标题的撤销/重做历史
///
/// 章节标题输入框使用外部传入的 [TextEditingController]，不进入正文
/// 编辑器的撤销栈，因此单独维护一份历史；正文与标题的撤销顺序由编辑器
/// 按各自最后一次编辑时间决定。
class ChapterTitleUndoHistory {
  ChapterTitleUndoHistory({this.maxLevels = 200});

  /// 最多保留的记录条数
  final int maxLevels;

  final List<ChapterTitleEdit> _undoStack = <ChapterTitleEdit>[];
  final List<ChapterTitleEdit> _redoStack = <ChapterTitleEdit>[];

  /// 最近一次记录编辑的时间（null 表示没有标题编辑记录）
  DateTime? get lastEditAt => _undoStack.isEmpty ? null : _undoStack.last.timestamp;

  bool get canUndo => _undoStack.isNotEmpty;

  bool get canRedo => _redoStack.isNotEmpty;

  /// 记录一次标题编辑
  ///
  /// [mergeWindow] 内的连续输入合并为同一条记录，撤销时一次退回整段输入。
  void record({
    required String before,
    required String after,
    Duration mergeWindow = const Duration(seconds: 1),
  }) {
    if (before == after) return;
    final DateTime now = DateTime.now();
    final ChapterTitleEdit? last = _undoStack.isEmpty ? null : _undoStack.last;
    if (last != null &&
        last.textAfter == before &&
        now.difference(last.timestamp) < mergeWindow) {
      last.textAfter = after;
      last.timestamp = now;
    } else {
      _undoStack.add(ChapterTitleEdit(textBefore: before, textAfter: after, timestamp: now));
      if (_undoStack.length > maxLevels) _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  /// 取出上一条记录用于撤销，返回 null 表示无可撤销内容
  ///
  /// 调用方负责把标题文本回退到 [ChapterTitleEdit.textBefore]。
  ChapterTitleEdit? undo() {
    if (_undoStack.isEmpty) return null;
    final ChapterTitleEdit edit = _undoStack.removeLast();
    _redoStack.add(edit);
    return edit;
  }

  /// 取出上一条被撤销的记录用于重做，返回 null 表示无可重做内容
  ///
  /// 调用方负责把标题文本前进到 [ChapterTitleEdit.textAfter]。
  ChapterTitleEdit? redo() {
    if (_redoStack.isEmpty) return null;
    final ChapterTitleEdit edit = _redoStack.removeLast();
    _undoStack.add(edit);
    return edit;
  }

  /// 清空历史（切换章节等场景）
  void clear() {
    _undoStack.clear();
    _redoStack.clear();
  }
}
