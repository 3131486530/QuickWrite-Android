import 'package:flutter/material.dart';
import 'package:quick_write/core/services/chapter_word_count_service.dart';
import 'package:quick_write/core/utils/typography_extension.dart';
import 'package:quick_write/core/utils/word_count_utils.dart';

/// 今日章节字数卡片
///
/// 仅在「统计设置 - 章节字数」开关开启时展示，列出今日写过的每个章节
/// 及其当日净增字数。数据只保留当天，跨天自动清空。
class TodayChapterWordCountCard extends StatefulWidget {
  const TodayChapterWordCountCard({super.key});

  @override
  State<TodayChapterWordCountCard> createState() =>
      _TodayChapterWordCountCardState();
}

class _TodayChapterWordCountCardState extends State<TodayChapterWordCountCard> {
  @override
  void initState() {
    super.initState();
    ChapterWordCountService.instance.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: ChapterWordCountService.instance,
      builder: (context, _) {
        final service = ChapterWordCountService.instance;
        final items = service.items;

        return Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.menu_book_outlined, size: 20, color: colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      '今日章节字数',
                      style: context.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    Text(
                      WordCountUtils.formatWordCount(service.totalWords, wanThreshold: 100000),
                      style: context.bodyMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                if (items.isEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '今天还没有章节字数记录',
                    style: context.bodySmall?.copyWith(color: colorScheme.outline),
                  ),
                ] else ...[
                  const SizedBox(height: 8),
                  const Divider(height: 16),
                  // 章节较多时限制高度，内部可滚动，避免撑高统计页
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(height: 12),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final title = item.title.trim().isEmpty ? '未命名章节' : item.title;
                        return Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.bodyMedium,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              WordCountUtils.formatWordCount(item.words, wanThreshold: 100000),
                              style: context.bodyMedium?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
