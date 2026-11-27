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

  /// 今日是否已有章节数据
  bool get isEmpty => _items.isEmpty;

  /// 今日章节字数合计
  int get totalWords =>
      _items.values.fold(0, (sum, item) => sum + item.words);

  /// 今日章节字数列表（按字数从多到少）
  List<ChapterWordCountItem> get items {
    final list = _items.values.where((item) => item.words != 0).toList();
    list.sort((a, b) => b.words.compareTo(a.words));
    return list;
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
    notifyListeners();
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
    await ensureLoaded();
    if (_dateKey != _todayKey()) {
      // 跨天：清空后重新开始
      await ensureLoaded();
    }
    final existing = _items[chapterId];
    final next = (existing?.words ?? 0) + delta;
    if (next <= 0) {
      _items.remove(chapterId);
    } else {
      _items[chapterId] = ChapterWordCountItem(
        chapterId: chapterId,
        title: title,
        words: next,
      );
    }
    notifyListeners();
    _schedulePersist();
  }

  /// 同步章节标题（章节改名后更新清单显示）
  void updateTitle(String chapterId, String title) {
    final item = _items[chapterId];
    if (item == null || item.title == title) return;
    item.title = title;
    notifyListeners();
    _schedulePersist();
  }

  /// 清空今日记录
  Future<void> clear() async {
    _items.clear();
    notifyListeners();
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
    _persistTimer?.cancel();
    super.dispose();
  }
}
