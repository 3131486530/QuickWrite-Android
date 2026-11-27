import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单个章节的今日字数记录
class ChapterWordCountItem {
  ChapterWordCountItem({
    required this.chapterId,
    required this.title,
    required this.words,
  });

  /// 章节唯一标识（与编辑器标签页 id 一致）
  final String chapterId;

  /// 章节标题（记录时的快照）
  String title;

  /// 今日该章节净增字数
  int words;

  Map<String, dynamic> toJson() => {
        'chapterId': chapterId,
        'title': title,
        'words': words,
      };

  static ChapterWordCountItem? fromJson(Map<String, dynamic> json) {
    final id = json['chapterId'];
    if (id is! String || id.isEmpty) return null;
    return ChapterWordCountItem(
      chapterId: id,
      title: (json['title'] as String?) ?? '',
      words: (json['words'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 今日章节字数服务
///
/// 只保存"当天"各章节的净增字数：数据里带日期标记，日期变化时整体清空，
/// 因此天然满足"只记录今日所有章节字数"的语义，不产生历史累计。
/// 数据量很小，使用 SharedPreferences 以 JSON 形式持久化。
class ChapterWordCountService extends ChangeNotifier {
  ChapterWordCountService._();

  static final ChapterWordCountService instance = ChapterWordCountService._();

  static const String _prefKey = 'chapter_word_count_today';

  /// 当前数据所属日期（yyyy-MM-dd）
  String _dateKey = '';

  final Map<String, ChapterWordCountItem> _items = {};

  bool _loaded = false;

  Timer? _persistTimer;

  /// 通知合并定时器：把高频变更合并成一次 UI 通知
  Timer? _notifyTimer;

  /// 是否已释放（释放后不得再 notifyListeners）
  bool _disposed = false;

  /// 排序后清单缓存（数据变更时置空，避免每次 build 都复制并排序）
  List<ChapterWordCountItem>? _sortedCache;

  /// 合计字数缓存（数据变更时置空，避免每次 build 都全表累加）
  int? _totalCache;

  /// 今日是否已有章节数据
  bool get isEmpty => _items.isEmpty;

  /// 今日章节字数合计
  ///
  /// 结果带缓存：统计页与侧边栏会在每次 UI 刷新时读取该值，
  /// 全表累加只应发生在数据真正变化之后。
  int get totalWords => _totalCache ??= _items.values.fold<int>(0, (sum, item) => sum + item.words);

  /// 今日章节字数列表（按字数从多到少）
  ///
  /// 返回的列表由服务内部缓存持有，调用方只读，不要就地修改。
  List<ChapterWordCountItem> get items {
    final cached = _sortedCache;
    if (cached != null) return cached;
    final list = _items.values.where((item) => item.words != 0).toList()
      ..sort((a, b) => b.words.compareTo(a.words));
    return _sortedCache = list;
  }

  /// 数据变更后失效派生缓存
  void _invalidateCache() {
    _sortedCache = null;
    _totalCache = null;
  }

  /// 合并通知：编辑时每个按键都会累加字数，逐次 notifyListeners 会让
  /// 统计页卡片（位于 IndexedStack，即使不可见也会重建）随按键重建；
  /// 这里合并到 120ms 一次，肉眼不可感知且大幅减少重建次数。
  void _scheduleNotify() {
    if (_disposed || (_notifyTimer?.isActive ?? false)) return;
    _notifyTimer = Timer(const Duration(milliseconds: 120), () {
      _notifyTimer = null;
      if (_disposed) return;
      notifyListeners();
    });
  }

  /// 立即通知（用于载入、清空等低频且需要即时生效的场景）
  void _notifyNow() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    if (_disposed) return;
    notifyListeners();
  }

  static String _todayKey() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }

  /// 载入今日数据（跨天时自动清空旧数据）
  Future<void> ensureLoaded({bool forceNotify = false}) async {
    final today = _todayKey();
    if (_loaded && _dateKey == today) {
      if (forceNotify) notifyListeners();
      return;
    }
    _loaded = true;
    _dateKey = today;
    _items.clear();

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic> && decoded['date'] == today) {
          final list = decoded['items'];
          if (list is List) {
            for (final entry in list) {
              if (entry is Map<String, dynamic>) {
                final item = ChapterWordCountItem.fromJson(entry);
                if (item != null && item.words != 0) {
                  _items[item.chapterId] = item;
                }
              }
            }
          }
        } else {
          // 非今日数据：直接丢弃，只保留当天记录
          await prefs.remove(_prefKey);
        }
      }
    } catch (e) {
      debugPrint('读取今日章节字数失败: $e');
    }
    _invalidateCache();
    _notifyNow();
  }

  /// 累加某章节今日字数
  ///
  /// [delta] 为本次净增字数（可为负，表示删除今日新写的内容）。
  Future<void> addWords({
    required String chapterId,
    required String title,
    required int delta,
  }) async {
    if (chapterId.isEmpty || delta == 0) return;
    // 快路径：已载入且日期未变时直接同步累加，避免每次按键都走 await/异步队列。
    // 旧实现无条件 await ensureLoaded()，等于把每键一次的字数累加推到微任务里，
    // 输入高峰（连续快速输入）时会产生大量无意义的异步调度。
    if (!_loaded || _dateKey != _todayKey()) {
      await ensureLoaded();
      if (_disposed) return;
    }
    final existing = _items[chapterId];
    final next = (existing?.words ?? 0) + delta;
    if (next <= 0) {
      if (existing == null) return;
      _items.remove(chapterId);
    } else if (existing != null) {
      // 就地更新，避免每次按键都新建对象（List/Map 中的引用保持不变）
      existing.words = next;
      if (existing.title != title) existing.title = title;
    } else {
      _items[chapterId] = ChapterWordCountItem(
        chapterId: chapterId,
        title: title,
        words: next,
      );
    }
    _invalidateCache();
    _scheduleNotify();
    _schedulePersist();
  }

  /// 同步章节标题（章节改名后更新清单显示）
  void updateTitle(String chapterId, String title) {
    final item = _items[chapterId];
    if (item == null || item.title == title) return;
    item.title = title;
    _scheduleNotify();
    _schedulePersist();
  }

  /// 清空今日记录
  ///
  /// 重置码字统计数据时一并调用：今日章节字数是独立持久化的一份记录，
  /// 不随 [WritingStatsService.clearAllStats] 一起清空，必须显式重置。
  Future<void> clear() async {
    // 取消挂起的写盘，避免清空后定时器又把数据写回
    _persistTimer?.cancel();
    _persistTimer = null;
    _items.clear();
    _invalidateCache();
    // 视为已载入今日数据：清空后若马上继续码字，无需再从磁盘读取旧值
    _loaded = true;
    _dateKey = _todayKey();
    _notifyNow();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
    } catch (e) {
      debugPrint('清空今日章节字数失败: $e');
    }
  }

  /// 合并写盘，避免编辑过程高频 IO
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 800), () {
      _persist();
    });
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_items.isEmpty) {
        await prefs.remove(_prefKey);
        return;
      }
      await prefs.setString(
        _prefKey,
        jsonEncode({
          'date': _dateKey,
          'items': _items.values.map((item) => item.toJson()).toList(),
        }),
      );
    } catch (e) {
      debugPrint('保存今日章节字数失败: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _persistTimer?.cancel();
    _persistTimer = null;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    super.dispose();
  }
}
