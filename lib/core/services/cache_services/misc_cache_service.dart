import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:quick_write/core/models/cache_models/misc_cache.dart';
import 'package:quick_write/core/services/cache_services/cache_service.dart';

/// 杂项缓存服务
///
/// 统一管理各类零散的缓存数据，避免创建过多小文件
/// 使用独立的缓存文件（misc.cache）
///
/// 缓存内容包括：
/// - 书架上当前选中的分组 ID
/// - 每本书的未分卷组、未分组设定组折叠状态
/// - 新建章节、设定时分卷或分组选择记忆
/// - 章节、设定列表是否倒序排列
/// - 工具面板功能区与区块显示顺序
/// - 移动端正文关键词预览开关状态
/// - 正文敏感词标红开关状态
class MiscCacheService extends CacheService<MiscCacheData> {
  // ================= 单例模式 =================

  static final MiscCacheService instance = MiscCacheService._internal();

  /// 私有构造函数
  MiscCacheService._internal() : super('misc');

  // ================= 云同步常量 =================

  /// 同步实体的稳定标识
  static const String syncEntityId = 'miscPreferences';

  /// SharedPreferences 中记录同步时间戳的键
  static const String _syncStampKey = 'sync_stamp_misc';

  /// 最早时间戳
  static const String _epochStamp = '1970-01-01T00:00:00.000Z';

  /// 最近一次修改时间（UTC，ISO8601）
  String? _syncStamp;

  // ================= 状态属性 =================

  /// 当前缓存数据（内存中的副本）
  MiscCacheData _data = const MiscCacheData();

  /// 获取当前缓存数据（只读访问）
  MiscCacheData get data => _data;

  // ================= 初始化方法 =================

  @override
  Future<void> initialize() async {
    try {
      await super.initialize();

      final loadedData = await load();

      if (loadedData != null) {
        _data = loadedData;
        debugPrint('MiscCacheService: 已从缓存文件加载数据');
      } else {
        debugPrint('MiscCacheService: 使用空数据（缓存文件不存在或为空）');
      }

      // 读取同步时间戳，用于与其它设备比较新旧
      try {
        final prefs = await SharedPreferences.getInstance();
        _syncStamp = prefs.getString(_syncStampKey);
      } catch (e) {
        debugPrint('MiscCacheService 读取同步时间戳失败: $e');
      }
    } catch (e, stackTrace) {
      debugPrint('MiscCacheService 初始化失败: $e');
      debugPrint('堆栈跟踪: $stackTrace');
      _data = const MiscCacheData();
    }
  }

  // ================= 反序列化实现 =================

  @override
  MiscCacheData fromJson(Map<String, dynamic> json) {
    return MiscCacheData.fromJson(json);
  }

  // ================= 书架分组选择状态 =================

  /// 获取书架选中的分组 ID
  String getSelectedGroupId() {
    return _data.selectedGroupId;
  }

  /// 保存书架选中的分组 ID
  Future<bool> saveSelectedGroupId(String groupId) async {
    _data = _data.copyWith(selectedGroupId: groupId);
    return await save(_data);
  }

  // ================= 未分卷组折叠状态 =================

  /// 获取指定书籍的未分卷组是否折叠
  bool isUnassignedCollapsed(String bookUuid) {
    return _data.books[bookUuid]?.isUnassignedCollapsed ?? false;
  }

  /// 保存指定书籍的未分卷组折叠状态
  Future<bool> saveUnassignedCollapsed(String bookUuid, bool collapsed) async {
    final bookCache = _data.books[bookUuid] ?? const BookGroupExpandCache();
    final newBooks = Map<String, BookGroupExpandCache>.from(_data.books);
    newBooks[bookUuid] = bookCache.copyWith(isUnassignedCollapsed: collapsed);
    _data = _data.copyWith(books: newBooks);
    return await save(_data);
  }

  // ================= 未分组设定组折叠状态 =================

  /// 获取指定书籍的未分组设定组是否折叠
  bool isSettingUnassignedCollapsed(String bookUuid) {
    return _data.books[bookUuid]?.isSettingUnassignedCollapsed ?? false;
  }

  /// 保存指定书籍的未分组设定组折叠状态
  Future<bool> saveSettingUnassignedCollapsed(String bookUuid, bool collapsed) async {
    final bookCache = _data.books[bookUuid] ?? const BookGroupExpandCache();
    final newBooks = Map<String, BookGroupExpandCache>.from(_data.books);
    newBooks[bookUuid] = bookCache.copyWith(isSettingUnassignedCollapsed: collapsed);
    _data = _data.copyWith(books: newBooks);
    return await save(_data);
  }

  // ================= 新建章节分卷选择记忆 =================

  /// 获取指定书籍上次新建章节时选择的分卷 UUID
  String getLastSelectedVolume(String bookUuid) {
    return _data.books[bookUuid]?.lastSelectedVolume ?? '';
  }

  /// 保存指定书籍新建章节时选择的分卷 UUID
  Future<bool> saveLastSelectedVolume(String bookUuid, String volumeUuid) async {
    final bookCache = _data.books[bookUuid] ?? const BookGroupExpandCache();
    final newBooks = Map<String, BookGroupExpandCache>.from(_data.books);
    newBooks[bookUuid] = bookCache.copyWith(lastSelectedVolume: volumeUuid);
    _data = _data.copyWith(books: newBooks);
    return await save(_data);
  }

  // ================= 新建设定分组选择记忆 =================

  /// 获取指定书籍上次新建设定时选择的分组 UUID
  String getLastSelectedSettingGroup(String bookUuid) {
    return _data.books[bookUuid]?.lastSelectedSettingGroup ?? '';
  }

  /// 保存指定书籍新建设定时选择的分组 UUID
  Future<bool> saveLastSelectedSettingGroup(String bookUuid, String groupUuid) async {
    final bookCache = _data.books[bookUuid] ?? const BookGroupExpandCache();
    final newBooks = Map<String, BookGroupExpandCache>.from(_data.books);
    newBooks[bookUuid] = bookCache.copyWith(lastSelectedSettingGroup: groupUuid);
    _data = _data.copyWith(books: newBooks);
    return await save(_data);
  }

  // ================= 章节排序状态 =================

  /// 获取章节列表是否倒序排列
  bool isChapterReversed() {
    return _data.isChapterReversed;
  }

  /// 保存章节列表排序方式
  Future<bool> saveChapterReversed(bool reversed) async {
    _data = _data.copyWith(isChapterReversed: reversed);
    return await save(_data);
  }

  // ================= 设定排序状态 =================

  /// 获取设定列表是否倒序排列
  bool isSettingReversed() {
    return _data.isSettingReversed;
  }

  /// 保存设定列表排序方式
  Future<bool> saveSettingReversed(bool reversed) async {
    _data = _data.copyWith(isSettingReversed: reversed);
    return await save(_data);
  }

  // ================= 工具面板显示设置 =================

  /// 获取工具面板功能区显示顺序（仅包含可见工具）
  ///
  /// 列表按显示顺序存储开启显示的工具 ID，默认为 ['nameGen', 'sensitiveWord']
  List<String> getToolsFunctionOrder() {
    return _data.toolsFunctionOrder.toList();
  }

  /// 保存工具面板功能区显示顺序
  Future<bool> saveToolsFunctionOrder(List<String> order) async {
    _data = _data.copyWith(toolsFunctionOrder: order);
    return await save(_data);
  }

  /// 获取工具面板区块显示顺序（仅包含可见区块）
  ///
  /// 列表按显示顺序存储开启显示的区块 ID，默认为 ['bookInfo', 'stats']
  List<String> getToolsSectionOrder() {
    return _data.toolsSectionOrder.toList();
  }

  /// 保存工具面板区块显示顺序
  Future<bool> saveToolsSectionOrder(List<String> order) async {
    _data = _data.copyWith(toolsSectionOrder: order);
    return await save(_data);
  }

  // ================= 移动端正文关键词开关 =================

  /// 获取移动端正文关键词预览开关是否开启
  bool isKeywordHighlightEnabled() {
    return _data.keywordHighlightEnabled;
  }

  /// 保存移动端正文关键词预览开关状态
  Future<bool> saveKeywordHighlightEnabled(bool enabled) async {
    _data = _data.copyWith(keywordHighlightEnabled: enabled);
    return await save(_data);
  }

  // ================= 正文敏感词标红开关 =================

  /// 获取正文敏感词标红开关是否开启
  bool isSensitiveWordHighlightEnabled() {
    return _data.sensitiveWordHighlightEnabled;
  }

  /// 保存正文敏感词标红开关状态
  Future<bool> saveSensitiveWordHighlightEnabled(bool enabled) async {
    _data = _data.copyWith(sensitiveWordHighlightEnabled: enabled);
    return await save(_data);
  }

  // ================= 正文敏感词标红颜色 =================

  /// 获取正文敏感词标红颜色（空字符串表示跟随主题错误色）
  String getSensitiveWordColorHex() {
    return _data.sensitiveWordColorHex;
  }

  /// 保存正文敏感词标红颜色
  Future<bool> saveSensitiveWordColorHex(String colorHex) async {
    _data = _data.copyWith(sensitiveWordColorHex: colorHex);
    return await save(_data);
  }

  // ================= 自定义高亮选择记忆 =================

  /// 获取自定义高亮上次选择的颜色
  String getCustomHighlightLastColorHex() {
    final value = _data.customHighlightLastColorHex;
    return value.isEmpty ? '#FFB300' : value;
  }

  /// 保存自定义高亮上次选择的颜色
  Future<bool> saveCustomHighlightLastColorHex(String colorHex) async {
    _data = _data.copyWith(customHighlightLastColorHex: colorHex);
    return await save(_data);
  }

  // ================= 通用开关记忆 =================

  /// 读取某个开关最近一次的选择
  ///
  /// 从未记忆过时返回 [fallback]，保证旧版本升级上来仍是原有默认表现。
  bool getSwitchState(String key, {required bool fallback}) {
    return _data.switchStates[key] ?? fallback;
  }

  /// 记忆某个开关的选择
  ///
  /// 与已有取值相同时直接返回，避免无谓的落盘与云同步。
  Future<bool> saveSwitchState(String key, bool value) async {
    if (_data.switchStates[key] == value) return true;
    final states = Map<String, bool>.from(_data.switchStates)..[key] = value;
    _data = _data.copyWith(switchStates: states);
    return await save(_data);
  }

  // ================= 云同步支持 =================

  /// 保存数据时同步刷新修改时间，使其它设备能判定这是较新的操作记忆
  @override
  Future<bool> save(MiscCacheData data) async {
    final saved = await super.save(data);
    if (saved) {
      await _writeSyncStamp(DateTime.now().toUtc().toIso8601String());
    }
    return saved;
  }

  /// 写入同步时间戳
  Future<void> _writeSyncStamp(String stamp) async {
    _syncStamp = stamp;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_syncStampKey, stamp);
    } catch (e) {
      debugPrint('MiscCacheService 写入同步时间戳失败: $e');
    }
  }

  /// 构建参与云同步的缓存实体
  ///
  /// 缓存内容都是点击出来的操作记忆：书架分组选择、列表排序、
  /// 工具面板顺序、折叠状态与正文标红开关，换设备后无需重新操作
  Map<String, dynamic> buildSyncEntity() {
    return {
      'uuid': syncEntityId,
      'updatedAt': _syncStamp ?? _epochStamp,
      'payload': _data.toJson(),
    };
  }

  /// 应用云端同步下来的缓存
  Future<void> applySyncedData(Map<String, dynamic> entity) async {
    final payload = entity['payload'];
    if (payload is! Map) return;

    final MiscCacheData remote;
    try {
      remote = MiscCacheData.fromJson(Map<String, dynamic>.from(payload));
    } catch (e) {
      debugPrint('MiscCacheService 解析云端缓存失败: $e');
      return;
    }

    final stamp = entity['updatedAt'] as String? ?? _epochStamp;
    _data = remote;
    // 直接调用基类保存，避免把远端时间戳又覆盖为当前时间
    await super.save(remote);
    await _writeSyncStamp(stamp);

    debugPrint('MiscCacheService 已应用云端缓存');
  }

  // ================= 通用方法 =================

  /// 移除指定书籍的所有缓存
  Future<bool> removeBook(String bookUuid) async {
    final newBooks = Map<String, BookGroupExpandCache>.from(_data.books);
    newBooks.remove(bookUuid);
    _data = _data.copyWith(books: newBooks);
    return await save(_data);
  }

  /// 清空所有缓存
  Future<bool> clearAll() async {
    _data = const MiscCacheData();
    return await save(_data);
  }
}
