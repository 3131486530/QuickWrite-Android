import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:quick_write/core/models/cache_models/custom_color_cache.dart';
import 'package:quick_write/core/services/cache_services/cache_service.dart';
import 'package:quick_write/core/utils/color_utils.dart';

/// 自定义颜色缓存服务
///
/// 统一保存各类场景的自定义颜色，使用独立的缓存文件（custom_colors.cache）。
/// 字体颜色、字底颜色等场景共用该文件，仅在数据内部按场景键区分。
class CustomColorCacheService extends CacheService<CustomColorCacheData> {
  // ================= 单例模式 =================

  static final CustomColorCacheService instance = CustomColorCacheService._internal();

  /// 私有构造函数
  CustomColorCacheService._internal() : super('custom_colors');

  // ================= 云同步支持 =================

  /// 云同步实体的稳定标识
  static const String syncEntityId = 'custom_colors_store';

  /// 同步时间戳在本地偏好设置中的键名
  static const String _syncStampKey = 'sync_stamp_custom_colors';

  /// 无同步记录时使用的兜底时间
  static const String _epochStamp = '1970-01-01T00:00:00.000Z';

  /// 自定义颜色内容的最后修改时间
  String? _syncStamp;

  /// 供云同步比较使用的修改时间
  String get syncStamp => _syncStamp ?? _epochStamp;

  /// 读取同步时间戳
  Future<void> _loadSyncStamp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _syncStamp = prefs.getString(_syncStampKey);
    } catch (e) {
      debugPrint('CustomColorCacheService 读取同步时间戳失败: $e');
    }
  }

  /// 写入同步时间戳
  Future<void> _writeSyncStamp(String stamp) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_syncStampKey, stamp);
    } catch (e) {
      debugPrint('CustomColorCacheService 写入同步时间戳失败: $e');
    }
  }

  /// 构建云同步实体
  ///
  /// 自定义颜色属于用户偏好，随设置一起在多台设备间共用。
  Map<String, dynamic> buildSyncEntity() {
    return <String, dynamic>{
      'uuid': syncEntityId,
      'updatedAt': syncStamp,
      'payload': _data.toJson(),
    };
  }

  /// 应用云端同步下来的自定义颜色
  Future<void> applySyncedData(Map<String, dynamic> entity) async {
    final Object? payload = entity['payload'];
    if (payload is! Map) return;
    final CustomColorCacheData remote = CustomColorCacheData.fromJson(
      Map<String, dynamic>.from(payload),
    );
    _data = remote;
    await super.save(remote);
    revision.value++;
    final Object? stamp = entity['updatedAt'];
    if (stamp is String && stamp.isNotEmpty) {
      _syncStamp = stamp;
      await _writeSyncStamp(stamp);
    }
    debugPrint('CustomColorCacheService 已应用云端自定义颜色');
  }

  /// 保存自定义颜色并刷新同步时间戳
  @override
  Future<bool> save(CustomColorCacheData data) async {
    _data = data;
    final String stamp = DateTime.now().toUtc().toIso8601String();
    final bool ok = await super.save(data);
    if (ok) {
      _syncStamp = stamp;
      await _writeSyncStamp(stamp);
    }
    return ok;
  }

  // ================= 场景键 =================

  /// 大纲字体颜色场景
  static const String sceneOutlineFont = 'outlineFont';

  /// 大纲字底颜色场景
  static const String sceneOutlineBackground = 'outlineBackground';

  /// 大纲关键词颜色场景
  static const String sceneOutlineKeyword = 'outlineKeyword';

  // ================= 变更通知 =================

  /// 自定义颜色增删后自增，供已打开的颜色选单同步
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  // ================= 状态属性 =================

  /// 当前缓存数据（内存中的副本）
  CustomColorCacheData _data = const CustomColorCacheData();

  /// 获取当前缓存数据（只读访问）
  CustomColorCacheData get data => _data;

  // ================= 初始化方法 =================

  @override
  Future<void> initialize() async {
    try {
      await super.initialize();
      await _loadSyncStamp();

      final loadedData = await load();

      if (loadedData != null) {
        _data = loadedData;
        debugPrint('CustomColorCacheService: 已从缓存文件加载数据');
      } else {
        debugPrint('CustomColorCacheService: 使用空数据（缓存文件不存在或为空）');
      }
    } catch (e, stackTrace) {
      debugPrint('CustomColorCacheService 初始化失败: $e');
      debugPrint('堆栈跟踪: $stackTrace');
      _data = const CustomColorCacheData();
    }
  }

  // ================= 反序列化实现 =================

  @override
  CustomColorCacheData fromJson(Map<String, dynamic> json) {
    return CustomColorCacheData.fromJson(json);
  }

  // ================= 自定义颜色管理 =================

  /// 获取指定场景的自定义颜色列表（按添加顺序）
  List<Color> getColors(String scene) {
    final List<Color> colors = <Color>[];
    for (final String hex in _data.colorsByScene[scene] ?? const <String>[]) {
      final Color? color = ColorUtils.tryParseHex(hex);
      if (color != null) colors.add(color);
    }
    return colors;
  }

  /// 向指定场景添加自定义颜色，已存在时直接返回
  Future<bool> addColor(String scene, Color color) async {
    final String hex = ColorUtils.toHex(color);
    final List<String> current = _data.colorsByScene[scene] ?? const <String>[];
    if (current.contains(hex)) return true;

    final updated = Map<String, List<String>>.from(_data.colorsByScene);
    updated[scene] = [...current, hex];
    _data = _data.copyWith(colorsByScene: updated);
    revision.value++;
    return save(_data);
  }

  /// 从指定场景移除自定义颜色
  Future<bool> removeColor(String scene, Color color) async {
    final String hex = ColorUtils.toHex(color);
    final List<String> current = _data.colorsByScene[scene] ?? const <String>[];
    if (!current.contains(hex)) return true;

    final updated = Map<String, List<String>>.from(_data.colorsByScene);
    final remaining = current.where((String item) => item != hex).toList(growable: false);
    if (remaining.isEmpty) {
      updated.remove(scene);
    } else {
      updated[scene] = remaining;
    }
    _data = _data.copyWith(colorsByScene: updated);
    revision.value++;
    return save(_data);
  }
}
