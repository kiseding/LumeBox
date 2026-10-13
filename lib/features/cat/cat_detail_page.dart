import 'package:flutter/material.dart';

import '../../core/cat/cat_data_source.dart';
import '../../core/source/source.dart';
import '../../core/reading/reading.dart';
import '../../core/player/abstract_player.dart';
import '../../shared/widgets/glass_card.dart';
import '../video/video_player_page.dart';
import '../video/video_play_target.dart';
import '../reading/section_image.dart';

class CatDetailPage extends StatefulWidget {
  const CatDetailPage({
    super.key,
    required this.source,
    required this.item,
    required this.library,
  });
  final CatDataSource source;
  final SourceItem item;
  final ReadingLibrary library;
  @override
  State<CatDetailPage> createState() => _CatDetailPageState();
}

class _CatDetailPageState extends State<CatDetailPage> {
  late final pipeline = SectionImagePipeline(
    cacheDir: widget.library.imageCacheDir,
    memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
    maxConcurrent: SectionImagePipeline.coverConcurrency,
  );
  SourceDetail? detail;
  List<SourceChapter> chapters = [];
  String? error;
  bool loading = true, playing = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    pipeline.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final data = await widget.source.detail(widget.item.id);
      final episodes = await widget.source.chapters(widget.item.id);
      if (mounted) {
        setState(() {
          detail = data;
          chapters = episodes;
          loading = false;
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = '$failure';
          loading = false;
        });
      }
    }
  }

  Future<void> play(int index) async {
    if (playing) return;
    setState(() => playing = true);
    try {
      final chapter = chapters[index];
      final content = await widget.source.content(
        itemId: widget.item.id,
        chapterId: chapter.id,
      );
      if (content is! VideoContent) throw StateError('站点未返回视频地址');
      if (!mounted) return;
      widget.source.service.playInfo = {
        'name': widget.item.title,
        'title': widget.item.title,
        'episode': chapter.title,
        'epName': chapter.title,
        'url': content.url.toString(),
      };
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => VideoPlayerPage(
            media: PlayerMedia(
              uri: content.url,
              headers: content.headers,
              title: '${widget.item.title} · ${chapter.title}',
            ),
            library: widget.library,
            sourceManager: CatSourceManager(
              widget.source.service,
              widget.source.site,
            ),
            sourceId: widget.source.id,
            qualities: content.qualities,
            target: VideoPlayTarget(
              sourceId: widget.source.id,
              itemId: widget.item.id,
              title: widget.item.title,
              cover: widget.item.cover,
              chapterIndex: index,
              chapterId: chapter.id,
              chapterTitle: chapter.title,
            ),
          ),
        ),
      );
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$failure')));
      }
    } finally {
      if (mounted) setState(() => playing = false);
    }
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: widget.item.title,
    actions: [
      IconButton(
        tooltip: '收藏',
        icon: Icon(
          widget.source.service.favorites.contains(
                '${widget.source.id}|${widget.item.id}',
              )
              ? Icons.bookmark
              : Icons.bookmark_outline,
        ),
        onPressed: () async {
          await widget.source.service.toggleFavorite(widget.source.site, {
            'id': widget.item.id,
            'title': widget.item.title,
            'cover': widget.item.cover,
            'headers': widget.item.coverHeaders,
          });
          if (mounted) setState(() {});
        },
      ),
    ],
    child: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error!),
                TextButton(onPressed: load, child: const Text('重试')),
              ],
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: SizedBox(
                  width: 140,
                  height: 200,
                  child: SectionImage(
                    pipeline: pipeline,
                    url: detail?.cover ?? widget.item.cover ?? '',
                    headers: detail?.coverHeaders ?? widget.item.coverHeaders,
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (detail?.description?.isNotEmpty == true)
                GlassCard(child: Text(detail!.description!)),
              const SizedBox(height: 12),
              Text('剧集与线路（${chapters.length}）'),
              if (playing) const LinearProgressIndicator(),
              if (chapters.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('这个站点没有返回剧集。目录站点可继续选择分类，网盘站点可到源配置中心登录。'),
                ),
              for (var index = 0; index < chapters.length; index++)
                ListTile(
                  title: Text(chapters[index].title),
                  trailing: const Icon(Icons.play_circle_outline),
                  onTap: playing ? null : () => play(index),
                ),
            ],
          ),
  );
}
