part of '../workspace_provider.dart';

/// 工作台 Provider 共享状态基类
///
/// 提供跨 Mixin 共享的依赖（Isar 实例、dispose 标志、窗口通信字段、
/// 书架刷新通知、文件夹与迁移服务、标签页列表），并声明 [BookDataMixin]
/// 与 [EditorMixin] 互相调用的协调方法。
abstract class WorkspaceStateBase extends ChangeNotifier {
  // ================= 共享状态 =================

  /// 是否已被释放（防止在 dispose 后继续调用方法导致报错）
  bool _isDisposed = false;

  /// Isar 数据库实例（initialize 中赋值）
  late Isar _isar;

  /// 是否已初始化（整体初始化完成标志，在 initialize 末尾置 true）
  bool _isInitialized = false;

  /// 是否已初始化
  bool get isInitialized => _isInitialized;

  // ================= 窗口通信与书架刷新 =================

  /// 主窗口ID（用于向主窗口发送消息）
  String? _mainWindowId;

  /// 同窗口模式下的书籍保存回调（保存章节后通知书架刷新）
  VoidCallback? _onBookSaved;

  /// 通知本地内容发生了持久化变化
  ///
  /// 在书籍内容发生持久化变化（保存章节、删除章节、删除设定项等）后调用，
  /// 既用于刷新书架的最近编辑与字数显示，也让云同步服务按需安排一次同步。
  /// 独立窗口模式下通过 IPC 通知主窗口；同窗口模式下直接调用书架刷新回调。
  ///
  /// [contentChanged] 为 false 表示只是统计数据（码字时长等）落库，
  /// 正文并未变化：此时仍需刷新书架，但不应触发一次云同步
  void _notifyBookshelfRefresh({bool contentChanged = true}) {
    if (_isDisposed) return;

    // 内容已经落盘，交由云同步服务判断是否需要安排同步
    if (contentChanged) CloudSyncService.instance.notifyLocalChange();

    if (_mainWindowId != null) {
      MultiWindowService.instance.notifyBookUpdated(_mainWindowId!);
    } else if (_onBookSaved != null) {
      _onBookSaved!();
    }
  }

  /// 书架刷新节流定时器
  Timer? _bookshelfRefreshTimer;

  /// 节流窗口内是否还有未推送给书架的变更
  bool _bookshelfRefreshDirty = false;

  /// 合并书架刷新请求（trailing 节流）
  ///
  /// 自动保存持续输入时每秒都会落盘一次，若每次都让书架重查数据库并重建列表，
  /// 会在看不见书架的情况下反复白耗主 isolate 的时间片。这里把窗口内的多次
  /// 请求合并为一次；云同步的安排不等节流，仍按每次落盘即时通知。
  /// 退出工作台时由 [flushBookshelfRefresh] 补齐最后一次刷新，保证最近编辑不滞后。
  void _scheduleBookshelfRefresh({bool contentChanged = true}) {
    if (_isDisposed) return;

    // 云同步需要按每次落盘即时判断是否安排同步，不能被 UI 节流拖延
    if (contentChanged) CloudSyncService.instance.notifyLocalChange();

    _bookshelfRefreshDirty = true;
    if (_bookshelfRefreshTimer != null) return;

    _bookshelfRefreshTimer = Timer(const Duration(milliseconds: 1200), () {
      _bookshelfRefreshTimer = null;
      if (_isDisposed || !_bookshelfRefreshDirty) return;
      _bookshelfRefreshDirty = false;
      // 云同步已在上面的每次调用中通知过，这里只负责刷新书架界面
      _notifyBookshelfRefresh(contentChanged: false);
    });
  }

  /// 立即补齐尚未推送的书架刷新（工作台关闭/释放前调用）
  ///
  /// 必须在 [_isDisposed] 置位之前调用，否则会被 [_notifyBookshelfRefresh] 拦掉。
  void flushBookshelfRefresh() {
    _bookshelfRefreshTimer?.cancel();
    _bookshelfRefreshTimer = null;
    if (!_bookshelfRefreshDirty) return;
    _bookshelfRefreshDirty = false;
    _notifyBookshelfRefresh(contentChanged: false);
  }

  // ================= 文件夹与迁移服务 =================

  /// 书籍文件夹路径服务（负责书籍文件夹结构维护与路径计算）
  late final BookFolderService _bookFolderService = BookFolderService();

  /// 分卷数据迁移服务（负责从文件系统迁移分卷到数据库，依赖 Isar 与文件夹路径服务）
  late VolumeMigrationService _volumeMigrationService;

  // ================= 跨域共享的标签页列表 =================

  /// 打开的标签页列表
  ///
  /// 由 [EditorMixin] 负责增删（openTab/closeTab 等），
  /// [BookDataMixin] 在删除章节/设定或重命名时需要读取/更新对应标签页。
  final List<EditorTab> _openedTabs = [];

  // ================= 跨 Mixin 协调接口 =================

  /// 关闭指定 ID 的标签页
  ///
  /// 由 [EditorMixin] 实现，供 [BookDataMixin] 在删除章节/设定时调用。
  void closeTab(String tabId);

  /// 保存章节内容到文件并更新数据库
  ///
  /// 由 [BookDataMixin] 实现，供 [EditorMixin] 在保存标签页时调用。
  /// 返回是否保存成功。
  Future<bool> saveChapterContent(ChapterModel chapter, String content);

  /// 读取章节文件内容
  ///
  /// 由 [BookDataMixin] 实现，供 [EditorMixin] 在全文搜索时调用。
  Future<String> readChapterContent(ChapterModel chapter);

  /// 清除指定设定项在大纲关键词索引中的全部绑定
  ///
  /// 由 [WorkspaceProvider] 实现，供 [BookDataMixin] 在删除整个设定项时调用：
  /// 设定项及其伴生文件被删除后，索引条目必须同步移除并通知监听者，
  /// 否则正文与阅读模式的高亮要等到重新进入工作台才失效。
  void purgeSettingItemKeywords(Iterable<String> settingItemUuids);

  /// 保存指定章节对应的标签页光标位置（若该标签页已打开）
  ///
  /// 由 [EditorMixin] 实现，供 [BookDataMixin] 在保存章节内容后调用，
  /// 以保证无论是手动保存还是自动保存都能持久化光标位置。
  Future<void> saveChapterCursorPositionIfAny(String chapterUuid);

  // ================= notifyListeners 安全重写 =================

  @override
  void notifyListeners() {
    if (!_isDisposed) super.notifyListeners();
  }
}
