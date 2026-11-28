import 'package:flutter/material.dart';

import 'package:quick_write/core/models/name_gen/name_dictionary.dart';
import 'package:quick_write/pages/workspace/name_gen/name_dictionary_editor_page.dart';

/// 显示词典编辑对话框
///
/// [dictionary] 为空表示新建词典，否则表示编辑该词典；
/// 返回编辑后的词典对象；用户取消时返回 null。
///
/// 桌面端与移动端统一使用整页编辑器：词典等同于一个章节，
/// 标题即词典名、正文即词条，不再按类别堆叠多个词组池输入框。
Future<NameDictionary?> showNameDictionaryEditorDialog({
  required BuildContext context,
  NameDictionary? dictionary,
}) {
  return pushNameDictionaryEditorPage(
    context: context,
    dictionary: dictionary,
  );
}
