import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:quick_write/core/constants/word_count_floating_mode.dart';
import 'package:quick_write/core/providers/workspace_provider.dart';
import 'package:quick_write/core/services/settings_service.dart';
import 'package:quick_write/core/utils/platform_capabilities.dart';
import 'package:quick_write/core/utils/typography_extension.dart';

/// 字数浮窗
///
/// 移动端叠加在编辑区上的一层半透明浮窗，实时显示当前标签页字数；
/// 开启码字速度后额外显示一行码字速度。显示位置由设置决定，
/// 位于底部时随编辑区一同被键盘上推。
/// 点击浮窗弹出「字数统计」弹窗，与底部状态栏点击字数使用同一统计页。
class WordCountFloatingWindow extends StatefulWidget {
  const WordCountFloatingWindow({super.key, this.onTap});

  /// 点击浮窗时的回调，由外层打开字数统计弹窗；为空时不响应点击
  final VoidCallback? onTap;

  @override
  State<WordCountFloatingWindow> createState() => _WordCountFloatingWindowState();
}

class _WordCountFloatingWindowState extends State<WordCountFloatingWindow> {
  /// 浮窗与编辑区边缘的间距
  static const double _edgeMargin = 12;

  /// 浮窗背景不透明度（半透明效果）
  static const double _backgroundOpacity = 0.72;

  /// 字号整体较早期版本缩小约三分之一
  static const double _labelFontSize = 10;
  static const double _valueFontSize = 11;
  static const double _iconSize = 10;

  @override
  void initState() {
    super.initState();
    // 设置变化（开关、显示位置、码字速度）需要重新构建以应用
    SettingsService.instance.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  /// 处理设置变化
  void _onSettingsChanged() {
    if (mounted) {
      setState(() {
        // 重新构建以应用新的设置
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 移动端专属功能，桌面端不显示
    if (!PlatformCapabilities.isMobile) return const SizedBox.shrink();
    // 未开启时不显示
    if (!SettingsService.instance.wordCountFloatingEnabled) return const SizedBox.shrink();

    final provider = context.watch<WorkspaceProvider>();
    final tab = provider.currentTab;
    // 没有打开的标签页时不显示
    if (tab == null) return const SizedBox.shrink();

    // 码字速度开启时需同时监听会话追踪器，随其每秒刷新
    final tracker = provider.sessionTracker;
    final speedEnabled = SettingsService.instance.wordCountFloatingSpeedEnabled;
    final Listenable listenable = speedEnabled && tracker != null
        ? Listenable.merge([provider.wordCountNotifier, tracker])
        : provider.wordCountNotifier;
    // 两项都关闭时仍保留字数，避免浮窗变为空白
    final bool showWordCount =
        SettingsService.instance.wordCountFloatingWordCountEnabled || !speedEnabled;

    // 计算浮窗贴靠的四角位置
    final position = SettingsService.instance.wordCountFloatingPosition;
    final bool alignTop = position == 'topLeft' || position == 'topRight';
    final bool alignLeft = position == 'topLeft' || position == 'bottomLeft';
    // 浮窗显示样式（标准、精简、极简）
    final mode = SettingsService.instance.wordCountFloatingMode;

    return Positioned(
      top: alignTop ? _edgeMargin : null,
      bottom: alignTop ? null : _edgeMargin,
      left: alignLeft ? _edgeMargin : null,
      right: alignLeft ? null : _edgeMargin,
      child: ListenableBuilder(
        listenable: listenable,
        builder: (context, _) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: _buildWindow(
            context,
            tab.wordCount,
            speedEnabled ? (tracker?.writingSpeed ?? 0) : null,
            mode,
            showWordCount,
          ),
        ),
      ),
    );
  }

  /// 构建浮窗内容
  ///
  /// [writingSpeed] 非空时额外渲染一行码字速度
  /// [mode] 决定每一行展示图标、标签与数值的组合
  /// [showWordCount] 控制是否渲染本章字数行
  Widget _buildWindow(
    BuildContext context,
    int wordCount,
    int? writingSpeed,
    WordCountFloatingMode mode,
    bool showWordCount,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        // 半透明底色，保留正文可见
        color: colorScheme.surface.withValues(alpha: _backgroundOpacity),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 本章字数
          if (showWordCount)
            _buildRow(
              context,
              icon: Icons.text_fields_rounded,
              label: '字数',
              value: '$wordCount 字',
              mode: mode,
            ),
          if (writingSpeed != null) ...[
            // 码字速度
            if (showWordCount) const SizedBox(height: 2),
            _buildRow(
              context,
              icon: Icons.speed_rounded,
              label: '速度',
              value: '$writingSpeed 字/分',
              mode: mode,
            ),
          ],
        ],
      ),
    );
  }

  /// 构建单行统计
  ///
  /// 按 [mode] 决定是否渲染图标与标签，数值始终显示
  Widget _buildRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required WordCountFloatingMode mode,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mode.showIcon) ...[
          Icon(icon, size: _iconSize, color: colorScheme.primary),
          const SizedBox(width: 4),
        ],
        if (mode.showLabel) ...[
          Text(
            label,
            style: context.bodySmall?.copyWith(
              fontSize: _labelFontSize,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 5),
        ],
        Text(
          value,
          style: context.bodyMedium?.copyWith(
            fontSize: _valueFontSize,
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
