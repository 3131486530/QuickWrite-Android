import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:uuid/uuid.dart';

import 'package:quick_write/core/models/name_gen/name_dictionary.dart';
import 'package:quick_write/core/services/settings_service.dart';
import 'package:quick_write/core/utils/color_utils.dart';
import 'package:quick_write/core/utils/platform_capabilities.dart';
import 'package:quick_write/core/utils/typography_extension.dart';
import 'package:quick_write/shared/widgets/qw_text_field.dart';

/// 打开词典编辑页
///
/// [dictionary] 为空表示新建词典，否则表示编辑该词典；
/// 返回编辑后的词典对象；用户放弃编辑时返回 null。
///
/// 词典等同于一个章节：页面标题即词典名，正文即词条，一行一条。
/// 页面只由「标题栏 + 单个编辑器」两层构成，不做任何按键盘高度增删
/// 子节点的布局调整，因此输入法弹起时组件树结构不变、焦点不丢失。
Future<NameDictionary?> pushNameDictionaryEditorPage({
  required BuildContext context,
  NameDictionary? dictionary,
}) {
  return Navigator.of(context).push<NameDictionary>(
    MaterialPageRoute<NameDictionary>(
      builder: (_) => NameDictionaryEditorPage(dictionary: dictionary),
    ),
  );
}

/// 词典编辑页（章节式）
class NameDictionaryEditorPage extends StatefulWidget {
  const NameDictionaryEditorPage({super.key, this.dictionary});

  /// 待编辑的词典，为空表示新建
  final NameDictionary? dictionary;

  @override
  State<NameDictionaryEditorPage> createState() =>
      _NameDictionaryEditorPageState();
}

class _NameDictionaryEditorPageState extends State<NameDictionaryEditorPage> {
  late final TextEditingController _nameController;
  late final FocusNode _nameFocusNode;
  late final FocusNode _editorFocusNode;
  late final CodeLineEditingController _editor;

  @override
  void initState() {
    super.initState();
    final NameDictionary? dictionary = widget.dictionary;
    _nameController = TextEditingController(text: dictionary?.name ?? '');
    _nameFocusNode = FocusNode();
    _editorFocusNode = FocusNode();

    // 旧的多池词典打开时展平为词条列表，保存后即成为章节式词典
    final List<String> entries = dictionary == null
        ? const <String>[]
        : (dictionary.isEntryList ? dictionary.entries : dictionary.allEntries);
    _editor = CodeLineEditingController.fromText(entries.join('\n'));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocusNode.dispose();
    _editorFocusNode.dispose();
    _editor.dispose();
    super.dispose();
  }

  /// 解析编辑器正文为词条列表
  ///
  /// 以换行为主，兼容顿号、逗号分隔；去空行并去重，保持原有顺序。
  List<String> _parseEntries(String text) {
    final Set<String> result = <String>{};
    for (final String raw in text.split(RegExp(r'[\r\n、，,]+'))) {
      final String entry = raw.trim();
      if (entry.isNotEmpty) result.add(entry);
    }
    return result.toList();
  }

  /// 保存并返回
  void _handleSave() {
    final String name = _nameController.text.trim();
    final NameDictionary? origin = widget.dictionary;
    final NameDictionary dictionary = NameDictionary.entryList(
      id: origin?.id ?? const Uuid().v4(),
      name: name.isEmpty ? '未命名词典' : name,
      entries: _parseEntries(_editor.text),
      orderIndex: origin?.orderIndex ?? NameDictionary.customOrderStart,
    );
    Navigator.of(context).pop(dictionary);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: QwTextField(
          controller: _nameController,
          focusNode: _nameFocusNode,
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: '词典名',
            hintStyle: context.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          style: context.titleMedium,
          maxLines: 1,
          textInputAction: TextInputAction.done,
          // 只让标题输入框自己失焦，不清理整个焦点域，避免编辑器被动重建
          onTapOutside: (_) => _nameFocusNode.unfocus(),
        ),
        actions: [
          TextButton(
            onPressed: _handleSave,
            child: const Text('保存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(top: false, child: _buildEditor(context)),
    );
  }

  /// 全屏编辑器：正文即词条，回车换行
  Widget _buildEditor(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final bool breathing = PlatformCapabilities.isMobile &&
        SettingsService.instance.settings.breathingCursorEnabled;
    return CodeEditor(
      controller: _editor,
      focusNode: _editorFocusNode,
      autofocus: false,
      wordWrap: true,
      hint: '一行一个词条',
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      staticCursor: SettingsService.instance.settings.staticCursorEnabled,
      breathingCursor: breathing,
      style: CodeEditorStyle(
        fontSize: 16,
        fontHeight: 1.6,
        textColor: ColorUtils.getFontColorForTheme(context),
        backgroundColor: Colors.transparent,
        cursorColor:
            ColorUtils.getCursorColorForTheme(context, colorScheme.primary),
        cursorWidth: 2,
        selectionColor: colorScheme.primary.withValues(alpha: 0.25),
        highlightColor: colorScheme.primary.withValues(alpha: 0.25),
      ),
    );
  }
}
