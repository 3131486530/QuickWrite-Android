import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:quick_write/core/services/settings_service.dart';
import 'package:quick_write/core/services/workspace/custom_highlight_service.dart';
import 'package:quick_write/core/utils/color_utils.dart';
import 'package:quick_write/core/utils/custom_highlight_regex.dart';
import 'package:quick_write/core/utils/highlight_range_resolver.dart';
import 'package:quick_write/pages/workspace/reader/reader_paginator.dart';
import 'package:quick_write/shared/widgets/widgets.dart';

/// 阅读模式中的一章
///
/// 章节正文按需加载，避免一次性把全书读进内存；
/// [loadContent] 由调用方决定取文件内容还是编辑器里尚未落盘的正文。
class ReaderChapter {
  const ReaderChapter({required this.title, required this.loadContent});

  /// 章节标题
  final String title;

  /// 读取章节正文
  final Future<String> Function() loadContent;
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
}) {
  if (chapters.isEmpty) return Future<void>.value();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => ReadingModePage(
        bookTitle: bookTitle,
        chapters: chapters,
        initialChapterIndex: initialChapterIndex.clamp(0, chapters.length - 1),
        customHighlightService: customHighlightService,
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
/// 交互：左右滑动或点击屏幕左右三分之一区域翻页，点击中间区域显隐顶部栏，
/// 每章末尾有一次「本章完」过渡页，点击后进入下一章。
/// 翻页动效
enum ReadingTurnMode {
  /// 直接换页，无过渡动画（默认）
  none,

  /// 下一页覆盖上一页的覆盖式翻页
  cover,
}

class ReadingModePage extends StatefulWidget {
  const ReadingModePage({
    super.key,
    required this.bookTitle,
    required this.chapters,
    required this.initialChapterIndex,
    this.customHighlightService,
  });

  /// 书名
  final String bookTitle;

  /// 章节列表
  final List<ReaderChapter> chapters;

  /// 初始章节序号
  final int initialChapterIndex;

  /// 自定义关键词高亮服务（与编辑器共用同一份配置）
  final CustomHighlightService? customHighlightService;

  @override
  State<ReadingModePage> createState() => _ReadingModePageState();
}

class _ReadingModePageState extends State<ReadingModePage> {
  /// 正文左右留白
  static const double _horizontalPadding = 20;

  /// 正文顶部留白
  static const double _topPadding = 8;

  /// 页脚高度（章节名与页码）
  static const double _footerHeight = 34;

  /// 行分隔线高度
  static const double _separatorHeight = 1;

  /// 已加载的章节正文（按章节序号缓存）
  final Map<int, String> _contentCache = <int, String>{};

  late final PageController _pageController;

  /// 翻页动效，默认无动画
  ReadingTurnMode _turnMode = ReadingTurnMode.none;

  /// 翻页动效偏好的本地存储 key
  static const String _turnModePrefKey = 'reader_turn_mode';

  int _chapterIndex = 0;

  /// 当前章正文，null 表示正在加载
  String? _content;

  /// 当前章高亮范围（整章解析一次）
  List<HighlightRange> _ranges = const <HighlightRange>[];

  /// 当前章按换行拆出的段落与其在全文中的起始偏移
  List<String> _paragraphs = const <String>[];
  List<int> _paragraphStarts = const <int>[];

  /// 分页结果（末尾含一张章末过渡页）
  List<ReaderPageSlice> _pages = const <ReaderPageSlice>[];

  /// 上一次分页所依据的参数指纹，变化时重新分页
  String _paginationSignature = '';

  int _pageIndex = 0;

  bool _loading = true;

  /// 顶部栏是否显示
  bool _chromeVisible = false;

  /// 分页完成后是否停在最后一页正文（用于「上一章」回退）
  bool _pendingChapterEnd = false;

  @override
  void initState() {
    super.initState();
    _chapterIndex = widget.initialChapterIndex;
    _pageController = PageController();
    _loadChapter(_chapterIndex);
    _restoreTurnMode();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 章名
  String get _chapterTitle => widget.chapters[_chapterIndex].title;

  @override
  Widget build(BuildContext context) {
    final Color background = ColorUtils.getEditorBackgroundColorForTheme(context);
    return Scaffold(
      backgroundColor: background,
      // 阅读排版不随系统字体缩放变化，与编辑器正文保持一致
      body: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
        child: Focus(
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: Stack(
          children: <Widget>[
            SafeArea(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final double contentWidth =
                      math.max(80.0, constraints.maxWidth - _horizontalPadding * 2);
                  final double contentHeight = math.max(
                    80.0,
                    constraints.maxHeight - _topPadding - _footerHeight - 16,
                  );
                  _ensurePaginated(context, contentWidth, contentHeight);

                  return Column(
                    children: <Widget>[
                      Expanded(
                        child: _loading
                            ? const Center(child: CircularProgressIndicator())
                            : _buildPages(context),
                      ),
                      _buildFooter(context),
                    ],
                  );
                },
              ),
            ),
            _buildTopBar(context, background),
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
    pages.add(const ReaderPageSlice(
      blocks: <ReaderBlock>[],
      hasTitle: false,
      isChapterEnd: true,
    ));
    _pages = pages;
    if (_pendingChapterEnd) {
      // 由「上一章」触发：分页完成后停在最后一页正文，而不是章首
      _pendingChapterEnd = false;
      _pageIndex = math.max(0, _pages.length - 2);
    }
    _pageIndex = _pageIndex.clamp(0, _pages.length - 1);

    final int target = _pageIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      if (_pageController.page?.round() != target) {
        _pageController.jumpToPage(target);
      }
    });
  }

  /// 解析整章高亮范围：对话高亮与自定义关键词高亮，与编辑器同源
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

    return HighlightRangeResolver.mergeRanges(ranges);
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
        // 翻页只有「无动画」与「覆盖」两种，均靠点击/按键触发，禁用拖动抢占
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _pages.length,
        onPageChanged: (int index) => setState(() => _pageIndex = index),
        itemBuilder: (BuildContext context, int index) =>
            _buildPageWithTurnEffect(context, index),
      ),
    );
  }

  /// 单页内容
  Widget _buildPage(BuildContext context, int index) {
    final ReaderPageSlice page = _pages[index];
    if (page.isChapterEnd) return _buildChapterEndPage(context);

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

    if (!settings.showLineSeparator) return textWidget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        textWidget,
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

  /// 章末过渡页
  Widget _buildChapterEndPage(BuildContext context) {
    final bool hasNext = _chapterIndex + 1 < widget.chapters.length;
    final Color color = ColorUtils.getFontColorForTheme(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('本章完', style: _titleStyle(context).copyWith(fontSize: 18)),
            const SizedBox(height: 12),
            Text(
              hasNext ? '下一章 · ${widget.chapters[_chapterIndex + 1].title}' : '已经是最后一章',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: SettingsService.instance.fontFamily,
                fontSize: 13,
                color: color.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 28),
            hasNext
                ? FilledButton(
                    onPressed: () => _loadChapter(_chapterIndex + 1),
                    child: const Text('继续阅读'),
                  )
                : TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('退出阅读'),
                  ),
          ],
        ),
      ),
    );
  }

  /// 页脚：章节名与当前页码
  Widget _buildFooter(BuildContext context) {
    final Color color = ColorUtils.getFontColorForTheme(context).withValues(alpha: 0.45);
    final TextStyle style = TextStyle(
      fontFamily: SettingsService.instance.fontFamily,
      fontSize: 11,
      color: color,
    );
    return SizedBox(
      height: _footerHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _horizontalPadding),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(_chapterTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
            ),
            Text('${_pageIndex + 1}/${_pages.isEmpty ? 1 : _pages.length}', style: style),
          ],
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
                      onPressed: _toggleTurnMode,
                      icon: Icon(_turnMode == ReadingTurnMode.cover
                          ? Icons.layers_rounded
                          : Icons.compare_arrows_rounded),
                      color: color,
                      tooltip: _turnMode == ReadingTurnMode.cover
                          ? '翻页：覆盖（点击改为无动画）'
                          : '翻页：无动画（点击改为覆盖）',
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
                        trailing: current
                            ? Icon(
                                Icons.play_arrow_rounded,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          if (index != _chapterIndex) _loadChapter(index);
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

  /// 从本地偏好恢复翻页动效
  Future<void> _restoreTurnMode() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? saved = prefs.getString(_turnModePrefKey);
    if (!mounted || saved == null) return;
    final ReadingTurnMode mode =
        saved == 'cover' ? ReadingTurnMode.cover : ReadingTurnMode.none;
    if (mode != _turnMode) setState(() => _turnMode = mode);
  }

  /// 切换翻页动效并持久化
  Future<void> _toggleTurnMode() async {
    final ReadingTurnMode next = _turnMode == ReadingTurnMode.cover
        ? ReadingTurnMode.none
        : ReadingTurnMode.cover;
    setState(() => _turnMode = next);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _turnModePrefKey,
      next == ReadingTurnMode.cover ? 'cover' : 'none',
    );
    if (!mounted) return;
    SnackBarService.show(
      context,
      next == ReadingTurnMode.cover ? '翻页方式：覆盖' : '翻页方式：无动画',
    );
  }

  /// 翻到指定页：无动画模式直接跳页，覆盖模式滑入覆盖
  void _goToPage(int target) {
    if (_turnMode == ReadingTurnMode.none) {
      _pageController.jumpToPage(target);
      return;
    }
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  /// 包装单页：覆盖翻页时把已翻过的页固定原位，形成新页压上去的效果
  Widget _buildPageWithTurnEffect(BuildContext context, int index) {
    final Widget page = _buildPage(context, index);
    if (_turnMode == ReadingTurnMode.none) return page;
    final Widget shadowed = DecoratedBox(
      decoration: const BoxDecoration(
        boxShadow: <BoxShadow>[
          BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(-3, 0)),
        ],
      ),
      child: page,
    );
    return AnimatedBuilder(
      animation: _pageController,
      builder: (BuildContext context, Widget? child) {
        double progress = _pageIndex.toDouble();
        if (_pageController.hasClients && _pageController.position.haveDimensions) {
          progress = _pageController.page ?? progress;
        }
        // PageView 原生会把旧页左移，这里补偿回原位，新页就压在上面滑入
        final double covered = (progress - index).clamp(0.0, 1.0);
        if (covered <= 0) return child!;
        return Transform.translate(
          offset: Offset(covered * MediaQuery.sizeOf(context).width, 0),
          child: child,
        );
      },
      child: shadowed,
    );
  }

  /// 上一页：首页时回到上一章的最后一页
  void _turnBack() {
    if (_pageIndex > 0) {
      _goToPage(_pageIndex - 1);
      return;
    }
    if (_chapterIndex == 0) {
      SnackBarService.show(context, '已经是第一章');
      return;
    }
    _loadChapterWithEnd(_chapterIndex - 1);
  }

  /// 下一页：章末页时进入下一章
  void _turnForward() {
    if (_pageIndex < _pages.length - 1) {
      _goToPage(_pageIndex + 1);
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
