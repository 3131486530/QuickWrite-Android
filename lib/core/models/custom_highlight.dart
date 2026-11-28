import 'package:uuid/uuid.dart';

/// 自定义高亮单个词条
///
/// [keyword] 在字面量模式下是原样匹配的关键词，在正则模式下是正则表达式；
/// 字面量模式（默认）的行为与旧版本完全一致，不做任何转义。
/// 颜色由所属分组统一决定，此处的 [colorHex] 仅为兼容旧配置保留。
class CustomHighlightItem {
  /// 需要高亮显示的关键词（字面量模式）或正则表达式（正则模式）
  final String keyword;

  /// 高亮颜色的十六进制字符串（#RRGGBB 格式）
  final String colorHex;

  /// 是否把 [keyword] 当作正则表达式解析
  final bool isRegex;

  const CustomHighlightItem({
    required this.keyword,
    required this.colorHex,
    this.isRegex = false,
  });

  /// 从 JSON 反序列化
  factory CustomHighlightItem.fromJson(Map<String, dynamic> json) {
    return CustomHighlightItem(
      keyword: (json['keyword'] as String?) ?? '',
      colorHex: (json['colorHex'] as String?) ?? '#FFB300',
      // 旧配置无此字段；云端下来的异常类型也一律降级为字面量，避免解析失败
      isRegex: json['isRegex'] == true,
    );
  }

  /// 序列化为 JSON
  ///
  /// 字面量模式不写入新字段，保证旧配置文件的字节内容不变（旧版本也能无损读取），
  /// 同时避免只为默认模式触发一次不必要的云同步。
  Map<String, dynamic> toJson() => {
        'keyword': keyword,
        'colorHex': colorHex,
        if (isRegex) 'isRegex': true,
      };

  /// 创建一份修改后的副本
  CustomHighlightItem copyWith({
    String? keyword,
    String? colorHex,
    bool? isRegex,
  }) {
    return CustomHighlightItem(
      keyword: keyword ?? this.keyword,
      colorHex: colorHex ?? this.colorHex,
      isRegex: isRegex ?? this.isRegex,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomHighlightItem &&
          other.keyword == keyword &&
          other.colorHex == colorHex &&
          other.isRegex == isRegex;

  @override
  int get hashCode => Object.hash(keyword, colorHex, isRegex);
}

/// 自定义高亮分组
///
/// 一个分组 = 一种颜色 + 一本独立词库。同组内所有词条共用分组颜色，
/// 组与组之间颜色互不影响，避免过去「一个词一种颜色」的逐条配置负担。
class CustomHighlightGroup {
  /// 分组唯一标识（分组重命名、调序时保持稳定，不依赖数组下标）
  final String id;

  /// 分组名称（可为空，显示时回退为「未命名分组」）
  final String name;

  /// 分组颜色（#RRGGBB），组内全部词条共用
  final String colorHex;

  /// 组内词条列表
  final List<CustomHighlightItem> items;

  const CustomHighlightGroup({
    required this.id,
    this.name = '',
    required this.colorHex,
    this.items = const [],
  });

  /// 默认分组颜色
  static const String defaultColorHex = '#FFB300';

  /// 创建一个新分组（自动生成 id）
  factory CustomHighlightGroup.create({
    String name = '',
    String colorHex = defaultColorHex,
    List<CustomHighlightItem> items = const [],
  }) {
    return CustomHighlightGroup(
      id: const Uuid().v4(),
      name: name,
      colorHex: colorHex,
      items: _normalizeItems(items, colorHex),
    );
  }

  /// 从 JSON 反序列化
  ///
  /// [fallbackId] 用于旧数据或云端缺字段时生成稳定 id（同一次解析内保持一致）。
  factory CustomHighlightGroup.fromJson(
    Map<String, dynamic> json, {
    String fallbackId = '',
  }) {
    final String colorHex = _normalizeHex((json['colorHex'] as String?) ?? defaultColorHex);
    final rawItems = json['items'];
    final items = <CustomHighlightItem>[];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is Map<String, dynamic>) {
          final parsed = CustomHighlightItem.fromJson(item);
          // 颜色统一由分组决定，忽略词条上残留的旧颜色
          items.add(parsed.copyWith(colorHex: colorHex));
        }
      }
    }
    final String rawId = ((json['id'] as String?) ?? '').trim();
    return CustomHighlightGroup(
      id: rawId.isEmpty ? fallbackId : rawId,
      name: (json['name'] as String?) ?? '',
      colorHex: colorHex,
      items: items,
    );
  }

  /// 分组显示名（空名时回退）
  String get displayName {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '未命名分组' : trimmed;
  }

  /// 组内词条数量
  int get wordCount => items.length;

  /// 词库文本：顿号分隔，正则词条带「re:」前缀（与词库编辑框格式一致）
  String get wordsText => items
      .map((e) => e.isRegex ? 're:${e.keyword}' : e.keyword)
      .join('、');

  /// 序列化为 JSON
  ///
  /// 组内词条不写颜色，改色时只需改分组一处，文件更小也不会有颜色残留。
  Map<String, dynamic> toJson() => {
        'id': id,
        if (name.trim().isNotEmpty) 'name': name.trim(),
        'colorHex': colorHex,
        'items': items
            .map((e) => {
                  'keyword': e.keyword,
                  if (e.isRegex) 'isRegex': true,
                })
            .toList(),
      };

  /// 创建一份修改后的副本
  CustomHighlightGroup copyWith({
    String? id,
    String? name,
    String? colorHex,
    List<CustomHighlightItem>? items,
  }) {
    final String nextColor = colorHex ?? this.colorHex;
    final List<CustomHighlightItem> nextItems = items ?? this.items;
    return CustomHighlightGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      colorHex: nextColor,
      items: colorHex == null ? nextItems : _normalizeItems(nextItems, nextColor),
    );
  }

  /// 统一词条颜色并补齐空关键词过滤
  static List<CustomHighlightItem> _normalizeItems(
    List<CustomHighlightItem> source,
    String colorHex,
  ) {
    return source
        .where((e) => e.keyword.trim().isNotEmpty)
        .map((e) => e.copyWith(keyword: e.keyword.trim(), colorHex: colorHex))
        .toList();
  }

  /// 把 `#RGB` / `RRGGBB` 等写法统一成 `#RRGGBB`
  ///
  /// 非法或云端同步来的脏颜色一律回退默认色，避免渲染层 Color 解析崩溃。
  static String _normalizeHex(String raw) {
    var hex = raw.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    hex = hex.toUpperCase();
    if (!RegExp(r'^[0-9A-F]{6}([0-9A-F]{2})?$').hasMatch(hex)) {
      return defaultColorHex;
    }
    // 只保留 RGB，透明度由渲染层的分组透明度统一控制
    return '#${hex.substring(0, 6)}';
  }
}

/// 自定义高亮整体配置
///
/// 结构：启用开关 + 分组列表。旧版本的单层 items 配置在加载时
/// 会自动按颜色归并为分组，保证升级后原有高亮不丢失。
class CustomHighlightConfig {
  /// 是否启用自定义高亮
  final bool enabled;

  /// 分组列表
  final List<CustomHighlightGroup> groups;

  const CustomHighlightConfig({
    this.enabled = false,
    this.groups = const [],
  });

  /// 空配置（默认值）
  static const CustomHighlightConfig empty = CustomHighlightConfig();

  /// 全部词条（展开所有分组，颜色取所属分组色）
  List<CustomHighlightItem> get items =>
      groups.expand((g) => g.items).toList(growable: false);

  /// 从 JSON 反序列化
  factory CustomHighlightConfig.fromJson(Map<String, dynamic> json) {
    final bool enabled = json['enabled'] == true;

    final rawGroups = json['groups'];
    final groups = <CustomHighlightGroup>[];
    if (rawGroups is List) {
      for (final raw in rawGroups) {
        if (raw is Map<String, dynamic>) {
          groups.add(CustomHighlightGroup.fromJson(
            raw,
            fallbackId: 'group_${groups.length}',
          ));
        }
      }
    }

    // 旧配置迁移：没有 groups 但有扁平 items 时，按颜色合并为分组
    if (groups.isEmpty) {
      groups.addAll(_migrateLegacyItems(json['items']));
    }

    return CustomHighlightConfig(enabled: enabled, groups: groups);
  }

  /// 旧版扁平 items → 分组（按颜色聚合，保持首次出现的颜色顺序）
  static List<CustomHighlightGroup> _migrateLegacyItems(Object? rawItems) {
    if (rawItems is! List) return const [];
    final order = <String>[];
    final grouped = <String, List<CustomHighlightItem>>{};
    for (final raw in rawItems) {
      if (raw is! Map<String, dynamic>) continue;
      final item = CustomHighlightItem.fromJson(raw);
      if (item.keyword.trim().isEmpty) continue;
      final color = CustomHighlightGroup._normalizeHex(item.colorHex);
      if (!grouped.containsKey(color)) {
        order.add(color);
        grouped[color] = <CustomHighlightItem>[];
      }
      grouped[color]!.add(item.copyWith(
        keyword: item.keyword.trim(),
        colorHex: color,
      ));
    }

    final result = <CustomHighlightGroup>[];
    for (int i = 0; i < order.length; i++) {
      final color = order[i];
      result.add(CustomHighlightGroup(
        id: 'legacy_${i}_${color.replaceFirst('#', '')}',
        name: '分组 ${i + 1}',
        colorHex: color,
        items: grouped[color]!,
      ));
    }
    return result;
  }

  /// 序列化为 JSON
  ///
  /// [items] 为兼容旧版本的镜像字段：旧版 App 读到分组文件仍能正常高亮，
  /// 升级期间不至于因为回退旧版本而丢掉全部高亮。
  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'groups': groups.map((g) => g.toJson()).toList(),
        'items': items.map((e) => e.toJson()).toList(),
      };

  /// 创建一份修改后的副本
  CustomHighlightConfig copyWith({
    bool? enabled,
    List<CustomHighlightGroup>? groups,
  }) {
    return CustomHighlightConfig(
      enabled: enabled ?? this.enabled,
      groups: groups ?? this.groups,
    );
  }
}
