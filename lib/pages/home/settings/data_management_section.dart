import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:quick_write/core/providers/writing_session_tracker.dart';
import 'package:quick_write/core/providers/writing_stats_provider.dart';
import 'package:quick_write/core/services/app_paths.dart';
import 'package:quick_write/core/services/backup_service.dart';
import 'package:quick_write/core/services/chapter_word_count_service.dart';
import 'package:quick_write/core/services/writing_stats_service.dart';
import 'package:quick_write/core/utils/file_explorer.dart';
import 'package:quick_write/core/utils/platform_capabilities.dart';
import 'package:quick_write/pages/home/settings/setting_widgets.dart';
import 'package:quick_write/shared/widgets/widgets.dart';

/// 数据管理设置分组
///
/// 提供以下功能：
/// - 在文件管理器中打开数据目录、缓存目录、备份目录（仅桌面端提供）
/// - 重置码字统计数据
/// - 清除所有备份文件
class DataManagementSection extends StatelessWidget {
  const DataManagementSection({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingSectionCard(
      title: '数据管理',
      children: [
        // 目录定位依赖桌面文件管理器，移动端不提供
        if (PlatformCapabilities.supportsFileManagerReveal) ...[
          _buildDataDirTile(context),
          _buildCacheDirTile(context),
          _buildBackupDirTile(context),
        ],
        _buildResetStatsTile(context),
        _buildClearBackupsTile(context),
      ],
    );
  }

  /// 数据目录：在文件管理器中打开应用数据根目录
  Widget _buildDataDirTile(BuildContext context) {
    return SettingTile(
      icon: Icons.folder_outlined,
      title: '数据目录',
      subtitle: '包含书籍、备份、回收站及配置文件',
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => _openDirectory(context, () async {
        return AppPaths.instance.appRootPath;
      }),
    );
  }

  /// 缓存目录：在文件管理器中打开缓存目录
  Widget _buildCacheDirTile(BuildContext context) {
    return SettingTile(
      icon: Icons.storage_outlined,
      title: '缓存目录',
      subtitle: '存储窗体状态、编辑位置等临时缓存数据',
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => _openDirectory(context, AppPaths.instance.getCachePath),
    );
  }

  /// 备份目录：在文件管理器中打开备份目录
  Widget _buildBackupDirTile(BuildContext context) {
    return SettingTile(
      icon: Icons.history_edu_outlined,
      title: '备份目录',
      subtitle: '存储章节和设定的历史版本备份',
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => _openDirectory(context, AppPaths.instance.getBackupPath),
    );
  }

  /// 重置码字统计数据：清空全部码字统计记录
  Widget _buildResetStatsTile(BuildContext context) {
    return SettingTile(
      icon: Icons.restart_alt_outlined,
      title: '重置码字统计数据',
      subtitle: '清空所有书籍的码字统计记录，操作不可恢复',
      accentColor: Theme.of(context).colorScheme.error,
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () => _confirmResetStats(context),
    );
  }

  /// 清除备份文件：删除所有历史备份
  Widget _buildClearBackupsTile(BuildContext context) {
    return SettingTile(
      icon: Icons.cleaning_services_outlined,
      title: '清除备份文件',
      subtitle: '删除所有书籍的章节和设定历史备份，操作不可恢复',
      accentColor: Theme.of(context).colorScheme.error,
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () => _confirmClearBackups(context),
    );
  }

  /// 在文件管理器中打开指定目录
  ///
  /// [pathProvider] 返回目录路径的回调，可为同步或异步
  Future<void> _openDirectory(
    BuildContext context,
    Future<String> Function() pathProvider,
  ) async {
    try {
      final path = await pathProvider();
      final success = await FileExplorer.openDirectory(path);
      if (!context.mounted) return;
      SnackBarService.show(
        context,
        success ? '已在文件管理器中打开' : '打开目录失败，请检查目录是否存在',
      );
    } catch (e) {
      if (!context.mounted) return;
      SnackBarService.showError(context, '打开目录失败：$e');
    }
  }

  /// 显示重置码字统计数据的确认对话框
  void _confirmResetStats(BuildContext context) {
    showConfirmDialog(
      context: context,
      title: '重置码字统计数据',
      description: '将清空所有书籍的累计码字字数、时长等统计记录，此操作不可恢复。',
      type: ConfirmType.delete,
      confirmText: '重置',
      cancelText: '取消',
      onConfirm: () async {
        await WritingStatsService.instance.clearAllStats();
        // 今日章节字数是一份独立持久化的记录（SharedPreferences），
        // 不在 clearAllStats 的清理范围内，必须一并清空，否则重置后统计页仍显示旧数据
        await ChapterWordCountService.instance.clear();
        // 工作台的会话追踪器在内存中仍持有今日字数与待写盘增量：
        // 只清数据库会导致侧边栏继续显示旧数值，且防抖落库会把旧增量写回，
        // 这里把存活实例的今日/会话数据一并归零并丢弃待写盘增量
        WritingSessionTracker.resetAllLive();
        // 刷新统计页数据，避免重置后仍展示重置前的缓存结果
        if (context.mounted) {
          await context.read<WritingStatsProvider>().refresh();
        }
        if (!context.mounted) return;
        SnackBarService.showSuccess(context, '码字统计数据已重置');
      },
    );
  }

  /// 显示清除备份文件的确认对话框
  void _confirmClearBackups(BuildContext context) {
    showConfirmDialog(
      context: context,
      title: '清除备份文件',
      description: '将删除所有书籍的章节和设定历史备份，此操作不可恢复。',
      type: ConfirmType.delete,
      confirmText: '清除',
      cancelText: '取消',
      onConfirm: () async {
        final count = await BackupService.instance.clearAllBackups();
        if (!context.mounted) return;
        SnackBarService.showSuccess(
          context,
          count > 0 ? '已清除 $count 个备份文件' : '没有需要清除的备份文件',
        );
      },
    );
  }
}
