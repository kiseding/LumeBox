import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import 'collection_panel.dart';
import 'poster_card.dart';

/// 本板块历史或收藏抽屉；入口决定内容，不再显示分栏。
Future<void> showReadingHistorySheet({
  required BuildContext context,
  required Section section,
  required ReadingLibrary library,
  required void Function(LibraryItem item, ReadingProgress progress) onResume,
  void Function(LibraryItem item)? onOpenItem,
  DateTime Function()? clock,
  HistoryDrawerTab initialTab = HistoryDrawerTab.records,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => ReadingHistorySheet(
      section: section,
      library: library,
      onResume: onResume,
      onOpenItem: onOpenItem,
      clock: clock,
      initialTab: initialTab,
    ),
  );
}

/// 历史抽屉本体（可单独嵌入测试）。
class ReadingHistorySheet extends StatefulWidget {
  const ReadingHistorySheet({
    super.key,
    required this.section,
    required this.library,
    required this.onResume,
    this.onOpenItem,
    this.clock,
    this.initialTab = HistoryDrawerTab.records,
  });

  final Section section;

  /// 本板块阅读库（调用方打开，本组件不负责释放）。
  final ReadingLibrary library;

  /// 点某条：续看 / 续读（由调用方决定打开什么）。
  final void Function(LibraryItem item, ReadingProgress progress) onResume;

  /// 点一条**还没读过**的收藏：打开它的详情页。
  final void Function(LibraryItem item)? onOpenItem;

  /// 测试用时钟（相对时间的基准）；为空时取当前时间。
  final DateTime Function()? clock;
  final HistoryDrawerTab initialTab;

  /// 记录条数上限（本地库，量级有限）。
  static const int maxEntries = 500;

  @override
  State<ReadingHistorySheet> createState() => _ReadingHistorySheetState();
}

/// 抽屉入口类型（界面不显示页签）。
enum HistoryDrawerTab {
  records('记录'),
  favorites('收藏');

  const HistoryDrawerTab(this.label);

  final String label;
}

class _ReadingHistorySheetState extends State<ReadingHistorySheet> {
  late final SectionImagePipeline pipeline = SectionImagePipeline(
    cacheDir: widget.library.imageCacheDir,
    memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
    diskCache: SectionImagePipeline.diskCacheFor(widget.section),
  );
  @override
  void dispose() {
    pipeline.dispose();
    super.dispose();
  }

  bool get favorites => widget.initialTab == HistoryDrawerTab.favorites;
  @override
  Widget build(BuildContext context) {
    final entries = widget.library.continueReading(limit: 1000000);
    final items = favorites
        ? widget.library.shelf()
        : entries.map((e) => e.item).toList();
    final now = (widget.clock ?? DateTime.now)();
    final title = favorites ? '收藏' : '历史';
    void open(LibraryItem item) {
      final progress = widget.library.progress(item.itemId);
      if (progress != null) {
        widget.onResume(item, progress);
      } else {
        widget.onOpenItem?.call(item);
      }
    }

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: Column(
              children: [
                ListTile(
                  title: Text('${widget.section.label} · $title'),
                  subtitle: Text('${items.length} 条 · 最近在前'),
                  trailing: IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                Expanded(
                  child: CollectionPanel(
                    title: title,
                    ids: items.map((e) => e.itemId).toList(),
                    library: widget.library,
                    storageKey:
                        'collection.${favorites ? 'favorites' : 'history'}.layout',
                    onDelete: (ids) async {
                      for (final id in ids) {
                        if (favorites) {
                          widget.library.removeFavorite(id);
                        } else {
                          widget.library.removeHistory(id);
                        }
                      }
                      setState(() {});
                    },
                    itemBuilder: (index) {
                      final item = items[index];
                      return HistoryEntryTile(
                        item: item,
                        progress: widget.library.progress(item.itemId),
                        now: now,
                        onResume: () => open(item),
                      );
                    },
                    gridBuilder: (index) {
                      final item = items[index];
                      return GlassCard(
                        onTap: () => open(item),
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: PosterCover(
                                    pipeline: pipeline,
                                    url: item.cover,
                                    title: item.title,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                            Text(
                              widget.library
                                      .progress(item.itemId)
                                      ?.describe() ??
                                  '尚未开始',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一条历史记录：标题 + 进度文案 + 相对时间 + 进度条。
///
/// 历史抽屉与视频播放历史页共用这一份，避免两处各长一副样子。
/// [progress] 允许为空（收藏页签里「收藏了还没读」的那些条目）：此时不画进度条、
/// 时间取加入时间，文案写明「还没开始读」。
class HistoryEntryTile extends StatelessWidget {
  const HistoryEntryTile({
    super.key,
    required this.item,
    required this.progress,
    required this.now,
    required this.onResume,
    this.onRemove,
  });

  final LibraryItem item;
  final ReadingProgress? progress;
  final DateTime now;
  final VoidCallback onResume;

  /// 删除这条记录；为空时不显示删除按钮（小说 / 漫画的抽屉只读）。
  final VoidCallback? onRemove;

  /// 进度条比例：只有算得出比例的形状才画（漫画是页位置，没有总页数）。
  static double? ratioOf(ReadingProgress progress) => switch (progress) {
    VideoProgress p => p.ratio,
    NovelProgress p => p.chapterLength > 0 ? p.chapterRatio : null,
    ComicProgress _ => null,
  };

  /// 是否已看完（只有视频有「看完」这个明确口径）。
  static bool isFinished(ReadingProgress progress) =>
      progress is VideoProgress && progress.isFinished;

  @override
  Widget build(BuildContext context) {
    final saved = progress;
    final ratio = saved == null ? null : ratioOf(saved);
    final finished = saved != null && isFinished(saved);
    return GlassCard(
      radius: 14,
      padding: EdgeInsets.fromLTRB(14, 12, onRemove == null ? 14 : 6, 12),
      onTap: onResume,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: LumeTheme.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      relativeTime(now, progress?.updatedAt ?? item.addedAt),
                      style: TextStyle(fontSize: 11, color: LumeTheme.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        progress?.describe() ?? '还没开始读',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                      ),
                    ),
                    if (finished)
                      Text(
                        '已看完',
                        style: TextStyle(fontSize: 11, color: LumeTheme.muted),
                      ),
                  ],
                ),
                if (ratio != null) ...<Widget>[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 3,
                      backgroundColor: LumeTheme.fillStrong,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        finished ? LumeTheme.muted : LumeTheme.textPrimary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              tooltip: '删除记录',
              icon: Icon(Icons.close, size: 18, color: LumeTheme.muted),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }

  /// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前 / 具体日期。
  static String relativeTime(DateTime now, DateTime time) {
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }
}
