import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:quick_write/core/constants/punctuation_symbols.dart';
import 'package:quick_write/core/constants/quick_input_action.dart';
import 'package:quick_write/core/constants/word_count_floating_mode.dart';
import 'package:quick_write/core/models/app_settings.dart';
import 'package:quick_write/core/models/quick_phrase.dart';
import 'package:quick_write/core/models/text_replacement_rule.dart';
import 'package:quick_write/core/theme/custom_theme.dart';
import 'package:quick_write/core/theme/theme_store.dart';
import 'package:quick_write/core/services/cloud_sync/cloud_sync_service.dart';
import 'package:quick_write/core/utils/platform_capabilities.dart';
import 'app_paths.dart';
import 'font_service.dart';

/// 设置服务类
/// 
/// 负责管理应用的全局设置，包括：
/// - 配置文件的读写（存储在 文档/QuickWrite 目录下）
/// - 应用首次启动时创建配置目录
/// - 提供设置的获取、更新、保存功能
/// 
/// 使用方式：
/// ```dart
/// // 初始化（在 main.dart 中调用）
/// await SettingsService.instance.initialize();
/// 
/// // 获取设置
/// final settings = SettingsService.instance.settings;
/// 
/// // 更新设置
/// await SettingsService.instance.updateThemeMode(ThemeMode.dark);
/// await SettingsService.instance.updateSettings(newSettings);
/// ```
class SettingsService extends ChangeNotifier {
  // ================= 单例模式 =================
  static final SettingsService instance = SettingsService._internal();
  SettingsService._internal();
  
  // ================= 常量定义 =================
    
  /// SharedPreferences 中存储配置文件路径的 key
  static const String _configPathKey = 'config_file_path';

  /// 配置文件内记录设置最后修改时间的键名
  static const String _syncStampKey = 'settingsUpdatedAt';

  /// 最早时间戳
  ///
  /// 首次启动生成的默认配置取该时间，使云端已有的设置能够覆盖它
  static const String _epochStamp = '1970-01-01T00:00:00.000Z';

  /// 设置同步实体的稳定标识
  static const String syncEntityId = 'appSettings';

  // ================= 状态属性 =================
  
  /// 当前设置
  /// 使用当前平台的默认设置作为初始值，保持默认值单一数据源
  AppSettings _settings = _platformDefaults;

  /// 当前平台的默认设置
  ///
  /// 移动端与桌面端存在少量默认值差异（如大纲编辑器左右边距）
  static AppSettings get _platformDefaults =>
      PlatformCapabilities.isMobile ? AppSettings.mobileDefaults : AppSettings.defaults;
  
  /// 获取当前设置（只读）
  AppSettings get settings => _settings;

  /// 自定义主题存取服务
  final ThemeStore _themeStore = ThemeStore();

  /// 已保存的自定义主题列表
  /// 主题定义独立存放于主题目录下的 JSON 文件，不再随 settings.json 保存
  List<CustomTheme> _customThemes = const [];

  /// 解析后的快捷输入栏符号列表
  /// 设置变化时重新解析，避免每次读取按键时重复解析文本
  List<PunctuationSymbol> _quickInputSymbols = PunctuationSymbols.quickInputKeys;
  
  /// 配置文件完整路径
  String? _configFilePath;
  
  /// 是否已初始化
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// 设置内容的最后修改时间（UTC，ISO8601）
  ///
  /// 参与云同步的版本判定：与其它设备上的设置取较新者，
  /// 换设备后可直接恢复上次的配置，无需重新设置
  String? _settingsSyncStamp;

  /// 是否首次启动（配置文件是否是新创建的）
  bool _isFirstLaunch = false;
  bool get isFirstLaunch => _isFirstLaunch;

  /// 防抖保存定时器
  /// 用于在滑块拖动等连续操作时延迟写入文件，避免频繁 IO
  Timer? _saveDebounceTimer;

  /// 防抖延迟时间（毫秒）
  static const int _saveDebounceDelay = 500;

  // ================= 初始化方法 =================
  
  /// 初始化设置服务
  /// 
  /// 该方法应该在应用启动时调用（main.dart 中）
  /// 主要工作：
  /// 1. 确保 AppPaths 已初始化
  /// 2. 加载配置文件（如果存在）或创建默认配置
  Future<void> initialize() async {
    if (_isInitialized) {
      debugPrint('SettingsService 已经初始化，跳过重复初始化');
      return;
    }
    
    try {
      // 确保 AppPaths 已初始化
      if (!AppPaths.instance.isInitialized) {
        await AppPaths.instance.initialize();
      }
      
      // 从 AppPaths 获取配置文件路径
      _configFilePath = AppPaths.instance.configFilePath;
      debugPrint('配置文件路径: $_configFilePath');
      
      // 保存配置目录路径到 SharedPreferences（方便后续使用）
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_configPathKey, AppPaths.instance.appRootPath);
      
      // 加载配置文件
      await _loadSettings();
      _syncQuickInputSymbols();
      
      // 加载自定义主题（独立存放于主题目录）
      _customThemes = await _themeStore.loadAll();
      
      _isInitialized = true;
      debugPrint('SettingsService 初始化完成');
    } catch (e, stackTrace) {
      debugPrint('SettingsService 初始化失败: $e');
      debugPrint('堆栈跟踪: $stackTrace');
      // 即使初始化失败，也使用默认设置
      _settings = _platformDefaults;
      _isInitialized = true;
    }
  }

  // ================= 配置文件读写 =================
  
  /// 获取当前系统的默认字体
  String _getSystemDefaultFontFamily() {
    if (PlatformCapabilities.isWindows) {
      return 'Microsoft YaHei';
    } else if (PlatformCapabilities.isMacOS) {
      return 'PingFang SC';
    } else if (PlatformCapabilities.isLinux) {
      return 'Noto Sans SC';
    } else {
      return 'Microsoft YaHei';
    }
  }

  /// 获取当前系统的默认字体名称
  /// 用于字体下拉菜单中"默认"选项的重置操作
  String get defaultFontFamily => _getSystemDefaultFontFamily();

  /// 从配置文件加载设置
  Future<void> _loadSettings() async {
    if (_configFilePath == null) {
      debugPrint('配置文件路径为空，使用默认设置');
      _settings = _platformDefaults;
      return;
    }
    
    final configFile = File(_configFilePath!);
    
    if (await configFile.exists()) {
      try {
        final content = await configFile.readAsString();
        final jsonMap = json.decode(content) as Map<String, dynamic>;
        _settings = AppSettings.fromJson(jsonMap);
        _settingsSyncStamp = jsonMap[_syncStampKey] as String?;
        if (_settingsSyncStamp == null) {
          // 旧版本配置没有时间戳，用文件修改时间兜底，避免被误判为刚改过
          try {
            _settingsSyncStamp =
                (await configFile.stat()).modified.toUtc().toIso8601String();
          } catch (e) {
            _settingsSyncStamp = _epochStamp;
          }
        }
        _isFirstLaunch = false; // 配置文件存在，不是首次启动
        debugPrint('已加载配置文件: $_settings');
      } catch (e) {
        debugPrint('解析配置文件失败: $e，使用默认设置');
        _settings = _platformDefaults;
        _isFirstLaunch = false; // 配置文件存在但损坏，不是首次启动
        // 尝试修复损坏的配置文件
        await _saveSettings();
      }
    } else {
      debugPrint('配置文件不存在，创建默认配置');
      // 首次启动时，根据系统设置默认字体
      final defaultFont = _getSystemDefaultFontFamily();
      _settings = _platformDefaults.copyWith(fontFamily: defaultFont);
      _isFirstLaunch = true; // 配置文件不存在，是首次启动
      await _saveSettings(stamp: _epochStamp);
    }
  }
  
  /// 保存设置到配置文件
  Future<bool> _saveSettings({String? stamp}) async {
    if (_configFilePath == null) {
      debugPrint('配置文件路径为空，无法保存');
      return false;
    }
    
    try {
      final configFile = File(_configFilePath!);
      final resolvedStamp = stamp ?? DateTime.now().toUtc().toIso8601String();
      final jsonMap = Map<String, dynamic>.from(_settings.toJson())
        ..[_syncStampKey] = resolvedStamp;
      final jsonContent = const JsonEncoder.withIndent('  ').convert(jsonMap);
      await configFile.writeAsString(jsonContent);
      _settingsSyncStamp = resolvedStamp;
      debugPrint('配置已保存: $_settings');
      return true;
    } catch (e) {
      debugPrint('保存配置文件失败: $e');
      return false;
    }
  }

  /// 根据当前设置重新解析快捷输入栏符号列表
  void _syncQuickInputSymbols() {
    _quickInputSymbols = PunctuationSymbols.parseSymbolList(_settings.quickInputSymbolsText);
  }

  // ================= 云同步支持 =================

  /// 构建参与云同步的设置实体
  ///
  /// 除字体家族以外的全部设置项都会进入实体：字体文件本身不参与云同步，
  /// 字体家族若跨设备搬运会指向本机不存在的字体，因此保留本机取值
  Map<String, dynamic> buildSyncEntity() {
    return {
      'uuid': syncEntityId,
      'updatedAt': _settingsSyncStamp ?? _epochStamp,
      'payload': _settingsPayloadForSync(),
    };
  }

  /// 生成同步用设置 JSON，剔除字体家族字段
  Map<String, dynamic> _settingsPayloadForSync() {
    final jsonMap = Map<String, dynamic>.from(_settings.toJson());

    final global = jsonMap['global'];
    if (global is Map) {
      global.remove('appFontFamily');
    }

    final editor = jsonMap['editor'];
    if (editor is Map) {
      final font = editor['font'];
      if (font is Map) {
        font.remove('family');
        font.remove('outlineFamily');
        font.remove('outlineTitleFamily');
      }

      final layout = editor['layout'];
      if (layout is Map) {
        final chapterTitle = layout['chapterTitle'];
        if (chapterTitle is Map) {
          chapterTitle.remove('family');
        }
      }
    }

    return jsonMap;
  }

  /// 应用云端同步下来的设置
  ///
  /// 字体家族保留本机取值，其余设置全部按远端内容生效并立即通知界面刷新；
  /// 时间戳沿用远端时间，避免刚恢复的设置被再次判定为新改动而回传
  Future<void> applySyncedSettings(Map<String, dynamic> entity) async {
    final payload = entity['payload'];
    if (payload is! Map) return;

    final AppSettings remote;
    try {
      remote = AppSettings.fromJson(Map<String, dynamic>.from(payload));
    } catch (e) {
      debugPrint('解析云端设置失败: $e');
      return;
    }

    final merged = remote.copyWith(
      appFontFamily: _settings.appFontFamily,
      fontFamily: _settings.fontFamily,
      outlineFontFamily: _settings.outlineFontFamily,
      outlineTitleFontFamily: _settings.outlineTitleFontFamily,
      chapterTitleFontFamily: _settings.chapterTitleFontFamily,
    );

    final stamp = entity['updatedAt'] as String? ?? _epochStamp;
    if (merged == _settings && stamp == _settingsSyncStamp) return;

    _cancelDebouncedSave();
    _settings = merged;
    _syncQuickInputSymbols();
    final success = await _saveSettings(stamp: stamp);
    notifyListeners();

    debugPrint('已应用云端设置: $success');
  }

  // ================= 主题设置相关 =================
  
  /// 获取当前主题模式
  ThemeMode get themeMode => _settings.themeModeValue;
  
  /// 更新主题模式
  /// 
  /// [mode] 新的主题模式
  /// 返回是否保存成功
  Future<bool> updateThemeMode(ThemeMode mode) async {
    final newSettings = _settings.copyWith(
      themeMode: AppSettings.themeModeToString(mode),
    );
    
    if (newSettings == _settings) {
      debugPrint('主题设置未变化，跳过保存');
      return true;
    }
    
    _settings = newSettings;
    final success = await _saveSettings();
    
    if (success) {
      notifyListeners();
    }
    
    return success;
  }

  // ================= 自定义主题设置相关 =================

  /// 获取当前激活的自定义主题 ID（null 表示使用内置主题）
  String? get activeCustomThemeId => _settings.activeCustomThemeId;

  /// 获取已保存的自定义主题列表
  List<CustomTheme> get customThemes => _customThemes;

  /// 获取当前激活的自定义主题对象
  /// 未激活或激活的主题已被删除时返回 null
  CustomTheme? get activeCustomTheme {
    final id = _settings.activeCustomThemeId;
    if (id == null) return null;
    for (final theme in _customThemes) {
      if (theme.id == id) return theme;
    }
    return null;
  }

  /// 更新已保存的自定义主题列表
  ///
  /// 主题定义写入主题目录下的独立文件，列表中已移除的主题其文件会被删除
  Future<bool> updateCustomThemes(List<CustomTheme> themes) async {
    final success = await _themeStore.syncAll(themes);
    _customThemes = themes;
    notifyListeners();
    if (success) {
      // 主题文件已更新，交由云同步服务安排一次同步
      CloudSyncService.instance.notifyLocalChange();
    }
    return success;
  }

  /// 更新当前激活的自定义主题 ID
  /// [id] 传入 null 表示切换回内置主题
  Future<bool> updateActiveCustomThemeId(String? id) async {
    final newSettings = _settings.copyWith(activeCustomThemeId: id);
    return updateSettings(newSettings);
  }
  
  /// 是否在新窗口中打开工作台；Linux/macOS 恒为 false，配置值保留待日后恢复
  bool get openWorkspaceInNewWindow =>
      PlatformCapabilities.isLinux || PlatformCapabilities.isMacOS
          ? false
          : _settings.openWorkspaceInNewWindow;
  
  /// 更新是否在新窗口中打开工作台
  Future<bool> updateOpenWorkspaceInNewWindow(bool value) async {
    final newSettings = _settings.copyWith(openWorkspaceInNewWindow: value);
    return updateSettings(newSettings);
  }

  // ================= 窗口关闭行为设置相关 =================

  /// 是否处于多窗口模式（工作台在独立窗口中打开）
  bool get isMultiWindowMode => openWorkspaceInNewWindow;

  /// 获取关闭主窗口行为（用户设置值，见 AppSettings.closeActionXxx）
  String get closeWindowAction => _settings.closeWindowAction;

  /// 获取实际生效的关闭主窗口行为
  /// 多窗口模式下多个窗口同属一个进程，关闭主窗口会连带退出所有窗口，
  /// 因此该模式下固定为最小化至托盘，不允许用户修改
  String get effectiveCloseWindowAction =>
      isMultiWindowMode ? AppSettings.closeActionTray : _settings.closeWindowAction;

  /// 更新关闭主窗口行为
  Future<bool> updateCloseWindowAction(String value) async {
    final newSettings = _settings.copyWith(closeWindowAction: value);
    return updateSettings(newSettings);
  }

  // ================= 启动与恢复设置相关 =================

  /// 获取是否在启动时自动打开上一次编辑的作品
  bool get autoOpenLastWorkOnStartup => _settings.autoOpenLastWorkOnStartup;

  /// 更新是否在启动时自动打开上一次编辑的作品
  Future<bool> updateAutoOpenLastWorkOnStartup(bool value) async {
    final newSettings = _settings.copyWith(autoOpenLastWorkOnStartup: value);
    return updateSettings(newSettings);
  }

  /// 获取是否在打开作品时恢复上一次退出时打开的标签页
  bool get restoreTabsOnOpenWork => _settings.restoreTabsOnOpenWork;

  /// 更新是否在打开作品时恢复上一次退出时打开的标签页
  Future<bool> updateRestoreTabsOnOpenWork(bool value) async {
    final newSettings = _settings.copyWith(restoreTabsOnOpenWork: value);
    return updateSettings(newSettings);
  }

  // ================= 更新设置相关 =================

  /// 获取是否在启动时自动检查更新
  bool get autoCheckUpdate => _settings.autoCheckUpdate;

  /// 更新是否在启动时自动检查更新
  Future<bool> updateAutoCheckUpdate(bool value) async {
    final newSettings = _settings.copyWith(autoCheckUpdate: value);
    return updateSettings(newSettings);
  }

  // ================= 暗色模式封面变暗设置相关 =================
  
  /// 获取暗色模式下是否让封面变暗
  bool get dimCoverInDarkMode => _settings.dimCoverInDarkMode;
  
  /// 更新暗色模式下是否让封面变暗
  Future<bool> updateDimCoverInDarkMode(bool value) async {
    final newSettings = _settings.copyWith(dimCoverInDarkMode: value);
    return updateSettings(newSettings);
  }

  // ================= 应用界面字体设置相关 =================

  /// 获取应用界面字体名称（null 表示跟随系统默认字体）
  String? get appFontFamily => _settings.appFontFamily;

  /// 更新应用界面字体名称
  /// [value] 传入 null 表示跟随系统默认字体
  Future<bool> updateAppFontFamily(String? value) async {
    final newSettings = _settings.copyWith(appFontFamily: value);
    return updateSettings(newSettings);
  }

  /// 获取应用界面字号缩放倍数（1.0 为默认大小）
  double get appFontScale => _settings.appFontScale;

  /// 更新应用界面字号缩放倍数
  /// [value] 缩放倍数，1.0 为默认大小
  Future<bool> updateAppFontScale(double value) async {
    final newSettings = _settings.copyWith(appFontScale: value);
    return updateSettings(newSettings);
  }

  // ================= 布局设置相关（右侧边栏 - 布局设置面板）=================
  
  /// 获取是否显示章节标题
  bool get showChapterTitle => _settings.showChapterTitle;
  
  /// 获取章节标题顶边距
  double get chapterTitleTopMargin => _settings.chapterTitleTopMargin;
  
  /// 获取章节标题字体大小
  double get chapterTitleFontSize => _settings.chapterTitleFontSize;
  
  /// 获取章节标题默认字号（像素）
  double get defaultChapterTitleFontSize => AppSettings.defaults.chapterTitleFontSize;

  /// 获取章节标题字体名称（null 表示系统默认字体）
  ///
  /// 章节标题字体独立于正文字体与界面字体，默认使用系统字体
  String? get chapterTitleFontFamily => _settings.chapterTitleFontFamily;
  
  /// 获取章节标题对齐方式（'center' 居中 / 'left' 向左对齐）
  String get chapterTitleAlignment => _settings.chapterTitleAlignment;
  
  /// 章节标题是否向左对齐（false 表示居中）
  bool get isChapterTitleLeftAligned =>
      _settings.chapterTitleAlignment == AppSettings.chapterTitleAlignLeft;
  
  /// 获取章节标题颜色（亮色主题，为 null 时使用主题默认颜色）
  String? get chapterTitleColorLight => _settings.chapterTitleColorLight;

  /// 获取章节标题颜色（暗色主题，为 null 时使用主题默认颜色）
  String? get chapterTitleColorDark => _settings.chapterTitleColorDark;
  
  /// 获取页面顶边距
  double get topMargin => _settings.topMargin;
  
  /// 获取页面左右边距
  double get horizontalMargin => _settings.horizontalMargin;
  
  /// 获取页面底边距
  double get bottomMargin => _settings.bottomMargin;
  
  /// 获取是否开启纸张模式
  /// 移动端不提供纸张模式，始终返回关闭
  bool get isPageViewEnabled => PlatformCapabilities.isMobile ? false : _settings.isPageViewEnabled;

  /// 获取滚动条是否常驻显示
  bool get scrollbarAlwaysVisible => _settings.scrollbarAlwaysVisible;

  /// 获取编辑器背景色模式（'default' 跟随主题 / 'custom' 自定义）
  String get editorBackgroundMode => _settings.editorBackgroundMode;

  /// 获取编辑器背景色（亮色主题，为 null 时使用主题默认颜色）
  String? get editorBackgroundColorLight => _settings.editorBackgroundColorLight;

  /// 获取编辑器背景色（暗色主题，为 null 时使用主题默认颜色）
  String? get editorBackgroundColorDark => _settings.editorBackgroundColorDark;

  /// 获取纸张模式背景淡化开关
  bool get dimPaperBackground => _settings.dimPaperBackground;

  /// 获取大纲编辑器顶边距
  double get outlineTopMargin => _settings.outlineTopMargin;

  /// 获取大纲编辑器左右边距
  double get outlineHorizontalMargin => _settings.outlineHorizontalMargin;

  /// 获取大纲编辑器底边距
  double get outlineBottomMargin => _settings.outlineBottomMargin;

  /// 获取大纲编辑器节点间距
  double get outlineNodeSpacing => _settings.outlineNodeSpacing;

  /// 获取大纲编辑器页面视图模式
  /// 移动端不提供页面视图设置，始终返回默认模式
  String get outlinePageViewMode => PlatformCapabilities.isMobile ? 'default' : _settings.outlinePageViewMode;

  /// 获取是否显示大纲编辑器底部的快捷键提示
  bool get outlineBottomHintEnabled => _settings.outlineBottomHintEnabled;

  /// 获取是否在大纲编辑器第一个节点上方显示大纲标题
  bool get outlineShowTitle => _settings.outlineShowTitle;

  /// 更新是否显示章节标题
  Future<bool> updateShowChapterTitle(bool value) async {
    final newSettings = _settings.copyWith(showChapterTitle: value);
    return updateSettings(newSettings);
  }
  
  /// 更新章节标题顶边距
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateChapterTitleTopMargin(double value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(chapterTitleTopMargin: value);
    return updateSettings(newSettings, debounce: debounce);
  }

  /// 更新章节标题字体大小
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateChapterTitleFontSize(double value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(chapterTitleFontSize: value);
    return updateSettings(newSettings, debounce: debounce);
  }

  /// 更新章节标题字体名称（传 null 恢复系统默认字体）
  Future<bool> updateChapterTitleFontFamily(String? value) async {
    final newSettings = _settings.copyWith(chapterTitleFontFamily: value);
    return updateSettings(newSettings);
  }

  /// 更新章节标题对齐方式
  /// [leftAligned] true 为向左对齐，false 为居中
  Future<bool> updateChapterTitleAlignment(bool leftAligned) async {
    final newSettings = _settings.copyWith(
      chapterTitleAlignment: leftAligned
          ? AppSettings.chapterTitleAlignLeft
          : AppSettings.chapterTitleAlignCenter,
    );
    return updateSettings(newSettings);
  }
  
  /// 更新章节标题颜色（亮色主题）
  Future<bool> updateChapterTitleColorLight(String? value) async {
    final newSettings = _settings.copyWith(chapterTitleColorLight: value);
    return updateSettings(newSettings);
  }

  /// 更新章节标题颜色（暗色主题）
  Future<bool> updateChapterTitleColorDark(String? value) async {
    final newSettings = _settings.copyWith(chapterTitleColorDark: value);
    return updateSettings(newSettings);
  }
  
  /// 更新页面顶边距
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateTopMargin(double value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(topMargin: value);
    return updateSettings(newSettings, debounce: debounce);
  }

  /// 更新页面左右边距
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateHorizontalMargin(double value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(horizontalMargin: value);
    return updateSettings(newSettings, debounce: debounce);
  }

  /// 更新页面底边距
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateBottomMargin(double value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(bottomMargin: value);
    return updateSettings(newSettings, debounce: debounce);
  }
  
  /// 更新是否开启纸张模式
  Future<bool> updateIsPageViewEnabled(bool value) async {
    final newSettings = _settings.copyWith(isPageViewEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新滚动条是否常驻显示
  Future<bool> updateScrollbarAlwaysVisible(bool value) async {
    final newSettings = _settings.copyWith(scrollbarAlwaysVisible: value);
    return updateSettings(newSettings);
  }

  /// 更新编辑器背景色模式（'default' 跟随主题 / 'custom' 自定义）
  Future<bool> updateEditorBackgroundMode(String value) async {
    final newSettings = _settings.copyWith(editorBackgroundMode: value);
    return updateSettings(newSettings);
  }

  /// 更新编辑器背景色（亮色主题）
  Future<bool> updateEditorBackgroundColorLight(String? value) async {
    final newSettings = _settings.copyWith(editorBackgroundColorLight: value);
    return updateSettings(newSettings);
  }

  /// 更新编辑器背景色（暗色主题）
  Future<bool> updateEditorBackgroundColorDark(String? value) async {
    final newSettings = _settings.copyWith(editorBackgroundColorDark: value);
    return updateSettings(newSettings);
  }

  /// 更新纸张模式背景淡化开关
  Future<bool> updateDimPaperBackground(bool value) async {
    final newSettings = _settings.copyWith(dimPaperBackground: value);
    return updateSettings(newSettings);
  }

  /// 更新大纲编辑器顶边距
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateOutlineTopMargin(double value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(outlineTopMargin: value);
    return updateSettings(newSettings, debounce: debounce);
  }

  /// 更新大纲编辑器左右边距
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateOutlineHorizontalMargin(double value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(outlineHorizontalMargin: value);
    return updateSettings(newSettings, debounce: debounce);
  }

  /// 更新大纲编辑器底边距
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateOutlineBottomMargin(double value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(outlineBottomMargin: value);
    return updateSettings(newSettings, debounce: debounce);
  }

  /// 更新大纲编辑器节点间距
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateOutlineNodeSpacing(double value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(outlineNodeSpacing: value);
    return updateSettings(newSettings, debounce: debounce);
  }

  /// 更新大纲编辑器页面视图模式
  Future<bool> updateOutlinePageViewMode(String value) async {
    final newSettings = _settings.copyWith(outlinePageViewMode: value);
    return updateSettings(newSettings);
  }

  /// 更新是否显示大纲编辑器底部的快捷键提示
  Future<bool> updateOutlineBottomHintEnabled(bool value) async {
    final newSettings = _settings.copyWith(outlineBottomHintEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新是否在大纲编辑器第一个节点上方显示大纲标题
  Future<bool> updateOutlineShowTitle(bool value) async {
    final newSettings = _settings.copyWith(outlineShowTitle: value);
    return updateSettings(newSettings);
  }

  // ================= 排版设置相关（右侧边栏 - 排版设置面板）=================
  
  /// 获取字间距
  double get letterSpacing => _settings.letterSpacing;
  
  /// 获取行间距倍数
  double get lineHeight => _settings.lineHeight;
  
  /// 获取是否开启首行缩进
  bool get isFirstLineIndentEnabled => _settings.isFirstLineIndentEnabled;

  /// 获取是否用全角空格实现首行缩进
  bool get isFullWidthSpaceIndentEnabled => _settings.isFullWidthSpaceIndentEnabled;

  /// 获取是否开启自动空行
  bool get autoLineBreak => _settings.autoLineBreak;
  
  /// 获取是否显示行间线条
  bool get showLineSeparator => _settings.showLineSeparator;

  /// 获取行间线样式（'solid' 实线 / 'dashed' 虚线）
  String get lineSeparatorStyle => _settings.lineSeparatorStyle;

  /// 获取行间线不透明度（0.0 ~ 1.0）
  double get lineSeparatorOpacity => _settings.lineSeparatorOpacity;
  
  // ================= 字体设置相关 =================
  
  /// 获取字体名称
  String get fontFamily => _settings.fontFamily;
  
  /// 获取字体大小
  double get fontSize => _settings.fontSize;
  
  /// 获取正文默认字号（像素）
  double get defaultFontSize => AppSettings.defaults.fontSize;
  
  /// 获取是否加粗
  bool get isBold => _settings.isBold;
  
  /// 获取是否斜体
  bool get isItalic => _settings.isItalic;
  
  /// 获取是否下划线
  bool get isUnderline => _settings.isUnderline;
  
  /// 获取正文字体颜色（亮色主题，为 null 时使用主题默认颜色）
  String? get fontColorLight => _settings.fontColorLight;

  /// 获取正文字体颜色（暗色主题，为 null 时使用主题默认颜色）
  String? get fontColorDark => _settings.fontColorDark;

  /// 获取大纲编辑器字体名称
  String get outlineFontFamily => _settings.outlineFontFamily;

  /// 获取大纲编辑器字体大小
  double get outlineFontSize => _settings.outlineFontSize;

  /// 获取大纲编辑器默认字号（像素）
  double get defaultOutlineFontSize => AppSettings.defaults.outlineFontSize;

  /// 获取大纲标题字体名称（null 表示跟随大纲字体）
  String? get outlineTitleFontFamily => _settings.outlineTitleFontFamily;

  /// 获取大纲标题字体大小
  double get outlineTitleFontSize => _settings.outlineTitleFontSize;

  /// 获取大纲标题默认字号（像素）
  double get defaultOutlineTitleFontSize => AppSettings.defaults.outlineTitleFontSize;

  /// 大纲标题是否为向左对齐
  bool get isOutlineTitleLeftAligned =>
      _settings.outlineTitleAlignment == AppSettings.outlineTitleAlignLeft;

  /// 获取大纲标题颜色（亮色主题，为 null 时跟随主题默认颜色）
  String? get outlineTitleColorLight => _settings.outlineTitleColorLight;

  /// 获取大纲标题颜色（暗色主题，为 null 时跟随主题默认颜色）
  String? get outlineTitleColorDark => _settings.outlineTitleColorDark;

  /// 获取大纲正文字体颜色（亮色主题，为 null 时跟随主题默认颜色）
  String? get outlineContentColorLight => _settings.outlineContentColorLight;

  /// 获取大纲正文字体颜色（暗色主题，为 null 时跟随主题默认颜色）
  String? get outlineContentColorDark => _settings.outlineContentColorDark;

  // ================= 其他设置 =================

  /// 获取是否开启自动保存
  /// 移动端没有保存按钮，自动保存必须常开，始终返回开启
  bool get autoSaveEnabled => PlatformCapabilities.isMobile ? true : _settings.autoSaveEnabled;

  /// 获取是否开启自动备份
  bool get autoBackupEnabled => _settings.autoBackupEnabled;

  /// 获取备份间隔（单位：分钟）
  int get backupInterval => _settings.backupInterval;

  /// 获取历史记录保存天数
  /// 1~365 表示保留对应天数，0 表示永久保留
  int get historyRetentionDays => _settings.historyRetentionDays;

  /// 获取打开文件时光标定位模式
  String get openChapterCursorMode => _settings.openChapterCursorMode;

  /// 获取静态光标是否启用（true 表示光标不闪烁）
  bool get staticCursorEnabled => _settings.staticCursorEnabled;

  /// 获取呼吸式顺滑光标是否启用（true 表示光标做淡入淡出的呼吸动画）
  bool get breathingCursorEnabled => _settings.breathingCursorEnabled;

  /// 获取字数浮窗是否显示本章字数
  bool get wordCountFloatingWordCountEnabled => _settings.wordCountFloatingWordCountEnabled;

  /// 获取光标颜色（亮色主题，null 表示跟随主题主色）
  String? get cursorColorLight => _settings.cursorColorLight;

  /// 获取光标颜色（暗色主题，null 表示跟随主题主色）
  String? get cursorColorDark => _settings.cursorColorDark;

  /// 获取底部信息栏是否显示
  bool get bottomStatusBarEnabled => _settings.bottomStatusBarEnabled;

  /// 获取预览模式是否启用
  /// 移动端不提供预览模式，始终返回关闭
  bool get previewModeEnabled => PlatformCapabilities.isMobile ? false : _settings.previewModeEnabled;

  /// 获取移动端快捷输入栏是否启用
  bool get quickInputBarEnabled => _settings.quickInputBarEnabled;

  /// 获取标点符号自动补全是否启用
  bool get punctuationAutoCompleteEnabled => _settings.punctuationAutoCompleteEnabled;

  /// 获取成对符号回车跳出是否启用
  bool get pairedSymbolEnterJumpEnabled => _settings.pairedSymbolEnterJumpEnabled;

  /// 获取快捷输入栏右侧操作区左侧图标的动作
  ///
  /// 关键词高亮开关已下线（改为常驻开启），旧配置中残留该项时回退到默认动作，
  /// 避免快捷输入栏出现空白图标位。
  QuickInputAction get quickInputBarLeftAction => _normalizeQuickInputAction(
        QuickInputAction.fromId(
          _settings.quickInputBarLeftAction,
          fallback: QuickInputAction.defaultLeft,
        ),
        fallback: QuickInputAction.defaultLeft,
      );

  /// 获取快捷输入栏右侧操作区右侧图标的动作
  QuickInputAction get quickInputBarRightAction => _normalizeQuickInputAction(
        QuickInputAction.fromId(
          _settings.quickInputBarRightAction,
          fallback: QuickInputAction.defaultRight,
        ),
        fallback: QuickInputAction.defaultRight,
      );

  /// 获取快捷输入栏右侧操作区第三个图标的动作
  ///
  /// 默认「无」，即右侧操作区只显示两个图标；设为具体动作后多出一个图标位
  QuickInputAction get quickInputBarThirdAction => _normalizeQuickInputAction(
        QuickInputAction.fromId(
          _settings.quickInputBarThirdAction,
          fallback: QuickInputAction.none,
        ),
        fallback: QuickInputAction.none,
      );

  /// 大纲编辑器底部快捷输入（自定义符号栏）面板是否默认展开
  bool get outlineQuickInputPanelOpen => _settings.outlineQuickInputPanelOpen;

  /// 过滤已下线的快捷动作
  QuickInputAction _normalizeQuickInputAction(
    QuickInputAction action, {
    required QuickInputAction fallback,
  }) {
    if (action == QuickInputAction.keywordToggle) return fallback;
    return action;
  }

  /// 获取快捷输入栏当前的符号列表
  /// 用户未自定义或自定义文本中无有效符号时，为内置默认列表
  List<PunctuationSymbol> get quickInputSymbols => _quickInputSymbols;

  /// 获取快捷短语列表
  List<QuickPhrase> get quickPhrases => _settings.quickPhrases;

  /// 获取正文自动替换规则
  List<TextReplacementRule> get textReplacementRules => _settings.textReplacementRules;

  /// 正文自动替换总开关（默认关闭）
  bool get autoReplaceEnabled => _settings.autoReplaceEnabled;

  /// 获取快捷输入栏符号列表的可编辑文本
  /// 用户未自定义时返回内置默认列表格式化后的文本
  String get quickInputSymbolsText =>
      _settings.quickInputSymbolsText ??
      PunctuationSymbols.formatSymbolList(PunctuationSymbols.quickInputKeys);

  /// 获取字数浮窗是否启用
  /// 移动端专属功能，桌面端始终返回关闭
  bool get wordCountFloatingEnabled =>
      PlatformCapabilities.isMobile && _settings.wordCountFloatingEnabled;

  /// 获取字数浮窗显示位置
  String get wordCountFloatingPosition => _settings.wordCountFloatingPosition;

  /// 获取字数浮窗是否显示码字速度
  bool get wordCountFloatingSpeedEnabled => _settings.wordCountFloatingSpeedEnabled;

  /// 获取字数浮窗显示样式
  WordCountFloatingMode get wordCountFloatingMode => _settings.wordCountFloatingMode;

  /// 更新字间距
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateLetterSpacing(double value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(letterSpacing: value);
    return updateSettings(newSettings, debounce: debounce);
  }

  /// 更新行间距倍数
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateLineHeight(double value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(lineHeight: value);
    return updateSettings(newSettings, debounce: debounce);
  }
  
  // ================= 字体设置相关 =================
  
  /// 更新字体名称
  Future<bool> updateFontFamily(String value) async {
    final newSettings = _settings.copyWith(fontFamily: value);
    return updateSettings(newSettings);
  }
  
  /// 更新字体大小
  Future<bool> updateFontSize(double value) async {
    final newSettings = _settings.copyWith(fontSize: value);
    return updateSettings(newSettings);
  }
  
  /// 更新是否加粗
  Future<bool> updateIsBold(bool value) async {
    final newSettings = _settings.copyWith(isBold: value);
    return updateSettings(newSettings);
  }
  
  /// 更新是否斜体
  Future<bool> updateIsItalic(bool value) async {
    final newSettings = _settings.copyWith(isItalic: value);
    return updateSettings(newSettings);
  }
  
  /// 更新是否下划线
  Future<bool> updateIsUnderline(bool value) async {
    final newSettings = _settings.copyWith(isUnderline: value);
    return updateSettings(newSettings);
  }
  
  /// 更新正文字体颜色（亮色主题）
  Future<bool> updateFontColorLight(String? value) async {
    final newSettings = _settings.copyWith(fontColorLight: value);
    return updateSettings(newSettings);
  }

  /// 更新正文字体颜色（暗色主题）
  Future<bool> updateFontColorDark(String? value) async {
    final newSettings = _settings.copyWith(fontColorDark: value);
    return updateSettings(newSettings);
  }

  /// 更新大纲编辑器字体名称
  Future<bool> updateOutlineFontFamily(String value) async {
    final newSettings = _settings.copyWith(outlineFontFamily: value);
    return updateSettings(newSettings);
  }

  /// 更新大纲编辑器字体大小
  Future<bool> updateOutlineFontSize(double value) async {
    final newSettings = _settings.copyWith(outlineFontSize: value);
    return updateSettings(newSettings);
  }

  /// 更新大纲标题字体名称（传 null 表示跟随大纲字体）
  Future<bool> updateOutlineTitleFontFamily(String? value) async {
    final newSettings = _settings.copyWith(outlineTitleFontFamily: value);
    return updateSettings(newSettings);
  }

  /// 更新大纲标题字体大小
  Future<bool> updateOutlineTitleFontSize(double value) async {
    final newSettings = _settings.copyWith(outlineTitleFontSize: value);
    return updateSettings(newSettings);
  }

  /// 更新大纲标题对齐方式
  Future<bool> updateOutlineTitleAlignment(bool isLeftAligned) async {
    final newSettings = _settings.copyWith(
      outlineTitleAlignment: isLeftAligned
          ? AppSettings.outlineTitleAlignLeft
          : AppSettings.outlineTitleAlignCenter,
    );
    return updateSettings(newSettings);
  }

  /// 更新大纲标题颜色（亮色主题）
  Future<bool> updateOutlineTitleColorLight(String colorHex) async {
    final newSettings = _settings.copyWith(outlineTitleColorLight: colorHex);
    return updateSettings(newSettings);
  }

  /// 更新大纲标题颜色（暗色主题）
  Future<bool> updateOutlineTitleColorDark(String colorHex) async {
    final newSettings = _settings.copyWith(outlineTitleColorDark: colorHex);
    return updateSettings(newSettings);
  }

  /// 更新大纲正文字体颜色（亮色主题）
  Future<bool> updateOutlineContentColorLight(String colorHex) async {
    final newSettings = _settings.copyWith(outlineContentColorLight: colorHex);
    return updateSettings(newSettings);
  }

  /// 更新大纲正文字体颜色（暗色主题）
  Future<bool> updateOutlineContentColorDark(String colorHex) async {
    final newSettings = _settings.copyWith(outlineContentColorDark: colorHex);
    return updateSettings(newSettings);
  }

  /// 校验字体设置引用的字体在本机是否可用
  ///
  /// 设置可能随云同步写入本机不存在的字体，届时将其恢复为默认字体，
  /// 避免界面与编辑器持续引用不可用的字体。应在字体服务加载完成后调用
  Future<void> validateFontAvailability() async {
    final fonts = FontService();
    final defaultFont = _getSystemDefaultFontFamily();
    var newSettings = _settings;

    // 编辑器正文字体：本机不存在时恢复为系统默认字体
    if (!fonts.isFontFamilyAvailable(newSettings.fontFamily)) {
      newSettings = newSettings.copyWith(fontFamily: defaultFont);
    }

    // 大纲编辑器字体：本机不存在时恢复为系统默认字体
    if (!fonts.isFontFamilyAvailable(newSettings.outlineFontFamily)) {
      newSettings = newSettings.copyWith(outlineFontFamily: defaultFont);
    }

    // 应用界面字体：本机不存在时清除，回退为跟随系统默认字体
    final appFontFamily = newSettings.appFontFamily;
    if (appFontFamily != null && !fonts.isFontFamilyAvailable(appFontFamily)) {
      newSettings = newSettings.copyWith(appFontFamily: null);
    }

    // 设置未发生变化时 updateSettings 内部会自行跳过保存
    await updateSettings(newSettings);
  }

  
  /// 更新是否开启首行缩进
  Future<bool> updateIsFirstLineIndentEnabled(bool value) async {
    final newSettings = _settings.copyWith(isFirstLineIndentEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新是否用全角空格实现首行缩进
  Future<bool> updateIsFullWidthSpaceIndentEnabled(bool value) async {
    final newSettings = _settings.copyWith(isFullWidthSpaceIndentEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新是否开启自动空行
  Future<bool> updateAutoLineBreak(bool value) async {
    final newSettings = _settings.copyWith(autoLineBreak: value);
    return updateSettings(newSettings);
  }
  
  /// 更新是否显示行间线条
  Future<bool> updateShowLineSeparator(bool value) async {
    final newSettings = _settings.copyWith(showLineSeparator: value);
    return updateSettings(newSettings);
  }

  /// 更新行间线样式
  Future<bool> updateLineSeparatorStyle(String value) async {
    final newSettings = _settings.copyWith(lineSeparatorStyle: value);
    return updateSettings(newSettings);
  }

  /// 更新行间线不透明度
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateLineSeparatorOpacity(double value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(lineSeparatorOpacity: value);
    return updateSettings(newSettings, debounce: debounce);
  }

  /// 获取是否开启对话高亮
  bool get dialogueHighlightEnabled => _settings.dialogueHighlightEnabled;

  /// 获取对话高亮颜色（亮色主题）
  String? get dialogueHighlightColorLight => _settings.dialogueHighlightColorLight;

  /// 获取对话高亮颜色（暗色主题）
  String? get dialogueHighlightColorDark => _settings.dialogueHighlightColorDark;

  /// 更新是否开启对话高亮
  Future<bool> updateDialogueHighlightEnabled(bool value) async {
    final newSettings = _settings.copyWith(dialogueHighlightEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新对话高亮颜色（亮色主题）
  Future<bool> updateDialogueHighlightColorLight(String? value) async {
    final newSettings = _settings.copyWith(dialogueHighlightColorLight: value);
    return updateSettings(newSettings);
  }

  /// 更新对话高亮颜色（暗色主题）
  Future<bool> updateDialogueHighlightColorDark(String? value) async {
    final newSettings = _settings.copyWith(dialogueHighlightColorDark: value);
    return updateSettings(newSettings);
  }

  // ================= 其他设置更新方法 =================

  /// 更新是否开启自动保存
  Future<bool> updateAutoSaveEnabled(bool value) async {
    final newSettings = _settings.copyWith(autoSaveEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新是否开启自动备份
  Future<bool> updateAutoBackupEnabled(bool value) async {
    final newSettings = _settings.copyWith(autoBackupEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新备份间隔（单位：分钟）
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateBackupInterval(int value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(backupInterval: value);
    return updateSettings(newSettings, debounce: debounce);
  }

  /// 更新历史记录保存天数
  /// 1~365 表示保留对应天数，0 表示永久保留
  /// [debounce] 是否使用防抖方式保存
  Future<bool> updateHistoryRetentionDays(int value, {bool debounce = false}) async {
    final newSettings = _settings.copyWith(historyRetentionDays: value);
    return updateSettings(newSettings, debounce: debounce);
  }

  /// 更新打开文件时光标定位模式
  Future<bool> updateOpenChapterCursorMode(String value) async {
    final newSettings = _settings.copyWith(openChapterCursorMode: value);
    return updateSettings(newSettings);
  }

  /// 更新静态光标开关
  ///
  /// 静态光标与呼吸式光标互斥，开启静态光标会同时关闭呼吸式光标
  Future<bool> updateStaticCursorEnabled(bool value) async {
    final newSettings = _settings.copyWith(
      staticCursorEnabled: value,
      breathingCursorEnabled: value ? false : _settings.breathingCursorEnabled,
    );
    return updateSettings(newSettings);
  }

  /// 更新呼吸式顺滑光标开关
  ///
  /// 呼吸式光标与静态光标互斥，开启呼吸式光标会同时关闭静态光标
  Future<bool> updateBreathingCursorEnabled(bool value) async {
    final newSettings = _settings.copyWith(
      breathingCursorEnabled: value,
      staticCursorEnabled: value ? false : _settings.staticCursorEnabled,
    );
    return updateSettings(newSettings);
  }

  /// 更新字数浮窗的本章字数显示开关
  Future<bool> updateWordCountFloatingWordCountEnabled(bool value) async {
    final newSettings = _settings.copyWith(wordCountFloatingWordCountEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新光标颜色（亮色主题）
  ///
  /// [colorHex] 为 null 表示恢复跟随主题主色
  Future<bool> updateCursorColorLight(String? colorHex) async {
    final newSettings = _settings.copyWith(cursorColorLight: colorHex);
    return updateSettings(newSettings);
  }

  /// 更新光标颜色（暗色主题）
  ///
  /// [colorHex] 为 null 表示恢复跟随主题主色
  Future<bool> updateCursorColorDark(String? colorHex) async {
    final newSettings = _settings.copyWith(cursorColorDark: colorHex);
    return updateSettings(newSettings);
  }

  /// 更新底部信息栏开关
  Future<bool> updateBottomStatusBarEnabled(bool value) async {
    final newSettings = _settings.copyWith(bottomStatusBarEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新预览模式开关
  Future<bool> updatePreviewModeEnabled(bool value) async {
    final newSettings = _settings.copyWith(previewModeEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新移动端快捷输入栏开关
  Future<bool> updateQuickInputBarEnabled(bool value) async {
    final newSettings = _settings.copyWith(quickInputBarEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新标点符号自动补全开关
  Future<bool> updatePunctuationAutoCompleteEnabled(bool value) async {
    final newSettings = _settings.copyWith(punctuationAutoCompleteEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新成对符号回车跳出开关
  Future<bool> updatePairedSymbolEnterJumpEnabled(bool value) async {
    final newSettings = _settings.copyWith(pairedSymbolEnterJumpEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新正文自动替换总开关
  Future<bool> updateAutoReplaceEnabled(bool value) async {
    final newSettings = _settings.copyWith(autoReplaceEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新快捷输入栏右侧操作区图标的动作
  ///
  /// [third] 为空时保留原有的第三个图标设置，避免两图标的调用方误清空第三位
  Future<bool> updateQuickInputBarActions(
    QuickInputAction left,
    QuickInputAction right, [
    QuickInputAction? third,
  ]) async {
    final newSettings = _settings.copyWith(
      quickInputBarLeftAction: left.id,
      quickInputBarRightAction: right.id,
      quickInputBarThirdAction: third?.id,
    );
    return updateSettings(newSettings);
  }

  /// 更新大纲编辑器底部快捷输入面板是否默认展开
  Future<bool> updateOutlineQuickInputPanelOpen(bool value) async {
    final newSettings = _settings.copyWith(outlineQuickInputPanelOpen: value);
    return updateSettings(newSettings);
  }

  /// 更新快捷输入栏符号列表
  ///
  /// [value] 为可编辑文本；传入 null 或空白文本表示恢复内置默认列表
  Future<bool> updateQuickInputSymbolsText(String? value) async {
    final String? text = value?.trim();
    final newSettings = _settings.copyWith(
      quickInputSymbolsText: (text == null || text.isEmpty) ? null : text,
    );
    return updateSettings(newSettings);
  }

  /// 更新快捷短语列表
  Future<bool> updateQuickPhrases(List<QuickPhrase> phrases) async {
    final newSettings = _settings.copyWith(quickPhrases: phrases);
    return updateSettings(newSettings);
  }

  /// 更新正文自动替换规则
  Future<bool> updateTextReplacementRules(List<TextReplacementRule> rules) async {
    final newSettings = _settings.copyWith(textReplacementRules: rules);
    return updateSettings(newSettings);
  }

  /// 更新字数浮窗开关
  Future<bool> updateWordCountFloatingEnabled(bool value) async {
    final newSettings = _settings.copyWith(wordCountFloatingEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新字数浮窗显示位置
  Future<bool> updateWordCountFloatingPosition(String value) async {
    final newSettings = _settings.copyWith(wordCountFloatingPosition: value);
    return updateSettings(newSettings);
  }

  /// 更新字数浮窗码字速度开关
  Future<bool> updateWordCountFloatingSpeedEnabled(bool value) async {
    final newSettings = _settings.copyWith(wordCountFloatingSpeedEnabled: value);
    return updateSettings(newSettings);
  }

  /// 更新字数浮窗显示样式
  Future<bool> updateWordCountFloatingMode(WordCountFloatingMode value) async {
    final newSettings = _settings.copyWith(wordCountFloatingMode: value);
    return updateSettings(newSettings);
  }

  // ================= 码字统计设置相关 =================

  /// 码字统计是否包含粘贴字数
  bool get statsIncludePasteWords => _settings.statsIncludePasteWords;

  /// 更新码字统计是否包含粘贴字数
  Future<bool> updateStatsIncludePasteWords(bool value) async {
    final newSettings = _settings.copyWith(statsIncludePasteWords: value);
    return updateSettings(newSettings);
  }

  /// 码字统计是否包含设定字数
  bool get statsIncludeSettingWords => _settings.statsIncludeSettingWords;

  /// 更新码字统计是否包含设定字数
  Future<bool> updateStatsIncludeSettingWords(bool value) async {
    final newSettings = _settings.copyWith(statsIncludeSettingWords: value);
    return updateSettings(newSettings);
  }

  /// 码字统计是否按章节记录今日字数
  bool get statsChapterWordCountEnabled => _settings.statsChapterWordCountEnabled;

  /// 更新是否按章节记录今日字数
  Future<bool> updateStatsChapterWordCountEnabled(bool value) async {
    final newSettings = _settings.copyWith(statsChapterWordCountEnabled: value);
    return updateSettings(newSettings);
  }

  /// 空闲判定阈值（秒）
  int get statsIdleThresholdSeconds => _settings.statsIdleThresholdSeconds;

  /// 更新空闲判定阈值（秒）
  Future<bool> updateStatsIdleThresholdSeconds(int value) async {
    final newSettings = _settings.copyWith(statsIdleThresholdSeconds: value);
    return updateSettings(newSettings);
  }

  // ================= 重置布局和排版设置 =================
  
  /// 重置布局设置为默认值
  /// 从当前平台的默认设置获取默认值，保留其他设置不变
  Future<bool> resetLayoutSettings() async {
    final newSettings = _settings.copyWith(
      showChapterTitle: AppSettings.defaults.showChapterTitle,
      chapterTitleTopMargin: AppSettings.defaults.chapterTitleTopMargin,
      topMargin: AppSettings.defaults.topMargin,
      horizontalMargin: AppSettings.defaults.horizontalMargin,
      bottomMargin: AppSettings.defaults.bottomMargin,
      isPageViewEnabled: AppSettings.defaults.isPageViewEnabled,
      scrollbarAlwaysVisible: AppSettings.defaults.scrollbarAlwaysVisible,
      // 编辑器背景设置
      editorBackgroundMode: AppSettings.defaults.editorBackgroundMode,
      editorBackgroundColorLight: AppSettings.defaults.editorBackgroundColorLight,
      editorBackgroundColorDark: AppSettings.defaults.editorBackgroundColorDark,
      dimPaperBackground: AppSettings.defaults.dimPaperBackground,
      outlineTopMargin: _platformDefaults.outlineTopMargin,
      outlineHorizontalMargin: _platformDefaults.outlineHorizontalMargin,
      outlineBottomMargin: _platformDefaults.outlineBottomMargin,
      outlineNodeSpacing: _platformDefaults.outlineNodeSpacing,
      outlinePageViewMode: _platformDefaults.outlinePageViewMode,
      outlineBottomHintEnabled: _platformDefaults.outlineBottomHintEnabled,
      outlineShowTitle: _platformDefaults.outlineShowTitle,
    );
    return updateSettings(newSettings);
  }

  /// 重置章节标题格式设置为默认值
  Future<bool> resetChapterTitleFormatSettings() async {
    final newSettings = _settings.copyWith(
      chapterTitleFontSize: AppSettings.defaults.chapterTitleFontSize,
      chapterTitleFontFamily: AppSettings.defaults.chapterTitleFontFamily,
      chapterTitleAlignment: AppSettings.defaults.chapterTitleAlignment,
      chapterTitleColorLight: AppSettings.defaults.chapterTitleColorLight,
      chapterTitleColorDark: AppSettings.defaults.chapterTitleColorDark,
    );
    return updateSettings(newSettings);
  }
  
  /// 重置排版设置为默认值
  /// 从 AppSettings.defaults 获取默认值，保留其他设置不变
  Future<bool> resetTypesetSettings() async {
    final newSettings = _settings.copyWith(
      letterSpacing: AppSettings.defaults.letterSpacing,
      lineHeight: AppSettings.defaults.lineHeight,
      isFirstLineIndentEnabled: AppSettings.defaults.isFirstLineIndentEnabled,
      isFullWidthSpaceIndentEnabled: AppSettings.defaults.isFullWidthSpaceIndentEnabled,
      autoLineBreak: AppSettings.defaults.autoLineBreak,
      showLineSeparator: AppSettings.defaults.showLineSeparator,
      lineSeparatorStyle: AppSettings.defaults.lineSeparatorStyle,
      lineSeparatorOpacity: AppSettings.defaults.lineSeparatorOpacity,
      dialogueHighlightEnabled: AppSettings.defaults.dialogueHighlightEnabled,
      dialogueHighlightColorLight: AppSettings.defaults.dialogueHighlightColorLight,
      dialogueHighlightColorDark: AppSettings.defaults.dialogueHighlightColorDark,
    );
    return updateSettings(newSettings);
  }

  /// 重置其他设置为默认值
  /// 从 AppSettings.defaults 获取默认值，保留其他设置不变
  Future<bool> resetOtherSettings() async {
    final newSettings = _settings.copyWith(
      autoSaveEnabled: AppSettings.defaults.autoSaveEnabled,
      autoBackupEnabled: AppSettings.defaults.autoBackupEnabled,
      backupInterval: AppSettings.defaults.backupInterval,
      historyRetentionDays: AppSettings.defaults.historyRetentionDays,
      openChapterCursorMode: AppSettings.defaults.openChapterCursorMode,
      quickInputBarEnabled: AppSettings.defaults.quickInputBarEnabled,
      punctuationAutoCompleteEnabled: AppSettings.defaults.punctuationAutoCompleteEnabled,
      pairedSymbolEnterJumpEnabled: AppSettings.defaults.pairedSymbolEnterJumpEnabled,
      quickInputBarLeftAction: AppSettings.defaults.quickInputBarLeftAction,
      quickInputBarRightAction: AppSettings.defaults.quickInputBarRightAction,
      quickInputBarThirdAction: AppSettings.defaults.quickInputBarThirdAction,
      outlineQuickInputPanelOpen: AppSettings.defaults.outlineQuickInputPanelOpen,
      quickInputSymbolsText: AppSettings.defaults.quickInputSymbolsText,
      quickPhrases: AppSettings.defaults.quickPhrases,
      textReplacementRules: AppSettings.defaults.textReplacementRules,
      autoReplaceEnabled: AppSettings.defaults.autoReplaceEnabled,
      wordCountFloatingEnabled: AppSettings.defaults.wordCountFloatingEnabled,
      wordCountFloatingPosition: AppSettings.defaults.wordCountFloatingPosition,
      wordCountFloatingSpeedEnabled: AppSettings.defaults.wordCountFloatingSpeedEnabled,
      wordCountFloatingMode: AppSettings.defaults.wordCountFloatingMode,
    );
    return updateSettings(newSettings);
  }

  /// 重置备份设置为默认值
  /// 从 AppSettings.defaults 获取默认值，保留其他设置不变
  Future<bool> resetBackupSettings() async {
    final newSettings = _settings.copyWith(
      autoBackupEnabled: AppSettings.defaults.autoBackupEnabled,
      backupInterval: AppSettings.defaults.backupInterval,
      historyRetentionDays: AppSettings.defaults.historyRetentionDays,
    );
    return updateSettings(newSettings);
  }

  // ================= 通用设置更新方法 =================

  /// 批量更新设置
  ///
  /// [newSettings] 新的设置对象
  /// [debounce] 是否使用防抖方式保存，适用于滑块拖动等连续操作场景
  /// 返回是否保存成功
  Future<bool> updateSettings(AppSettings newSettings, {bool debounce = false}) async {
    if (newSettings == _settings) {
      debugPrint('设置未变化，跳过保存');
      return true;
    }

    _settings = newSettings;
    _syncQuickInputSymbols();

    if (debounce) {
      // 防抖模式：立即通知监听器以更新 UI，延迟写入文件以避免频繁 IO
      notifyListeners();
      _scheduleDebouncedSave();
      return true;
    }

    // 立即模式：取消可能存在的防抖任务，直接写入文件
    _cancelDebouncedSave();
    final success = await _saveSettings();

    if (success) {
      notifyListeners();
      // 配置文件已更新，交由云同步服务安排一次同步
      CloudSyncService.instance.notifyLocalChange();
    }

    return success;
  }

  /// 调度防抖保存任务
  /// 在延迟时间到达后执行一次文件写入，期间若再次调用会重新计时
  void _scheduleDebouncedSave() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(
      const Duration(milliseconds: _saveDebounceDelay),
      () async {
        _saveDebounceTimer = null;
        final success = await _saveSettings();
        if (success) {
          // 配置文件已更新，交由云同步服务安排一次同步
          CloudSyncService.instance.notifyLocalChange();
        }
      },
    );
  }

  /// 取消待执行的防抖保存任务
  void _cancelDebouncedSave() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
  }
  
  /// 重置所有设置为默认值
  Future<bool> resetToDefault() async {
    _settings = _platformDefaults;
    _syncQuickInputSymbols();
    final success = await _saveSettings();
    
    if (success) {
      notifyListeners();
    }
    
    return success;
  }

  // ================= 工具方法 =================
  
  /// 获取配置目录路径
  Future<String?> getConfigDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_configPathKey);
  }
  
  /// 导出配置到指定路径
  Future<bool> exportConfig(String targetPath) async {
    if (_configFilePath == null) return false;
    
    try {
      final sourceFile = File(_configFilePath!);
      if (!await sourceFile.exists()) return false;
      
      await sourceFile.copy(targetPath);
      debugPrint('配置已导出到: $targetPath');
      return true;
    } catch (e) {
      debugPrint('导出配置失败: $e');
      return false;
    }
  }
  
  /// 从指定路径导入配置
  Future<bool> importConfig(String sourcePath) async {
    if (_configFilePath == null) return false;
    
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) return false;
      
      final content = await sourceFile.readAsString();
      final jsonMap = json.decode(content) as Map<String, dynamic>;
      _settings = AppSettings.fromJson(jsonMap);
      _syncQuickInputSymbols();
      
      await _saveSettings();
      notifyListeners();
      
      debugPrint('配置已从 $sourcePath 导入');
      return true;
    } catch (e) {
      debugPrint('导入配置失败: $e');
      return false;
    }
  }
}
