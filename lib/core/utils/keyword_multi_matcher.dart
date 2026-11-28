/// 多关键词单遍匹配器
///
/// 正文高亮此前对每个关键词各做一次全文 `indexOf` 扫描，词条数量一多
/// （自定义高亮词库 + 敏感词库常达上百条），每输入一个字都要把全文扫描上百遍，
/// 长章节下会明显拖慢输入响应。
///
/// 这里把关键词建成前缀树（Trie），一次遍历正文即可找出全部命中：
/// 复杂度由 O(文本长度 × 词条数) 降为 O(文本长度 × 最长词长度)，
/// 且命中规则与原逐词扫描保持一致：
/// - 同一个关键词的命中区间互不重叠（等价于 `indexOf` 后从 `index + length` 继续）；
/// - 同一位置可同时命中多个不同关键词（如「长词」与「长」），交由上层按优先级合并。
class KeywordMultiMatcher {
  KeywordMultiMatcher(Iterable<String> keywords) {
    for (final String keyword in keywords) {
      if (keyword.isEmpty) continue;
      int node = 0;
      for (int i = 0; i < keyword.length; i++) {
        final int code = keyword.codeUnitAt(i);
        int? next = _next[node][code];
        if (next == null) {
          next = _next.length;
          _next.add(<int, int>{});
          _outputs.add(<int>[]);
          _next[node][code] = next;
        }
        node = next;
      }
      _outputs[node].add(_keywords.length);
      _keywords.add(keyword);
    }
  }

  /// 前缀树各节点的子节点表（code unit → 节点下标）
  final List<Map<int, int>> _next = <Map<int, int>>[<int, int>{}];

  /// 各节点对应的关键词下标（仅词尾节点非空）
  final List<List<int>> _outputs = <List<int>>[<int>[]];

  /// 去重后的非空关键词列表，下标与 [KeywordHit.pattern] 对应
  final List<String> _keywords = <String>[];

  /// 关键词数量
  int get length => _keywords.length;

  bool get isEmpty => _keywords.isEmpty;

  /// 关键词原文（按构造顺序）
  List<String> get keywords => List<String>.unmodifiable(_keywords);

  /// 在 [text] 中查找全部关键词命中，结果按起始位置升序
  ///
  /// [text] 需与关键词大小写口径一致（调用方自行决定是否先统一小写）。
  List<KeywordHit> findMatches(String text) {
    final int textLength = text.length;
    if (_keywords.isEmpty || textLength == 0) return const <KeywordHit>[];
    final List<KeywordHit> hits = <KeywordHit>[];
    // 记录每个关键词上一次命中的结束位置，保证同一关键词不重叠
    final List<int> lastEnd = List<int>.filled(_keywords.length, 0);
    for (int start = 0; start < textLength; start++) {
      int node = 0;
      for (int i = start; i < textLength; i++) {
        final int? next = _next[node][text.codeUnitAt(i)];
        if (next == null) break;
        node = next;
        final List<int> outs = _outputs[node];
        if (outs.isEmpty) continue;
        final int end = i + 1;
        for (final int pattern in outs) {
          if (lastEnd[pattern] > start) continue;
          lastEnd[pattern] = end;
          hits.add(KeywordHit(start, end, pattern));
        }
      }
    }
    return hits;
  }
}

/// 一次关键词命中
class KeywordHit {
  const KeywordHit(this.start, this.end, this.pattern);

  /// 命中起点（含）
  final int start;

  /// 命中终点（不含）
  final int end;

  /// 命中的关键词在 [KeywordMultiMatcher.keywords] 中的下标
  final int pattern;

  int get length => end - start;
}
