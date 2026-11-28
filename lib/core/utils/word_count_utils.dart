/// 字数统计工具类
///
/// - 字数 = 字符数（不含空格）
/// - 字符数（含空格）= 文本总长度
/// - 字符数（不含空格）= 去除空格后的文本长度
class WordCountUtils {
  /// 计算文本的总字数
  ///
  /// 字数 = 字符数（不含空格）
  ///
  /// 采用单次遍历逐字符判定空白，不做字符串替换与正则匹配：
  /// 该函数在每次按键后都会针对整章文本执行，旧实现
  /// `text.replaceAll(RegExp(r'\s'), '')` 会为整章文本分配一份新字符串，
  /// 长章节（数万字）下每次按键都产生一次大对象分配与全量正则扫描，
  /// 直接表现为输入时的 GC 抖动与偶发掉帧。单次遍历无额外内存分配，
  /// 判定语义与 `RegExp(r'\s')` 保持一致（ASCII 空白 + Unicode 空白）。
  static int countWords(String text) {
    if (text.isEmpty) return 0;
    var count = 0;
    for (var i = 0; i < text.length; i++) {
      if (!_isWhitespaceCodeUnit(text.codeUnitAt(i))) count++;
    }
    return count;
  }

  /// 与 `RegExp(r'\s')` 等价的空白字符判定（按 UTF-16 code unit 判定）
  ///
  /// 覆盖 Tab/LF/VT/FF/CR/空格 以及 ECMAScript `\s` 定义的 Unicode 空白字符。
  /// 使用常量集合做查表，命中路径为整数比较，无正则引擎开销。
  static bool _isWhitespaceCodeUnit(int code) {
    // 常见 ASCII 空白：先行快速判定，覆盖绝大多数文本
    if (code == 0x20 || (code >= 0x09 && code <= 0x0D)) return true;
    if (code < 0x80) return false;
    return _unicodeWhitespace.contains(code);
  }

  /// Unicode 空白码点集合（与 JS/ECMAScript `\s` 对齐）
  static const Set<int> _unicodeWhitespace = <int>{
    0x00A0, // NO-BREAK SPACE
    0x1680, // OGHAM SPACE MARK
    0x2000, // EN QUAD
    0x2001, // EM QUAD
    0x2002, // EN SPACE
    0x2003, // EM SPACE
    0x2004, // THREE-PER-EM SPACE
    0x2005, // FOUR-PER-EM SPACE
    0x2006, // SIX-PER-EM SPACE
    0x2007, // FIGURE SPACE
    0x2008, // PUNCTUATION SPACE
    0x2009, // THIN SPACE
    0x200A, // HAIR SPACE
    0x2028, // LINE SEPARATOR
    0x2029, // PARAGRAPH SEPARATOR
    0x202F, // NARROW NO-BREAK SPACE
    0x205F, // MEDIUM MATHEMATICAL SPACE
    0x3000, // IDEOGRAPHIC SPACE
    0xFEFF, // ZERO WIDTH NO-BREAK SPACE
  };

  /// 格式化字数为易读字符串（带"字"/"万字"后缀）
  ///
  /// [wanThreshold] 使用"万"为单位的字数阈值，低于该值显示完整数字。
  /// 默认一万，统计界面传十万即十万以上才显示万。
  ///
  /// 示例（wanThreshold = 10000）：
  /// - 8000 -> "8000 字"
  /// - 10000 -> "1 万字"
  /// - 125000 -> "12.5 万字"
  static String formatWordCount(int count, {int wanThreshold = 10000}) {
    if (count < wanThreshold) {
      return '$count 字';
    } else {
      final wan = count / 10000.0;
      final formatted = wan.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');
      return '$formatted 万字';
    }
  }

  /// 格式化字数为简短数值（不带后缀），用于坐标轴、tooltip 等纯数值展示
  ///
  /// [wanThreshold] 使用"万"为单位的字数阈值，低于该值显示完整数字。
  static String formatWordCountShort(int count, {int wanThreshold = 10000}) {
    if (count < wanThreshold) {
      return '$count';
    } else {
      final wan = count / 10000.0;
      return '${wan.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '')}万';
    }
  }

  /// 获取详细的字数统计信息
  static WordCountResult countWordsDetail(String text) {
    if (text.isEmpty) {
      return const WordCountResult(
        wordCount: 0,
        chineseChars: 0,
        nonChineseWords: 0,
        paragraphs: 0,
        punctuation: 0,
        numbers: 0,
        characters: 0,
        charactersWithoutSpaces: 0,
      );
    }

    // 字数 = 字符数（不含空格）
    final wordCount = text.replaceAll(RegExp(r'\s'), '').length;

    // 中文字符数（汉字）
    final chineseChars = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;

    // 非中文单词数（英文单词）
    final nonChineseWords = RegExp(r'[a-zA-Z]+').allMatches(text).length;

    // 段落数（非空行）
    final paragraphs = text
        .split(RegExp(r'\n'))
        .where((line) => line.trim().isNotEmpty)
        .length;

    // 标点符号数（中文标点 + 英文标点）
    final chinesePunctuation = RegExp(r'[\u3000-\u303F\uFF01-\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF5E\uFF61-\uFF65]').allMatches(text).length;
    final englishPunctuation = RegExp(r'''[!"#$%&'()*+,\-./:;<=>?@\[\]^_`{|}~]''').allMatches(text).length;
    final punctuation = chinesePunctuation + englishPunctuation;

    // 数字数
    final numbers = RegExp(r'\d+').allMatches(text).length;

    // 字符数（含空格、换行）
    final characters = text.length;

    // 字符数（不含空格）
    final charactersWithoutSpaces = wordCount;

    return WordCountResult(
      wordCount: wordCount,
      chineseChars: chineseChars,
      nonChineseWords: nonChineseWords,
      paragraphs: paragraphs,
      punctuation: punctuation,
      numbers: numbers,
      characters: characters,
      charactersWithoutSpaces: charactersWithoutSpaces,
    );
  }
}

/// 字数统计结果
class WordCountResult {
  /// 字数（字符数，不含空格）
  final int wordCount;

  /// 中文字符数（汉字）
  final int chineseChars;

  /// 非中文单词数（英文单词）
  final int nonChineseWords;

  /// 段落数
  final int paragraphs;

  /// 标点符号数
  final int punctuation;

  /// 数字数
  final int numbers;

  /// 字符数（含空格、换行）
  final int characters;

  /// 字符数（不含空格）
  final int charactersWithoutSpaces;

  const WordCountResult({
    required this.wordCount,
    required this.chineseChars,
    required this.nonChineseWords,
    required this.paragraphs,
    required this.punctuation,
    required this.numbers,
    required this.characters,
    required this.charactersWithoutSpaces,
  });
}
