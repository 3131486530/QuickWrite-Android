import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:quick_write/core/models/custom_highlight.dart';
import 'package:quick_write/core/services/cloud_sync/cloud_sync_service.dart';
import 'package:quick_write/core/utils/custom_highlight_regex.dart';

/// 自定义高亮配置文件名（保存在书籍根目录下）
const String kCustomHighlightFileName = 'custom_highlights.json';

/// 自定义高亮增删改的结果
enum CustomHighlightMutationResult {
  /// 已写入配置文件并通知编辑器刷新
  ok,

  /// 按原有规则静默忽略（空内容、重名、索引越界、目标不存在）
  skipped,

  /// 正则表达式语法非法，配置保持原值不变
  invalidRegex,
}

/// 自定义高亮服务
///
/// 负责单本书自定义高亮配置的加载、保存与运行时增删改查。
/// 配置以 JSON 文件形式持久化到书籍根目录（与 chapters、settings 同级），
/// 通过 [ChangeNotifier] 通知编辑器在配置变化时重建高亮渲染。
///
/// 配置结构为「分组」：每组一种颜色、一本独立词库。
/// [items] 暴露的是全部词条展开后的结果，渲染层沿用旧的扁平遍历即可。
///
/// 生命周期由 [WorkspaceProvider] 管理：每本书的工作台持有一个独立实例。
class CustomHighlightService extends ChangeNotifier {
  /// 当前配置（初始为空配置，加载完成后更新）
  CustomHighlightConfig _config = CustomHighlightConfig.empty;

  /// 配置文件完整路径（load 成功后才有值）
  String? _configFilePath;

  /// 展开后的词条缓存与分组缓存
  ///
  /// [_config.items] 每次调用都会重新展开全部分组并分配列表，而编辑器正文
  /// 每输入一个字都要按词条重建高亮，这里缓存展开结果，配置变更时失效。
  List<CustomHighlightItem>? _itemsCache;
  List<CustomHighlightGroup>? _groupsCache;

  /// 配置修订号
  ///
  /// 任何一次 [notifyListeners]（启用开关、增删改分组、替换词库）都会自增，
  /// 渲染层据此判断高亮配置是否需要重新解析，无需每次遍历全部词条。
  int _revision = 0;

  int get revision => _revision;

  /// 获取当前配置（只读）
  CustomHighlightConfig get config => _config;

  /// 是否启用自定义高亮
  bool get enabled => _config.enabled;

  /// 分组列表（只读）
  List<CustomHighlightGroup> get groups => _groupsCache ??= List.unmodifiable(_config.groups);

  /// 全部词条（展开所有分组，颜色取所属分组色，只读）
  ///
  /// 渲染层（编辑器、阅读模式）仍按扁平列表遍历，分组改造无需改动渲染路径。
  List<CustomHighlightItem> get items => _itemsCache ??= List.unmodifiable(_config.items);

  /// 全部词条数量（用于面板展示）
  int get wordCount => _itemsCache?.length ?? _config.items.length;

  /// 配置变更通知
  ///
  /// 统一在此处递增修订号并清空展开缓存，避免新增写入口时漏掉失效逻辑。
  @override
  void notifyListeners() {
    _revision++;
    _itemsCache = null;
    _groupsCache = null;
    super.notifyListeners();
  }

  /// 从指定书籍根目录加载配置
  ///
  /// 文件不存在时使用空配置并标记为已加载，避免阻塞编辑器渲染。
  /// 旧版单层 items 配置会自动迁移为按颜色归并的分组。
  Future<void> load(String bookFolderPath) async {
    _configFilePath = '$bookFolderPath${Platform.pathSeparator}$kCustomHighlightFileName';

    try {
      final file = File(_configFilePath!);
      if (await file.exists()) {
        final content = await file.readAsString();
        final jsonMap = json.decode(content) as Map<String, dynamic>;
        _config = CustomHighlightConfig.fromJson(jsonMap);
      } else {
        // 文件不存在时使用空配置，不主动创建文件，待用户首次保存时再写入
        _config = CustomHighlightConfig.empty;
      }
    } catch (e) {
      debugPrint('加载自定义高亮配置失败: $e，使用空配置');
      _config = CustomHighlightConfig.empty;
    }

    // 配置整体替换后同步失效缓存与修订号，避免复用加载前的展开结果
    _itemsCache = null;
    _groupsCache = null;
    _revision++;
  }

  /// 保存当前配置到文件
  Future<bool> _save() async {
    if (_configFilePath == null) {
      debugPrint('自定义高亮配置文件路径为空，无法保存');
      return false;
    }

    try {
      final file = File(_configFilePath!);
      // 确保父目录存在（书籍根目录通常已存在，此处兜底）
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      final jsonContent = const JsonEncoder.withIndent('  ').convert(_config.toJson());
      await file.writeAsString(jsonContent);
      // 高亮配置已落盘，交由云同步服务安排一次同步
      CloudSyncService.instance.notifyLocalChange();
      return true;
    } catch (e) {
      debugPrint('保存自定义高亮配置失败: $e');
      return false;
    }
  }

  /// 更新启用状态
  Future<void> setEnabled(bool value) async {
    if (_config.enabled == value) return;
    _config = _config.copyWith(enabled: value);
    await _save();
    notifyListeners();
  }

  /// 按 id 查找分组，不存在时返回 null
  CustomHighlightGroup? groupById(String id) {
    for (final group in _config.groups) {
      if (group.id == id) return group;
    }
    return null;
  }

  /// 新增分组，返回新分组的 id
  ///
  /// [items] 中非法的正则表达式会被丢弃，不写入配置。
  Future<String> addGroup({
    String name = '',
    String colorHex = CustomHighlightGroup.defaultColorHex,
    List<CustomHighlightItem> items = const [],
  }) async {
    final group = CustomHighlightGroup.create(
      name: name,
      colorHex: colorHex,
      items: _sanitizeItems(items),
    );
    _config = _config.copyWith(
      groups: <CustomHighlightGroup>[..._config.groups, group],
    );
    await _save();
    notifyListeners();
    return group.id;
  }

  /// 修改分组名称与颜色
  ///
  /// 改色时组内全部词条同步换色（词条颜色由分组统一决定）。
  Future<void> updateGroup(
    String id, {
    String? name,
    String? colorHex,
  }) async {
    final index = _config.groups.indexWhere((g) => g.id == id);
    if (index < 0) return;
    final current = _config.groups[index];
    if (name == null && colorHex == null) return;
    if (name != null && name == current.name && colorHex == null) return;
    if (colorHex != null && colorHex == current.colorHex && name == null) return;

    final newGroups = List<CustomHighlightGroup>.from(_config.groups);
    newGroups[index] = current.copyWith(name: name, colorHex: colorHex);
    _config = _config.copyWith(groups: newGroups);
    await _save();
    notifyListeners();
  }

  /// 删除分组（组内词条一并删除）
  Future<void> removeGroup(String id) async {
    final newGroups = _config.groups.where((g) => g.id != id).toList();
    if (newGroups.length == _config.groups.length) return;
    _config = _config.copyWith(groups: newGroups);
    await _save();
    notifyListeners();
  }

  /// 调整分组顺序，[delta] 为 -1 上移、1 下移
  Future<void> moveGroup(String id, int delta) async {
    final index = _config.groups.indexWhere((g) => g.id == id);
    if (index < 0) return;
    final target = index + delta;
    if (target < 0 || target >= _config.groups.length) return;
    final newGroups = List<CustomHighlightGroup>.from(_config.groups);
    final group = newGroups.removeAt(index);
    newGroups.insert(target, group);
    _config = _config.copyWith(groups: newGroups);
    await _save();
    notifyListeners();
  }

  /// 覆盖某个分组的词库
  ///
  /// 词条颜色统一取分组颜色；空词条与非法正则在此处过滤，
  /// 返回被丢弃的非法正则条数，供界面提示。
  Future<int> replaceGroupItems(
    String id,
    List<CustomHighlightItem> newItems,
  ) async {
    final index = _config.groups.indexWhere((g) => g.id == id);
    if (index < 0) return 0;
    final current = _config.groups[index];

    final seen = <String>{};
    final filtered = <CustomHighlightItem>[];
    int invalidCount = 0;
    for (final item in newItems) {
      final trimmed = item.keyword.trim();
      if (trimmed.isEmpty) continue;
      final bool isRegex = item.isRegex;
      if (isRegex && !CustomHighlightRegex.isValid(trimmed)) {
        invalidCount++;
        continue;
      }
      final String key = isRegex ? 're:$trimmed' : 'kw:$trimmed';
      if (!seen.add(key)) continue;
      filtered.add(CustomHighlightItem(
        keyword: trimmed,
        colorHex: current.colorHex,
        isRegex: isRegex,
      ));
    }

    final newGroups = List<CustomHighlightGroup>.from(_config.groups);
    newGroups[index] = current.copyWith(items: filtered);
    _config = _config.copyWith(groups: newGroups);
    await _save();
    notifyListeners();
    return invalidCount;
  }

  /// 批量替换全部分组（用于对话框一次性提交）
  Future<void> replaceAllGroups(List<CustomHighlightGroup> newGroups) async {
    final cleaned = <CustomHighlightGroup>[];
    for (final group in newGroups) {
      final items = _sanitizeItems(group.items);
      // 组色统一落到词条上，避免改色后残留旧色
      cleaned.add(CustomHighlightGroup(
        id: group.id,
        name: group.name,
        colorHex: group.colorHex,
        items: items
            .map((e) => e.copyWith(colorHex: group.colorHex))
            .toList(growable: false),
      ));
    }

    _config = _config.copyWith(groups: cleaned);
    await _save();
    notifyListeners();
  }

  /// 过滤空词条、同组重名与非法正则
  List<CustomHighlightItem> _sanitizeItems(List<CustomHighlightItem> source) {
    final seen = <String>{};
    final result = <CustomHighlightItem>[];
    for (final item in source) {
      final trimmed = item.keyword.trim();
      if (trimmed.isEmpty) continue;
      if (item.isRegex && !CustomHighlightRegex.isValid(trimmed)) continue;
      final String key = item.isRegex ? 're:$trimmed' : 'kw:$trimmed';
      if (!seen.add(key)) continue;
      result.add(item.copyWith(keyword: trimmed));
    }
    return result;
  }
}
