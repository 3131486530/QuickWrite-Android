import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quick_write/core/services/reader/reader_tts_service.dart';
import 'package:quick_write/core/services/settings_service.dart';
import 'package:quick_write/core/models/outline_keyword.dart';
import 'package:quick_write/core/services/workspace/custom_highlight_service.dart';
import 'package:quick_write/core/services/workspace/outline_keyword_service.dart';
import 'package:quick_write/core/utils/color_utils.dart';
import 'package:quick_write/core/utils/custom_highlight_regex.dart';
import 'package:quick_write/core/utils/highlight_range_resolver.dart';
import 'package:quick_write/pages/workspace/reader/reader_paginator.dart';
import 'package:quick_write/shared/widgets/widgets.dart';

/// 阅读模式中的一章
///
/// 章节正文按需加载，避免一次性把全书读进内存；
/// [loadContent] 由调用方决定取文件内容还是编辑器里尚未落盘的正文，
/// [saveContent] 供长按段落的「编辑」把改后的整章正文写回。
class ReaderChapter {
  const ReaderChapter({
    required this.title,
    required this.loadContent,
    this.saveContent,
  });

  /// 章节标题
  final String title;

  /// 读取章节正文
  final Future<String> Function() loadContent;

  /// 写回整章正文，返回是否成功；为空表示该章只读
  final Future<bool> Function(String content)? saveContent;
}

/// 打开阅读模式
///
/// 以全屏路由进入，翻页阅读当前章节，并可跨章连续阅读。
Future<void> showReadingMode(
  BuildContext context, {
  required String bookTitle,
  required List<ReaderChapter> chapters,
  int initialChapterIndex = 0,
  CustomHighlightService? customHighlightService,
  OutlineKeywordService? outlineKeywordService,
}) {
  if (chapters.isEmpty) return Future<void>.value();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => ReadingModePage(
        bookTitle: bookTitle,
        chapters: chapters,
        initialChapterIndex: initialChapterIndex.clamp(0, chapters.length - 1),
        customHighlightService: customHighlightService,
        outlineKeywordService: outlineKeywordService,
      ),
    ),
  );
}

/// 阅读模式页面
///
/// 排版完全沿用章节编辑器的设置：正文的字体、字号、行高、字间距、字重、斜体、
/// 下划线、字体颜色、对话高亮、自定义关键词高亮、行分隔线与编辑器背景色，
/// 以及章节标题的字体、字号、颜色、对齐方式与顶边距，读起来与写作时所见一致。
///
/// 交互：点击屏幕左右三分之一区域或按键翻页（无动画直接换页），
/// 点击中间区域显隐顶部栏；读完一章最后一页后继续翻页即进入下一章，
/// 已是最后一章时不再翻页。
class ReadingModePage extends StatefulWidget {
  const ReadingModePage({
    super.key,
    required this.bookTitle,
    required this.chapters,
    required this.initialChapterIndex,
    this.customHighlightService,
    this.outlineKeywordService,
  });

  /// 书名
  final String bookTitle;

  /// 章节列表
  final List<ReaderChapter> chapters;

  /// 初始章节序号
  final int initialChapterIndex;

  /// 自定义关键词高亮服务（与编辑器共用同一份配置）
  final CustomHighlightService? customHighlightService;

  /// 大纲节点关键词服务（与编辑器共用同一份索引）
  ///
  /// 阅读模式没有修饰键与工具栏开关，节点关键词始终参与着色，
  /// 与写作页开启关键词高亮后的正文观感保持一致。
  final OutlineKeywordService? outlineKeywordService;

  @override
  State<ReadingModePage> createState() => _ReadingModePageState();
}

class _ReadingModePageState extends State<ReadingModePage> with WidgetsBindingObserver {
  /// 正文左右留白
  static const double _horizontalPadding = 20;

  /// 正文顶部留白：不留白，正文自 SafeArea 顶部铺排
  static const double _topPadding = 0;

  /// 页面底部不可见的 UI 占位区域：正文排到该区域上沿即止，
  /// 永不越过，页码安放在这块区域内，因此不会压到正文
  static const double _bottomSafeArea = 28;

  /// 正文底部留白：等于底部不可见区域高度
  static const double _bottomPadding = _bottomSafeArea;

  /// 页码距页面底部距离（在底部不可见区域内上移，不贴底）
  static const double _pageNumberBottomOffset = 10;

  /// 页码字号：放大以便看清
  static const double _pageNumberFontSize = 14;

  /// 行分隔线高度
  ///
  /// 与编辑器保持一致：每段正文后额外占 1 像素，分页时按块累加。
  static const double _separatorHeight = 1;

  /// 已加载的章节正文（按章节序号缓存）
  final Map<int, String> _contentCache = <int, String>{};

  late final PageController _pageController;

  int _chapterIndex = 0;

  /// 当前章正文，null 表示正在加载
  String? _content;

  /// 当前章高亮范围（整章解析一次）
  List<HighlightRange> _ranges = const <HighlightRange>[];

  /// 当前章按换行拆出的段落与其在全文中的起始偏移
  List<String> _paragraphs = const <String>[];
  List<int> _paragraphStarts = const <int>[];

  /// 分页结果
  List<ReaderPageSlice> _pages = const <ReaderPageSlice>[];

  /// 上一次分页所依据的参数指纹，变化时重新分页
  String _paginationSignature = '';

  int _pageIndex = 0;

  bool _loading = true;

  /// 顶部栏是否显示
  bool _chromeVisible = false;

  /// 分页完成后是否停在最后一页正文（用于「上一章」回退）
  bool _pendingChapterEnd = false;

  /// 语音朗读服务
  final ReaderTtsService _tts = ReaderTtsService();

  /// 听书模式是否开启
  bool _ttsEnabled = false;

  /// 是否正在朗读
  bool _ttsPlaying = false;

  /// 当前朗读段落序号（用于段落选中态，null 表示无朗读锚点）
  int? _speakingParagraph;

  /// 下一段待读的段落序号
  int _ttsCursor = 0;

  /// 分页还没完成时先记下要显形的段落，分页后落到它所在的页
  int? _pendingRevealParagraph;

  /// 听书控制条是否可见（听书开启且顶栏可见）
  bool get _ttsBarVisible => _ttsEnabled && _chromeVisible;

  /// 根节点 Key：长按后把屏幕坐标换算成浮层坐标
  final GlobalKey _rootKey = GlobalKey();

  /// 长按选中的段落序号（null 表示没有选中）
  int? _selectedParagraph;

  /// 长按位置（浮层定位锚点，Stack 局部坐标）
  Offset _selectionAnchor = Offset.zero;

  /// 段落浮动栏是否可见
  bool _selectionBarVisible = false;

  @override
  void initState() {
    super.initState();
    _chapterIndex = widget.initialChapterIndex;
    _pageController = PageController();
    // 关键词索引变化（新增、改色、删除关键词或删除整个设定项）后，
    // 需要立即按新索引重新解析高亮并重新分页，不能等下一次进入阅读模式
    widget.outlineKeywordService?.addListener(_onKeywordIndexChanged);
    // 退到后台时停止朗读，回到前台由用户自行继续
    WidgetsBinding.instance.addObserver(this);
    // 语速与单章循环是本地持久化偏好，读到后刷新一次按钮状态
    _tts.loadPreferences().then((_) {
      if (mounted) setState(() {});
    });
    _loadChapter(_chapterIndex);
  }

  @override
  void didUpdateWidget(covariant ReadingModePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换书籍时关键词服务实例会变，需要重新绑定监听
    if (!identical(oldWidget.outlineKeywordService, widget.outlineKeywordService)) {
      oldWidget.outlineKeywordService?.removeListener(_onKeywordIndexChanged);
      widget.outlineKeywordService?.addListener(_onKeywordIndexChanged);
    }
  }

  /// 关键词索引变化：触发重建，[_ensurePaginated] 会因版本号变化而重新分页
  void _onKeywordIndexChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    widget.outlineKeywordService?.removeListener(_onKeywordIndexChanged);
    WidgetsBinding.instance.removeObserver(this);
    _tts.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) return;
    if (!_ttsPlaying) return;
    // 退到后台或被其他应用覆盖时停止朗读，避免后台持续发声
    _tts.stop();
    if (!mounted) return;
    setState(() => _ttsPlaying = false);
  }

  /// 章名
  String get _chapterTitle => widget.chapters[_chapterIndex].title;

  @override
  Widget build(BuildContext context) {
    final Color background = ColorUtils.getEditorBackgroundColorForTheme(context);
    return Scaffold(
      backgroundColor: background,
      // 阅读页本身没有内联输入框，弹窗/输入法的安全区由弹窗自己处理；
      // 若跟随键盘缩放，正文高度会变，段落编辑保存后分页会按键盘高度重排一次，
      // 键盘收起再重排时页码已落错位置（表现就是跳到不相关的一页）。
      resizeToAvoidBottomInset: false,
      // 阅读排版不随系统字体缩放变化，与编辑器正文保持一致
      body: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
        child: Focus(
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: Stack(
          key: _rootKey,
          children: <Widget>[
            SafeArea(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final double contentWidth =
                      math.max(80.0, constraints.maxWidth - _horizontalPadding * 2);
                  final double contentHeight = math.max(
                    80.0,
                    constraints.maxHeight - _topPadding - _bottomPadding,
                  );
                  _ensurePaginated(context, contentWidth, contentHeight);

                  return Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: _loading
                            ? const Center(child: CircularProgressIndicator())
                            : _buildPages(context),
                      ),
                      // 页码固定在页面右侧的底部不可见区域内，正文不越过该区域，页码不参与点击
                      // 听书控制条占据同一块底部区域时页码改由控制条显示，避免被盖住
                      if (!_ttsBarVisible)
                      Positioned(
                        bottom: _pageNumberBottomOffset,
                        right: _horizontalPadding,
                        child: IgnorePointer(
                          child: Text(
                            '${_pageIndex + 1}/${_pages.isEmpty ? 1 : _pages.length}',
                            style: TextStyle(
                              fontFamily: SettingsService.instance.fontFamily,
                              fontSize: _pageNumberFontSize,
                              fontWeight: FontWeight.w500,
                              height: 1.1,
                              color: ColorUtils.getFontColorForTheme(context)
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            _buildTopBar(context, background),
            _buildTtsBar(context, background),
            _buildSelectionBar(context, background),
          ],
          ),
        ),
      ),
    );
  }

  /// 键盘翻页：左右方向键与翻页键，空格/回车前进
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.pageUp) {
      _turnBack();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space) {
      _turnForward();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 加载指定章节的正文
  Future<void> _loadChapter(int index) async {
    final int target = index.clamp(0, widget.chapters.length - 1);
    // 换章后旧的朗读锚点与段落序号都失效，听书续读时由新章章首重新给锚点
    _speakingParagraph = null;
    _pendingRevealParagraph = null;
    // 长按选中的段落同样属于旧章，换章时收起浮动栏
    _selectedParagraph = null;
    _selectionBarVisible = false;
    String? cached = _contentCache[target];
    if (cached == null) {
      setState(() {
        _loading = true;
        _chapterIndex = target;
        _content = null;
        _pages = const <ReaderPageSlice>[];
        _paginationSignature = '';
      });
      try {
        cached = await widget.chapters[target].loadContent();
      } catch (_) {
        cached = '';
      }
      _contentCache[target] = cached;
    }
    if (!mounted) return;
    setState(() {
      _chapterIndex = target;
      _content = cached;
      _loading = false;
      _pages = const <ReaderPageSlice>[];
      _paginationSignature = '';
      _pageIndex = 0;
    });
  }

  /// 听书开关：首次开启时准备引擎并从当前页首段开始朗读
  Future<void> _toggleTts() async {
    if (_ttsEnabled) {
      await _stopTts();
      return;
    }
    final bool ready = await _tts.ensureReady();
    if (!mounted) return;
    if (!ready) {
      SnackBarService.show(context, '当前设备没有可用的语音朗读引擎');
      return;
    }
    _tts.onComplete = _onParagraphSpoken;
    _tts.onError = _onTtsError;
    setState(() {
      _ttsEnabled = true;
      // 开启后先把控制条摆出来，方便立即暂停或切换循环
      _chromeVisible = true;
    });
    _speakFrom(_speakingParagraph ?? _firstParagraphOfPage(_pageIndex));
  }

  /// 关闭听书
  Future<void> _stopTts() async {
    _tts.onComplete = null;
    _tts.onError = null;
    await _tts.stop();
    if (!mounted) return;
    setState(() {
      _ttsEnabled = false;
      _ttsPlaying = false;
      _speakingParagraph = null;
      _pendingRevealParagraph = null;
    });
  }

  /// 播放/暂停：暂停后再播放从当前段落重新读起
  Future<void> _toggleTtsPlay() async {
    if (!_ttsEnabled) return;
    if (_ttsPlaying) {
      await _tts.stop();
      if (!mounted) return;
      setState(() => _ttsPlaying = false);
      return;
    }
    final bool ready = await _tts.ensureReady();
    if (!mounted || !ready) return;
    _tts.onComplete = _onParagraphSpoken;
    _tts.onError = _onTtsError;
    _speakFrom(_speakingParagraph ?? _firstParagraphOfPage(_pageIndex));
  }

  /// 手动切换朗读段落
  Future<void> _skipTtsParagraph(int delta) async {
    if (!_ttsEnabled || _paragraphs.isEmpty) return;
    await _tts.stop();
    if (!mounted) return;
    final int base = _speakingParagraph ?? _ttsCursor;
    final int target = (base + delta).clamp(0, _paragraphs.length - 1);
    _speakFrom(target, direction: delta < 0 ? -1 : 1);
  }

  /// 单章循环开关
  Future<void> _toggleTtsLoop() async {
    await _tts.setLoopChapter(!_tts.loopChapter);
    if (mounted) setState(() {});
  }

  /// 语速档位切换
  Future<void> _cycleTtsRate() async {
    await _tts.cycleRate();
    if (mounted) setState(() {});
  }

  void _onTtsError(Object error) {
    if (!mounted) return;
    SnackBarService.show(context, '语音朗读出错：$error');
    _stopTts();
  }

  /// 一段读完：接着读下一段，读完本章交给 [_onChapterSpokenOut]
  void _onParagraphSpoken() {
    if (!mounted || !_ttsEnabled || !_ttsPlaying) return;
    _speakFrom(_ttsCursor + 1);
  }

  /// 本章读完：单章循环回章首，否则续读下一章，已是最后一章则结束
  void _onChapterSpokenOut() {
    if (!mounted || !_ttsEnabled) return;
    if (_tts.loopChapter) {
      _pendingRevealParagraph = 0;
      _speakFrom(0);
      return;
    }
    if (_chapterIndex + 1 >= widget.chapters.length) {
      _stopTts();
      SnackBarService.show(context, '全书已朗读完毕');
      return;
    }
    _continueToNextChapter();
  }

  /// 续读下一章：正文与分页在下一帧才可用，届时从章首开始
  Future<void> _continueToNextChapter() async {
    await _loadChapter(_chapterIndex + 1);
    if (!mounted || !_ttsEnabled) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ttsEnabled) return;
      _pendingRevealParagraph = 0;
      _speakFrom(0);
    });
  }

  /// 朗读指定段落（自动跳过空行），朗读前把该段落所在页翻到眼前
  void _speakFrom(int paragraphIndex, {int direction = 1}) {
    if (!_ttsEnabled) return;
    if (_paragraphs.isEmpty) {
      // 章节正文还没加载完，等这一帧过去再试，避免读到上一章的残留段落
      if (_content == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_ttsEnabled) return;
          _speakFrom(paragraphIndex, direction: direction);
        });
        return;
      }
      _onChapterSpokenOut();
      return;
    }
    final int? target = _nextSpeakable(
      paragraphIndex.clamp(0, _paragraphs.length - 1),
      direction,
    );
    if (target == null) {
      _onChapterSpokenOut();
      return;
    }
    _ttsCursor = target;
    setState(() {
      _speakingParagraph = target;
      _ttsPlaying = true;
    });
    _revealParagraph(target);
    _tts.speak(_paragraphs[target]);
  }

  /// 从 [from] 起沿 [direction] 找到第一个非空段落
  int? _nextSpeakable(int from, int direction) {
    int cursor = from;
    while (cursor >= 0 && cursor < _paragraphs.length) {
      if (_paragraphs[cursor].trim().isNotEmpty) return cursor;
      cursor += direction;
    }
    return null;
  }

  /// 把指定段落所在的页翻到眼前
  ///
  /// 分页还没完成时（刚切章）先记下来，由 [_ensurePaginated] 落位。
  void _revealParagraph(int paragraphIndex) {
    final int pageIndex = _pageIndexForParagraph(paragraphIndex);
    if (pageIndex < 0) {
      _pendingRevealParagraph = paragraphIndex;
      return;
    }
    _pendingRevealParagraph = null;
    if (pageIndex == _pageIndex) return;
    _pageIndex = pageIndex;
    if (_pageController.hasClients) _pageController.jumpToPage(pageIndex);
  }

  /// 段落所属页序号，找不到返回 -1
  int _pageIndexForParagraph(int paragraphIndex) {
    for (int i = 0; i < _pages.length; i++) {
      for (final ReaderBlock block in _pages[i].blocks) {
        if (block.paragraphIndex == paragraphIndex) return i;
      }
    }
    return -1;
  }

  /// 段落所属页序号，找不到时返回序号最近段落所在的页；全书无正文返回 -1
  ///
  /// 段落被编辑成空行后不会再有 block，精确查找会落空，这时按就近原则落位，
  /// 保证重新分页后不会停在原来的页码上看到另一段内容。
  int _pageIndexForParagraphOrNearest(int paragraphIndex) {
    int nearestPage = -1;
    int nearestDistance = 1 << 30;
    for (int i = 0; i < _pages.length; i++) {
      for (final ReaderBlock block in _pages[i].blocks) {
        if (block.paragraphIndex == paragraphIndex) return i;
        final int distance = (block.paragraphIndex - paragraphIndex).abs();
        if (distance < nearestDistance) {
          nearestDistance = distance;
          nearestPage = i;
        }
      }
    }
    return nearestPage;
  }

  /// 某页首段序号，无正文时返回 0
  int _firstParagraphOfPage(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= _pages.length) return 0;
    final int index = _pages[pageIndex].firstParagraphIndex;
    return index < 0 ? 0 : index;
  }

  /// 手动翻页时暂停朗读，朗读锚点交还给新的可见页
  void _pauseForManualTurn() {
    if (!_ttsEnabled || !_ttsPlaying) return;
    _tts.stop();
    setState(() {
      _ttsPlaying = false;
      _speakingParagraph = null;
    });
  }

  /// 重新分页（仅在章节、尺寸或排版设置变化时执行）
  ///
  /// 分页为纯计算，在 build 阶段同步完成，保证第一帧就能拿到正确的页数；
  /// 页码变化后于帧末把 PageView 定位到目标页。
  void _ensurePaginated(BuildContext context, double contentWidth, double contentHeight) {
    final String? content = _content;
    if (content == null) return;

    final SettingsService settings = SettingsService.instance;
    final TextStyle bodyStyle = _bodyStyle(context);
    final TextStyle titleStyle = _titleStyle(context);
    final String signature = <String>[
      '$_chapterIndex',
      '${content.length}',
      '${content.hashCode}',
      '${contentWidth.round()}',
      '${contentHeight.round()}',
      '${settings.fontFamily}|${settings.fontSize}|${settings.lineHeight}|${settings.letterSpacing}',
      '${settings.isBold}|${settings.isItalic}|${settings.isUnderline}',
      '${settings.showChapterTitle}|${settings.chapterTitleFontSize}|${settings.chapterTitleFontFamily}',
      '${settings.chapterTitleTopMargin}|${settings.isChapterTitleLeftAligned}',
      '${settings.showLineSeparator}|${settings.lineSeparatorStyle}|${settings.lineSeparatorOpacity}',
      '${settings.dialogueHighlightEnabled}|${Theme.of(context).brightness}',
      // 关键词索引变化（新增、改色、删除）后需重新解析高亮再分页
      '${widget.outlineKeywordService?.revision ?? -1}',
      _firstLineIndent,
    ].join('#');
    if (signature == _paginationSignature) return;
    _paginationSignature = signature;

    _ranges = _resolveRanges(context, content);
    final List<ReaderPageSlice> pages = ReaderPaginator.paginate(
      chapterTitle: _chapterTitle,
      content: content,
      ranges: _ranges,
      bodyStyle: bodyStyle,
      titleStyle: titleStyle,
      titleTopMargin: settings.chapterTitleTopMargin,
      showTitle: settings.showChapterTitle,
      maxWidth: contentWidth,
      pageHeight: contentHeight,
      showSeparator: settings.showLineSeparator,
      separatorHeight: _separatorHeight,
      firstLineIndent: _firstLineIndent,
      onParagraphsResolved: (List<int> starts) {
        _paragraphs = content.split('\n');
        _paragraphStarts = starts;
      },
    );
    _pages = pages;
    if (_pendingChapterEnd) {
      // 由「上一章」触发：分页完成后停在最后一页正文，而不是章首
      _pendingChapterEnd = false;
      _pageIndex = math.max(0, _pages.length - 1);
    }
    _pageIndex = _pageIndex.clamp(0, _pages.length - 1);

    // 听书切章、段落编辑保存后重排：把等待落位的段落所在页翻出来。
    // 段落可能因编辑被清空而查不到，这时退到序号最近的段落，避免停在旧页码上。
    final int? reveal = _pendingRevealParagraph;
    if (reveal != null) {
      final int revealPage = _pageIndexForParagraphOrNearest(reveal);
      if (revealPage >= 0) _pageIndex = revealPage;
    }

    final int target = _pageIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 落位这一帧之后再清锚点：中途若因尺寸/关键词变化再次分页，还能重新对位
      if (_pendingRevealParagraph == reveal) _pendingRevealParagraph = null;
      if (!_pageController.hasClients) return;
      if (_pageController.page?.round() != target) {
        _pageController.jumpToPage(target);
      }
    });
  }

  /// 解析整章高亮范围：对话高亮、自定义关键词与大纲节点关键词，与编辑器同源
  List<HighlightRange> _resolveRanges(BuildContext context, String text) {
    final SettingsService settings = SettingsService.instance;
    final List<HighlightRange> ranges = <HighlightRange>[];

    if (settings.dialogueHighlightEnabled) {
      ranges.addAll(HighlightRangeResolver.parseDialogueRanges(
        text,
        ColorUtils.getDialogueHighlightColorForTheme(context),
      ));
    }

    final CustomHighlightService? service = widget.customHighlightService;
    if (service != null && service.enabled) {
      for (final item in service.items) {
        final Color color = ColorUtils.parseHex(item.colorHex);
        if (item.isRegex) {
          final RegExp? regex = CustomHighlightRegex.tryCompile(item.keyword);
          if (regex == null) continue;
          ranges.addAll(HighlightRangeResolver.parseRegexRanges(text, regex, color));
        } else {
          ranges.addAll(HighlightRangeResolver.parseKeywordRanges(text, item.keyword, color));
        }
      }
    }

    _addOutlineKeywordRanges(text, ranges);
    return HighlightRangeResolver.mergeRanges(ranges);
  }

  /// 叠加大纲节点关键词着色
  ///
  /// 与编辑器一致：长词优先，命中区间互不重叠，字重略加粗以示强调。
  void _addOutlineKeywordRanges(String text, List<HighlightRange> ranges) {
    final OutlineKeywordService? service = widget.outlineKeywordService;
    if (service == null) return;

    final List<String> keywords = service.keywords.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final List<({int start, int end})> accepted = <({int start, int end})>[];

    for (final keyword in keywords) {
      final OutlineKeywordEntry? entry = service.entryForKeyword(keyword);
      if (entry == null) continue;
      OutlineKeyword? binding;
      for (final item in entry.keywords) {
        if (item.keyword == keyword) {
          binding = item;
          break;
        }
      }
      if (binding == null) continue;

      final List<HighlightRange> matches = HighlightRangeResolver.parseKeywordRanges(
        text,
        keyword,
        binding.color,
        priority: HighlightRangeResolver.outlineKeywordPriority,
      );
      for (final match in matches) {
        final bool overlapped = accepted.any(
          (segment) => match.start < segment.end && match.end > segment.start,
        );
        if (overlapped) continue;
        accepted.add((start: match.start, end: match.end));
        // 阅读模式只做底色高亮，不叠加字重：分页按基础样式测量行宽，
        // 若渲染时加粗会让关键词所在行更宽、多折一行，页面高度超过可容纳区域，
        // 导致末行被页面底部裁掉（表现为正文被遮挡）
        ranges.add(HighlightRange(
          match.start,
          match.end,
          binding.color,
          HighlightRangeResolver.outlineKeywordPriority,
        ));
      }
    }
  }

  /// 段首缩进前缀
  ///
  /// 编辑器里首行缩进有两种实现：写入两个全角空格，或由排版绘制视觉缩进。
  /// 后者的字符不在正文中，阅读模式按同样宽度在段首补两个全角空格复现，
  /// 保证段落外观与写作时一致。
  String get _firstLineIndent {
    final SettingsService settings = SettingsService.instance;
    if (!settings.isFirstLineIndentEnabled) return '';
    if (settings.isFullWidthSpaceIndentEnabled) return '';
    return '\u3000\u3000';
  }

  /// 正文样式：与编辑器 CodeEditorStyle 使用同一批设置
  TextStyle _bodyStyle(BuildContext context) {
    final SettingsService settings = SettingsService.instance;
    final Color color = ColorUtils.getFontColorForTheme(context);
    return TextStyle(
      fontFamily: settings.fontFamily,
      fontSize: settings.fontSize,
      height: settings.lineHeight,
      letterSpacing: settings.letterSpacing,
      color: color,
      fontWeight: settings.isBold ? FontWeight.bold : FontWeight.normal,
      fontStyle: settings.isItalic ? FontStyle.italic : FontStyle.normal,
      decoration: settings.isUnderline ? TextDecoration.underline : TextDecoration.none,
      decorationColor: color,
    );
  }

  /// 章节标题样式：与编辑器章节标题使用同一批设置
  TextStyle _titleStyle(BuildContext context) {
    final SettingsService settings = SettingsService.instance;
    return TextStyle(
      fontFamily: settings.chapterTitleFontFamily,
      fontSize: settings.chapterTitleFontSize,
      color: ColorUtils.getChapterTitleColorForTheme(context),
    );
  }

  /// 正文区域
  Widget _buildPages(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (TapUpDetails details) {
        // 段落浮动栏打开时，先收起浮层与选中态，不触发翻页
        if (_selectionBarVisible || _selectedParagraph != null) {
          _hideSelectionBar();
          return;
        }
        final double width = MediaQuery.sizeOf(context).width;
        final double x = details.globalPosition.dx;
        if (x < width / 3) {
          _turnBack();
        } else if (x > width * 2 / 3) {
          _turnForward();
        } else {
          setState(() => _chromeVisible = !_chromeVisible);
        }
      },
      child: PageView.builder(
        controller: _pageController,
        // 翻页只靠点击/按键触发，禁用拖动抢占
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _pages.length,
        onPageChanged: (int index) => setState(() => _pageIndex = index),
        itemBuilder: (BuildContext context, int index) => _buildPage(context, index),
      ),
    );
  }

  /// 单页内容
  Widget _buildPage(BuildContext context, int index) {
    final ReaderPageSlice page = _pages[index];

    final SettingsService settings = SettingsService.instance;
    final TextStyle bodyStyle = _bodyStyle(context);
    final TextStyle titleStyle = _titleStyle(context);
    final TextAlign titleAlign =
        settings.isChapterTitleLeftAligned ? TextAlign.left : TextAlign.center;

    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        left: _horizontalPadding,
        right: _horizontalPadding,
        top: _topPadding,
        bottom: _bottomPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (page.hasTitle && settings.showChapterTitle)
            Padding(
              padding: EdgeInsets.only(top: settings.chapterTitleTopMargin),
              child: Text(
                _chapterTitle,
                style: titleStyle,
                textAlign: titleAlign,
              ),
            ),
          for (final ReaderBlock block in page.blocks) _buildBlock(context, block, bodyStyle),
        ],
      ),
    );
  }

  /// 单个文本块
  Widget _buildBlock(BuildContext context, ReaderBlock block, TextStyle bodyStyle) {
    final SettingsService settings = SettingsService.instance;
    final String paragraph =
        block.paragraphIndex < _paragraphs.length ? _paragraphs[block.paragraphIndex] : '';
    final int start = block.start.clamp(0, paragraph.length);
    final int end = block.end.clamp(start, paragraph.length);
    String text = paragraph.substring(start, end);
    if (text.isEmpty) text = ReaderPaginator.blankLine;
    final int startOffset =
        (block.paragraphIndex < _paragraphStarts.length ? _paragraphStarts[block.paragraphIndex] : 0) +
            start;

    final Widget textWidget = Text.rich(
      TextSpan(
        style: bodyStyle,
        children: ReaderPaginator.buildSpans(
          text: text,
          startOffset: startOffset,
          ranges: _ranges,
          baseStyle: bodyStyle,
          // 只有段落首块带首行缩进
          indentPrefix: block.start == 0 ? _firstLineIndent : '',
        ),
      ),
    );

    // 听书时当前朗读段落铺一层底色作为选中态；长按选中的段落同样铺底色。
    // 只画背景、不加内外边距与描边，分页测量不受影响，多行段落也是一整条连续底。
    final bool speaking = _ttsEnabled && block.paragraphIndex == _speakingParagraph;
    final bool selected = block.paragraphIndex == _selectedParagraph;
    final Color accent = Theme.of(context).colorScheme.primary;
    Widget bodyWidget = textWidget;
    if (speaking || selected) {
      bodyWidget = DecoratedBox(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: speaking ? 0.16 : 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: textWidget,
      );
    }

    // 长按整段：选中该段并弹出浮动栏（编辑 / 从此处读）
    bodyWidget = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPressStart: (LongPressStartDetails details) {
        _showSelectionBar(block.paragraphIndex, details.globalPosition);
      },
      child: bodyWidget,
    );

    // 分隔线属于段落之间的元素：段落被分页切开时，续块不再画分隔线，
    // 否则页内实际高度会比分页测量多出一条线，累积后把末行顶出页面。
    if (!settings.showLineSeparator || block.end < paragraph.length) return bodyWidget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        bodyWidget,
        _buildLineSeparator(context, settings),
      ],
    );
  }

  /// 行分隔线：与编辑器一样支持实线与虚线，透明度沿用设置
  Widget _buildLineSeparator(BuildContext context, SettingsService settings) {
    final Color color =
        ColorUtils.getFontColorForTheme(context).withValues(alpha: settings.lineSeparatorOpacity);
    final Widget line = settings.lineSeparatorStyle == 'dashed'
        ? CustomPaint(painter: _DashedLinePainter(color: color))
        : ColoredBox(color: color);
    return SizedBox(height: _separatorHeight, child: line);
  }

  /// 长按段落：选中该段并在长按位置弹出浮动栏
  void _showSelectionBar(int paragraphIndex, Offset globalPosition) {
    final RenderBox? box = _rootKey.currentContext?.findRenderObject() as RenderBox?;
    final Offset local = box == null ? globalPosition : box.globalToLocal(globalPosition);
    setState(() {
      _selectedParagraph = paragraphIndex;
      _selectionAnchor = local;
      _selectionBarVisible = true;
    });
  }

  /// 收起段落浮动栏并清掉选中态
  void _hideSelectionBar() {
    if (!_selectionBarVisible && _selectedParagraph == null) return;
    setState(() {
      _selectionBarVisible = false;
      _selectedParagraph = null;
    });
  }

  /// 段落浮动栏：编辑、从此处读
  ///
  /// 以浮层贴在长按位置上方（上方空间不足时贴到下方），不参与正文排版。
  Widget _buildSelectionBar(BuildContext context, Color background) {
    if (!_selectionBarVisible) return const SizedBox.shrink();
    const double barWidth = 172;
    const double barHeight = 42;
    final Size size = MediaQuery.sizeOf(context);
    final double left = (_selectionAnchor.dx - barWidth / 2)
        .clamp(8.0, math.max(8.0, size.width - barWidth - 8));
    final double top = _selectionAnchor.dy - barHeight - 10 >= 8
        ? _selectionAnchor.dy - barHeight - 10
        : _selectionAnchor.dy + 22;
    final Color color = ColorUtils.getFontColorForTheme(context);
    final Color accent = Theme.of(context).colorScheme.primary;

    Widget action({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: InkWell(
          onTap: onTap,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontFamily: SettingsService.instance.fontFamily,
                  fontSize: 13,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Positioned(
      left: left,
      top: top,
      child: Material(
        color: background,
        elevation: 4,
        borderRadius: BorderRadius.circular(barHeight / 2),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: barWidth,
          height: barHeight,
          child: Row(
            children: <Widget>[
              action(
                icon: Icons.edit_outlined,
                label: '编辑',
                onTap: _editSelectedParagraph,
              ),
              SizedBox(
                width: 0.5,
                height: 18,
                child: ColoredBox(color: color.withValues(alpha: 0.2)),
              ),
              action(
                icon: Icons.volume_up_rounded,
                label: '从此处读',
                onTap: _readFromSelectedParagraph,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 编辑选中的段落：弹窗改完写回正文与章节文件
  ///
  /// 位置逻辑与长按浮动栏完全同源：取长按点在栈内的局部坐标换算成全局坐标，
  /// 胶囊面板贴在该点上方（空间不足贴下方），并夹在可视区与键盘之间。
  Future<void> _editSelectedParagraph() async {
    final int? index = _selectedParagraph;
    final RenderBox? box = _rootKey.currentContext?.findRenderObject() as RenderBox?;
    final Offset anchor = box == null
        ? Offset(MediaQuery.sizeOf(context).width / 2,
            MediaQuery.sizeOf(context).height / 2)
        : box.localToGlobal(_selectionAnchor);
    _hideSelectionBar();
    if (index == null || index >= _paragraphs.length) return;
    final TextEditingController controller =
        TextEditingController(text: _paragraphs[index]);
    final String? edited = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭段落编辑',
      barrierColor: Colors.black.withValues(alpha: 0.12),
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (
        BuildContext dialogContext,
        Animation<double> animation,
        Animation<double> secondaryAnimation,
      ) {
        return CustomSingleChildLayout(
          delegate: _CapsulePanelLayout(
            anchor: anchor,
            gap: 10,
            keyboard: MediaQuery.viewInsetsOf(dialogContext).bottom,
          ),
          child: _buildParagraphEditorPanel(dialogContext, controller, index),
        );
      },
    );
    controller.dispose();
    if (!mounted || edited == null) return;
    await _replaceParagraph(index, edited);
  }

  /// 段落编辑面板：照搬长按浮动胶囊栏的材质与控件样式
  ///
  /// 同背景色、同 elevation 4、同字号 accent 图标动作（按钮自身不带圆角，靠外层裁切），
  /// 动作之间同样用 0.5×18 的细竖线分隔，只是把动作换成取消 / 保存；
  /// 外层圆角取小一号的 14，不用高度一半的胶囊。
  Widget _buildParagraphEditorPanel(
    BuildContext dialogContext,
    TextEditingController controller,
    int index,
  ) {
    final SettingsService settings = SettingsService.instance;
    final Color background =
        ColorUtils.getEditorBackgroundColorForTheme(dialogContext);
    final Color contentColor = ColorUtils.getFontColorForTheme(dialogContext);
    final Color accent = Theme.of(dialogContext).colorScheme.primary;

    Widget action({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
    }) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontFamily: settings.fontFamily,
                  fontSize: 13,
                  color: contentColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 560),
      child: Material(
        color: background,
        elevation: 4,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 2,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                cursorColor: accent,
                style: TextStyle(
                  fontFamily: settings.fontFamily,
                  fontSize: settings.fontSize,
                  height: settings.lineHeight,
                  color: contentColor,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '编辑第 ${index + 1} 段',
                  hintStyle: TextStyle(
                    fontFamily: settings.fontFamily,
                    fontSize: settings.fontSize,
                    color: contentColor.withValues(alpha: 0.35),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  action(
                    icon: Icons.close_rounded,
                    label: '取消',
                    onTap: () => Navigator.of(dialogContext).pop(),
                  ),
                  SizedBox(
                    width: 0.5,
                    height: 18,
                    child: ColoredBox(color: contentColor.withValues(alpha: 0.2)),
                  ),
                  action(
                    icon: Icons.check_rounded,
                    label: '保存',
                    onTap: () =>
                        Navigator.of(dialogContext).pop(controller.text),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 用 [text] 替换当前章第 [index] 段，并写回章节文件
  ///
  /// 按换行重新拼装整章正文：分页器同样以 `\n` 拆段，改完立刻重新分页，
  /// 并把编辑后的段落翻到眼前。
  Future<void> _replaceParagraph(int index, String text) async {
    final String? content = _content;
    if (content == null) return;
    final List<String> lines = content.split('\n');
    if (index >= lines.length || lines[index] == text) return;
    lines[index] = text;
    final String updated = lines.join('\n');

    // 文本变了，朗读锚点与段落序号都会失效：先把朗读状态收干净再停引擎，
    // 避免停止时触发的完成回调按旧游标继续读
    final bool wasPlaying = _ttsPlaying;
    setState(() {
      _content = updated;
      _contentCache[_chapterIndex] = updated;
      _pages = const <ReaderPageSlice>[];
      _paginationSignature = '';
      _pendingRevealParagraph = index;
      _ttsPlaying = false;
      _speakingParagraph = null;
      _selectedParagraph = null;
      _selectionBarVisible = false;
    });
    if (wasPlaying) await _tts.stop();

    final Future<bool> Function(String content)? save =
        widget.chapters[_chapterIndex].saveContent;
    if (save == null) {
      SnackBarService.show(context, '段落已修改');
      return;
    }
    bool ok;
    try {
      ok = await save(updated);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    SnackBarService.show(context, ok ? '段落已保存' : '段落已修改，但写入章节失败');
  }

  /// 从此处读：开启听书后从选中段落开始朗读
  Future<void> _readFromSelectedParagraph() async {
    final int? index = _selectedParagraph;
    _hideSelectionBar();
    if (index == null) return;
    if (!_ttsEnabled) {
      final bool ready = await _tts.ensureReady();
      if (!mounted) return;
      if (!ready) {
        SnackBarService.show(context, '当前设备没有可用的语音朗读引擎');
        return;
      }
      _tts.onComplete = _onParagraphSpoken;
      _tts.onError = _onTtsError;
      setState(() {
        _ttsEnabled = true;
        // 开启后把控制条摆出来，方便立即暂停或切换循环
        _chromeVisible = true;
      });
    }
    _speakFrom(index);
  }

  /// 听书控制条：上一段、播放/暂停、下一段、语速、单章循环
  ///
  /// 只在听书开启且顶部栏可见时出现（点屏幕中间可显隐），
  /// 以浮层方式贴在底部，不参与正文排版，不会压住页面文字。
  Widget _buildTtsBar(BuildContext context, Color background) {
    final Color color = ColorUtils.getFontColorForTheme(context);
    final Color accent = Theme.of(context).colorScheme.primary;
    final bool visible = _ttsBarVisible;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Material(
            color: background,
            elevation: visible ? 3 : 0,
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: <Widget>[
                    const SizedBox(width: 4),
                    IconButton(
                      onPressed: () => _skipTtsParagraph(-1),
                      icon: const Icon(Icons.skip_previous_rounded),
                      color: color,
                      visualDensity: VisualDensity.compact,
                      tooltip: '上一段',
                    ),
                    IconButton(
                      onPressed: _toggleTtsPlay,
                      icon: Icon(
                        _ttsPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_fill_rounded,
                      ),
                      iconSize: 40,
                      color: accent,
                      visualDensity: VisualDensity.compact,
                      tooltip: _ttsPlaying ? '暂停朗读' : '继续朗读',
                    ),
                    IconButton(
                      onPressed: () => _skipTtsParagraph(1),
                      icon: const Icon(Icons.skip_next_rounded),
                      color: color,
                      visualDensity: VisualDensity.compact,
                      tooltip: '下一段',
                    ),
                    const Spacer(),
                    Text(
                      '${_pageIndex + 1}/${_pages.isEmpty ? 1 : _pages.length}',
                      style: TextStyle(
                        fontFamily: SettingsService.instance.fontFamily,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: color.withValues(alpha: 0.6),
                      ),
                    ),
                    TextButton(
                      onPressed: _cycleTtsRate,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        '语速 · ${_tts.rateLabel}',
                        style: TextStyle(
                          fontFamily: SettingsService.instance.fontFamily,
                          fontSize: 12,
                          color: color.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _toggleTtsLoop,
                      icon: Icon(
                        Icons.repeat_one_rounded,
                        color: _tts.loopChapter ? accent : color.withValues(alpha: 0.55),
                      ),
                      visualDensity: VisualDensity.compact,
                      tooltip: _tts.loopChapter ? '单章循环：开' : '单章循环：关',
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 顶部栏：返回、书名与章名、目录
  Widget _buildTopBar(BuildContext context, Color background) {
    final Color color = ColorUtils.getFontColorForTheme(context);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !_chromeVisible,
        child: AnimatedOpacity(
          opacity: _chromeVisible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Material(
            color: background,
            elevation: _chromeVisible ? 2 : 0,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 52,
                child: Row(
                  children: <Widget>[
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                      color: color,
                      tooltip: '退出阅读',
                    ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            widget.bookTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: SettingsService.instance.fontFamily,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: color,
                            ),
                          ),
                          Text(
                            _chapterTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: SettingsService.instance.fontFamily,
                              fontSize: 11,
                              color: color.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: _toggleTts,
                      icon: Icon(
                        _ttsEnabled ? Icons.headphones_rounded : Icons.headphones_outlined,
                      ),
                      color: _ttsEnabled ? Theme.of(context).colorScheme.primary : color,
                      tooltip: _ttsEnabled ? '关闭听书' : '听书',
                    ),
                    IconButton(
                      onPressed: _openCatalog,
                      icon: const Icon(Icons.list_rounded),
                      color: color,
                      tooltip: '目录',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 目录：快速切换章节
  void _openCatalog() {
    _hideSelectionBar();
    final Color background = ColorUtils.getEditorBackgroundColorForTheme(context);
    final Color color = ColorUtils.getFontColorForTheme(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: background,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: <Widget>[
                      Text(
                        '目录 · 共 ${widget.chapters.length} 章',
                        style: TextStyle(
                          fontFamily: SettingsService.instance.fontFamily,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView.builder(
                    itemCount: widget.chapters.length,
                    itemBuilder: (BuildContext context, int index) {
                      final bool current = index == _chapterIndex;
                      return ListTile(
                        dense: true,
                        title: Text(
                          widget.chapters[index].title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: SettingsService.instance.fontFamily,
                            fontSize: 13,
                            color: current ? Theme.of(context).colorScheme.primary : color,
                            fontWeight: current ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        onTap: () {
                          _pauseForManualTurn();
                          _hideSelectionBar();
                          Navigator.of(sheetContext).pop();
                          if (index == _chapterIndex) return;
                          // 切章后回到纯阅读状态，顶部功能条一并收起
                          setState(() => _chromeVisible = false);
                          _loadChapter(index);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 上一页：首页时回到上一章的最后一页
  void _turnBack() {
    _hideSelectionBar();
    _pauseForManualTurn();
    if (_pageIndex > 0) {
      _pageController.jumpToPage(_pageIndex - 1);
      return;
    }
    if (_chapterIndex == 0) {
      SnackBarService.show(context, '已经是第一章');
      return;
    }
    _loadChapterWithEnd(_chapterIndex - 1);
  }

  /// 下一页：本章最后一页时直接进入下一章，无下一章则不翻页
  void _turnForward() {
    _hideSelectionBar();
    _pauseForManualTurn();
    if (_pageIndex < _pages.length - 1) {
      _pageController.jumpToPage(_pageIndex + 1);
      return;
    }
    if (_chapterIndex + 1 >= widget.chapters.length) {
      SnackBarService.show(context, '已经是最后一章');
      return;
    }
    _loadChapter(_chapterIndex + 1);
  }

  /// 加载上一章并停在最后一页正文
  ///
  /// 分页在下一帧的布局阶段完成，因此这里只置标记，由分页逻辑落位页码。
  Future<void> _loadChapterWithEnd(int index) async {
    _pendingChapterEnd = true;
    await _loadChapter(index);
  }
}

/// 虚线分隔线画笔
class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter({required this.color});

  final Color color;

  /// 单段实线长度
  static const double _dashWidth = 4;

  /// 间隔长度
  static const double _gapWidth = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    double x = 0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(math.min(x + _dashWidth, size.width), size.height / 2),
        paint,
      );
      x += _dashWidth + _gapWidth;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) => oldDelegate.color != color;
}

/// 胶囊浮层定位委托：与长按浮动栏同一套算法
/// （贴锚点上方，上方不够贴下方，左右夹在可视区内，且不压键盘）。
class _CapsulePanelLayout extends SingleChildLayoutDelegate {
  _CapsulePanelLayout({
    required this.anchor,
    required this.gap,
    required this.keyboard,
  });

  final Offset anchor;
  final double gap;
  final double keyboard;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: 220,
      maxWidth: math.min(560, constraints.maxWidth - 32),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double left = (anchor.dx - childSize.width / 2)
        .clamp(16.0, math.max(16.0, size.width - childSize.width - 16));
    final double maxBottom = size.height - keyboard - 8;
    double top = anchor.dy - childSize.height - gap;
    if (top < 8) top = anchor.dy + 22;
    if (top + childSize.height > maxBottom) {
      top = math.max(8.0, maxBottom - childSize.height);
    }
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_CapsulePanelLayout oldDelegate) {
    return oldDelegate.anchor != anchor || oldDelegate.keyboard != keyboard;
  }
}
