import 'package:flutter/material.dart';
import 'package:quick_write/core/models/custom_highlight.dart';
import 'package:quick_write/core/services/cache_services/misc_cache_service.dart';
import 'package:quick_write/core/services/workspace/custom_highlight_service.dart';
import 'package:quick_write/core/utils/color_utils.dart';
import 'package:quick_write/core/utils/typography_extension.dart';
import 'package:quick_write/shared/widgets/qw_dialogs.dart';
import 'package:quick_write/shared/widgets/qw_snackbar.dart';
import 'package:quick_write/shared/widgets/qw_switch.dart';
import 'package:quick_write/shared/widgets/qw_tooltip.dart';
import 'custom_highlight_group_dialog.dart';
import 'right_sidebar_widgets.dart';

/// 显示自定义高亮设置对话框
///
/// 使用项目统一的 [showDialogBase] 弹窗外壳，固定尺寸避免内容变化导致弹窗大小跳动；
/// 移动端外壳会自动收窄宽度，桌面端与移动端共用同一份内容与交互。
///
/// 配置以「分组」组织：每组一种颜色、一本独立词库，词条在组内用顿号分隔。
Future<void> showCustomHighlightDialog({
  required BuildContext context,
  required CustomHighlightService service,
}) {
  return showDialogBase(
    context: context,
    title: '自定义高亮',
    subtitle: '按分组管理词库，每组可自定义颜色',
    titleAction: _buildRegexHelpButton(context),
    width: 520,
    height: 460,
    content: _CustomHighlightDialogContent(service: service),
  );
}

/// 标题栏帮助按钮：点击弹出正则用法说明
Widget _buildRegexHelpButton(BuildContext context) {
  return CursorTooltipTarget(
    tooltipContent: const Text('正则表达式用法'),
    child: IconButton(
      onPressed: () => _showRegexHelp(context),
      icon: const Icon(Icons.help_outline_rounded, size: 16),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      visualDensity: VisualDensity.compact,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// 弹出正则用法说明（自适应高度，移动端内容可整体滚动）
Future<void> _showRegexHelp(BuildContext context) {
  return showDialogBase<void>(
    context: context,
    title: '正则表达式用法',
    subtitle: '词库中以「re:」开头的词条按正则匹配',
    titleIcon: Icons.code_rounded,
    width: 500,
    height: 460,
    adaptiveHeight: true,
    content: const _RegexHelpContent(),
  );
}

/// 正则用法说明内容
class _RegexHelpContent extends StatelessWidget {
  const _RegexHelpContent();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            '在分组词库里让某条词以「re:」开头，该条按表达式匹配；'
            '语法与 Dart / JavaScript 正则一致，^、\$ 按行生效，区分大小写，. 不跨行。',
            style: context.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          _helpExample(context, r're:【[^】]*】', '高亮整段【…】（连同成对符号）'),
          _helpExample(context, r're:(?<=【)[^】]*(?=】)', '只高亮【】内部的文字'),
          _helpExample(context, r're:【([^】]*)】', '含捕获组时只高亮第 1 组，同样只着色内部'),
          _helpExample(context, r're:《[^》]+》|（[^）]+）', '一次匹配书名号或圆括号里的内容'),
          _helpExample(context, r're:^.*(忽然|骤然).*$', '高亮包含指定字句的整行'),
          const SizedBox(height: 6),
          SelectableText(
            '提示：正则词条请单独占一行（正则内的顿号不会被拆开）；'
            '非法表达式不会写入配置，云端同步来的坏配置也会被跳过而不崩溃；'
            '单条最多着色 1000 处命中。',
            style: context.bodySmall?.copyWith(
              color: colorScheme.error.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }
}

/// 帮助弹窗中的一条「表达式 + 说明」
Widget _helpExample(BuildContext context, String pattern, String description) {
  final colorScheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          pattern,
          style: TextStyle(
            fontSize: 12.5,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w600,
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(height: 2),
        SelectableText(
          description,
          style: context.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}

/// 自定义高亮设置对话框内容
///
/// 顶部为总开关，中部为分组列表，每组对应「一种颜色 + 一本词库」；
/// 点击分组进入编辑，配置实时写入书籍根目录的 JSON 文件。
class _CustomHighlightDialogContent extends StatefulWidget {
  /// 当前书籍的自定义高亮服务
  final CustomHighlightService service;

  const _CustomHighlightDialogContent({required this.service});

  @override
  State<_CustomHighlightDialogContent> createState() =>
      _CustomHighlightDialogContentState();
}

class _CustomHighlightDialogContentState
    extends State<_CustomHighlightDialogContent> {
  /// 上次使用的分组颜色（新建分组默认沿用）
  String _lastColorHex = CustomHighlightGroup.defaultColorHex;

  @override
  void initState() {
    super.initState();
    _lastColorHex = MiscCacheService.instance.getCustomHighlightLastColorHex();
    widget.service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onServiceChanged);
    super.dispose();
  }

  /// service 配置变化时刷新列表
  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  /// 打开某个分组的编辑弹窗
  Future<void> _openGroup(String groupId, {required bool isNewGroup}) async {
    final result = await showCustomHighlightGroupDialog(
      context: context,
      service: widget.service,
      groupId: groupId,
      isNewGroup: isNewGroup,
    );
    if (!mounted) return;

    // 新建后既没起名也没词条的分组视为放弃，直接清理
    if (isNewGroup) {
      final group = widget.service.groupById(groupId);
      if (group != null &&
          group.items.isEmpty &&
          group.name.trim().isEmpty) {
        await widget.service.removeGroup(groupId);
      }
    }

    if (!mounted) return;
    // 选色可能已更新「上次颜色」，刷新以便新建分组沿用
    _lastColorHex = MiscCacheService.instance.getCustomHighlightLastColorHex();

    if (result != null && result.skippedCount > 0) {
      final List<String> parts = <String>[];
      if (result.conflictCount > 0) {
        parts.add('${result.conflictCount} 条已在其他分组');
      }
      if (result.invalidRegexCount > 0) {
        parts.add('${result.invalidRegexCount} 条正则无效');
      }
      SnackBarService.show(context, '已保存，${parts.join('、')}，未加入本组');
    }
    if (mounted) setState(() {});
  }

  /// 新建分组：先落库拿到 id，再进入编辑
  Future<void> _createGroup() async {
    final String colorHex = _lastColorHex.isEmpty
        ? CustomHighlightGroup.defaultColorHex
        : _lastColorHex;
    final String groupId = await widget.service.addGroup(colorHex: colorHex);
    if (!mounted) return;
    await _openGroup(groupId, isNewGroup: true);
  }

  /// 删除分组（含二次确认）
  Future<void> _deleteGroup(CustomHighlightGroup group) async {
    if (group.items.isEmpty) {
      await widget.service.removeGroup(group.id);
      if (mounted) setState(() {});
      return;
    }
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: '删除分组',
      description: '分组「${group.displayName}」及其 ${group.wordCount} 条词条将被删除，此操作不可撤销。',
      type: ConfirmType.delete,
      confirmText: '删除',
      cancelText: '取消',
      icon: Icons.delete_outline,
    );
    if (!confirmed || !mounted) return;
    await widget.service.removeGroup(group.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildEnableToggle(colorScheme),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1),
          ),
          _buildListHeader(colorScheme),
          const SizedBox(height: 8),
          Expanded(child: _buildGroupList(colorScheme)),
          const SizedBox(height: 10),
          Text(
            '每组一种颜色、一本词库；词条在组内用顿号「、」分隔',
            style: context.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建启用开关
  Widget _buildEnableToggle(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          QwSwitch(
            value: widget.service.enabled,
            onChanged: (value) => widget.service.setEnabled(value),
          ),
          const SizedBox(width: 10),
          Text('启用自定义高亮', style: context.titleSmall),
          const Spacer(),
          Text(
            widget.service.enabled ? '已开启' : '已关闭',
            style: context.bodySmall?.copyWith(
              color: widget.service.enabled
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建分组列表标题（含组数、词条数与新建入口）
  Widget _buildListHeader(ColorScheme colorScheme) {
    final int groupCount = widget.service.groups.length;
    final int wordCount = widget.service.wordCount;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Icon(Icons.layers_rounded, size: 16, color: colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            '高亮分组',
            style: context.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$groupCount 组 · $wordCount 条',
              style: context.bodySmall?.copyWith(color: colorScheme.primary),
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _createGroup,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('新建分组'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建分组列表
  Widget _buildGroupList(ColorScheme colorScheme) {
    final groups = widget.service.groups;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: groups.isEmpty
          ? _buildEmptyHint(colorScheme)
          : ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: groups.length,
              separatorBuilder: (_, _) => const SettingDivider(),
              itemBuilder: (context, index) {
                return _buildGroupRow(
                  groups[index],
                  index,
                  groups.length,
                  colorScheme,
                );
              },
            ),
    );
  }

  /// 空状态提示
  Widget _buildEmptyHint(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.layers_clear_rounded,
            size: 36,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          Text(
            '暂无高亮分组',
            style: context.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '点击「新建分组」，为它选一种颜色并录入词库',
            style: context.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }

  /// 单行分组：色点 + 名称 + 词条预览 + 排序/删除
  Widget _buildGroupRow(
    CustomHighlightGroup group,
    int index,
    int total,
    ColorScheme colorScheme,
  ) {
    final String preview = group.items
        .take(4)
        .map((e) => e.isRegex ? 're:${e.keyword}' : e.keyword)
        .join('、');

    return InkWell(
      onTap: () => _openGroup(group.id, isNewGroup: false),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: Row(
          children: [
            ColorIndicator(color: ColorUtils.parseHex(group.colorHex)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          group.displayName,
                          style: context.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${group.wordCount} 条',
                        style: context.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                  if (preview.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      style: context.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            _buildIconButton(
              icon: Icons.keyboard_arrow_up_rounded,
              tooltip: '上移',
              enabled: index > 0,
              onTap: () => widget.service.moveGroup(group.id, -1),
              colorScheme: colorScheme,
            ),
            _buildIconButton(
              icon: Icons.keyboard_arrow_down_rounded,
              tooltip: '下移',
              enabled: index < total - 1,
              onTap: () => widget.service.moveGroup(group.id, 1),
              colorScheme: colorScheme,
            ),
            _buildIconButton(
              icon: Icons.delete_outline,
              tooltip: '删除分组',
              onTap: () => _deleteGroup(group),
              color: Colors.redAccent,
              colorScheme: colorScheme,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建图标按钮
  Widget _buildIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool enabled = true,
    Color? color,
    required ColorScheme colorScheme,
  }) {
    return CursorTooltipTarget(
      tooltipContent: Text(tooltip),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            icon,
            size: 18,
            color: !enabled
                ? colorScheme.onSurfaceVariant.withValues(alpha: 0.25)
                : (color ?? colorScheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}
