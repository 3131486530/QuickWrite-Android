import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:quick_write/core/services/app_paths.dart';

/// 单个缓存条目
class _MetaSnapshotEntry {
  /// 内容标识（服务端 ETag，缺失时退化为大小-修改时间）
  final String contentId;

  /// 元数据文件的原始字节（gzip 压缩后的内容）
  final Uint8List bytes;

  const _MetaSnapshotEntry({required this.contentId, required this.bytes});

  Map<String, dynamic> toJson() => {
    'id': contentId,
    'data': base64Encode(bytes),
  };

  static _MetaSnapshotEntry? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final data = json['data'];
    if (id is! String || data is! String) return null;
    try {
      return _MetaSnapshotEntry(
        contentId: id,
        bytes: base64Decode(data),
      );
    } catch (_) {
      return null;
    }
  }
}

/// 远端元数据快照缓存
///
/// 坚果云按请求次数计费，元数据按书籍拆成多个文件后，每轮同步都要为
/// 每本书各发一次 GET 才能参与合并。绝大多数书籍在一轮同步里根本不会变化，
/// 这些 GET 完全可以用上一轮的结果替代：只要服务端 ETag 没变，文件内容必然没变。
///
/// 因此把上次读到的原始字节连同 ETag 一起缓存到本地，下一轮列举到相同
/// ETag 时直接复用，把「每本书一次请求」压缩成「没改动的书零请求」。
/// 缓存只是省流手段，校验失败或读取出错时一律回落到真实下载。
class MetaSnapshotCache {
  static const String _fileName = 'meta_snapshot_cache.json';

  /// 缓存文件的总容量上限
  ///
  /// 单本书的元数据经过 gzip 后通常只有几 KB，这里留出足够余量；
  /// 超过上限时按访问顺序淘汰最旧的条目，避免长期使用后无限膨胀
  static const int _maxTotalBytes = 4 * 1024 * 1024;

  /// 单个条目的容量上限，过大的文件直接不缓存
  static const int _maxEntryBytes = 256 * 1024;

  /// 相对路径 → 缓存条目
  final Map<String, _MetaSnapshotEntry> _entries = {};

  /// 访问顺序，用于上限淘汰
  final List<String> _order = [];

  bool _loaded = false;
  bool _dirty = false;
  String? _filePath;

  /// 命中次数，便于排查到底省了多少次请求
  int _hitCount = 0;
  int _missCount = 0;

  int get hitCount => _hitCount;
  int get missCount => _missCount;

  /// 读取缓存内容，未命中或内容标识不一致时返回 null
  Uint8List? read(String path, String contentId) {
    if (contentId.isEmpty) return null;
    final entry = _entries[path];
    if (entry == null || entry.contentId != contentId) {
      _missCount++;
      return null;
    }
    _hitCount++;
    _touch(path);
    return entry.bytes;
  }

  /// 写入缓存
  void write(String path, String contentId, Uint8List bytes) {
    if (contentId.isEmpty) return;
    if (bytes.length > _maxEntryBytes) return;
    _entries[path] = _MetaSnapshotEntry(contentId: contentId, bytes: bytes);
    _touch(path);
    _dirty = true;
    _evictIfNeeded();
  }

  /// 只保留仍然存在于远端的路径
  ///
  /// 远端已删除的书籍若不清理，缓存会随着删除操作只增不减
  void retainOnly(Set<String> validPaths) {
    final removed = _entries.keys.where((k) => !validPaths.contains(k)).toList();
    if (removed.isEmpty) return;
    for (final key in removed) {
      _entries.remove(key);
      _order.remove(key);
    }
    _dirty = true;
  }

  /// 清空全部缓存（远端元数据被整体清空时使用）
  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    _order.clear();
    _dirty = true;
  }

  /// 载入缓存文件
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = File(await _resolvePath());
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final entries = decoded['entries'];
      if (entries is! Map) return;
      entries.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final entry = _MetaSnapshotEntry.fromJson(
          Map<String, dynamic>.from(value),
        );
        if (entry == null) return;
        _entries[key] = entry;
        _order.add(key);
      });
    } catch (e) {
      // 缓存损坏只会让下一轮同步多花几次请求，直接丢弃重建
      debugPrint('元数据快照缓存读取失败，已丢弃: $e');
      _entries.clear();
      _order.clear();
    }
  }

  /// 落盘
  ///
  /// 无改动时不写文件，避免每轮同步都产生一次本地写盘
  Future<void> save() async {
    if (!_dirty) return;
    try {
      final file = File(await _resolvePath());
      await file.parent.create(recursive: true);
      final payload = <String, dynamic>{
        'version': 1,
        'entries': {
          for (final entry in _entries.entries) entry.key: entry.value.toJson(),
        },
      };
      await file.writeAsString(jsonEncode(payload));
      _dirty = false;
    } catch (e) {
      debugPrint('元数据快照缓存落盘失败: $e');
    }
  }

  /// 记录一次访问，把路径移到队尾
  void _touch(String path) {
    _order.remove(path);
    _order.add(path);
  }

  /// 超出容量上限时淘汰最久未访问的条目
  void _evictIfNeeded() {
    var total = _entries.values.fold<int>(0, (sum, e) => sum + e.bytes.length);
    while (total > _maxTotalBytes && _order.isNotEmpty) {
      final oldest = _order.removeAt(0);
      final removed = _entries.remove(oldest);
      if (removed != null) total -= removed.bytes.length;
    }
  }

  /// 缓存文件路径与 state.json 同目录，跟随同步目录配置
  Future<String> _resolvePath() async {
    final cached = _filePath;
    if (cached != null) return cached;
    if (!AppPaths.instance.isInitialized) {
      await AppPaths.instance.initialize();
    }
    final syncPath = await AppPaths.instance.getSyncPath();
    final path = '$syncPath${Platform.pathSeparator}$_fileName';
    _filePath = path;
    return path;
  }
}
