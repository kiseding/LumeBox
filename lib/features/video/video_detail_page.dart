import 'tmdb_artwork.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../shared/widgets/glass_card.dart';
import '../reading/poster_card.dart';
import 'source_playback.dart';
import 'video_play_target.dart';

typedef OpenVideoPlayer = Future<void> Function(
  PlayerMedia media,
  VideoPlayTarget target,
  List<VideoQuality> qualities,
  PlayerPrelaunch? prelaunch,
);

/// Detail first: selecting an episode never creates a player or resolves media.
class VideoDetailPage extends StatefulWidget {
  const VideoDetailPage({
    super.key,
    this.source,
    this.loadSource,
    this.sourceId,
    required this.item,
    required this.library,
    required this.onPlay,
    this.prelaunch,
  });
  final DataSource? source;
  final Future<DataSource?> Function()? loadSource;
  final String? sourceId;
  final SourceItem item;
  final ReadingLibrary library;
  final OpenVideoPlayer onPlay;
  final PlayerPrelaunch? Function()? prelaunch;
  @override
  State<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends State<VideoDetailPage> {
  late final tmdb = TmdbDetailController(widget.item.title);
  DataSource? _source;
  SourceDetail? detail;
  String? get sourceCover => detail?.cover?.trim().isNotEmpty == true
      ? detail!.cover
      : widget.item.cover;
  List<SourceChapter> chapters = [];
  int selected = 0;
  bool loading = true, resolving = false;
  String? error;
  late final pipeline = SectionImagePipeline(
    cacheDir: widget.library.imageCacheDir,
  );
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    tmdb.dispose();
    pipeline.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final source = widget.source ?? await widget.loadSource?.call();
      if (source == null) throw StateError('源不可用（未启用或脚本加载失败）');
      _source = source;
      final direct = SourcePlayback.itemAddress(widget.item.id);
      SourceDetail? metadata;
      try {
        metadata = await source.detail(widget.item.id);
      } catch (_) {
        // Some video sources only implement episodes/content. Metadata is optional.
      }
      detail = metadata;
      final episodes = direct == null
          ? await source.chapters(widget.item.id)
          : [SourceChapter(id: widget.item.id, title: '正片')];
      if (!mounted) return;
      final saved = widget.library.videoProgress(widget.item.id);
      var index = episodes.indexWhere((e) => e.id == saved?.chapterId);
      if (index < 0) index = 0;
      setState(() {
        detail = metadata;
        chapters = episodes;
        selected = index;
        loading = false;
      });
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = '$failure';
          loading = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('加载失败：$failure')));
          }
        });
      }
    }
  }

  Future<void> play() async {
    if (resolving || chapters.isEmpty) return;
    setState(() => resolving = true);
    PlayerPrelaunch? prepared;
    try {
      final chapter = chapters[selected];
      final direct = SourcePlayback.itemAddress(widget.item.id);
      prepared = widget.prelaunch?.call();
      final content = direct == null
          ? await _source!.content(
              itemId: widget.item.id,
              chapterId: chapter.id,
            )
          : null;
      final address = direct ?? SourcePlayback.contentAddress(content);
      if (address == null) throw StateError('源未返回有效的视频播放地址');
      if (!mounted) return;
      final transferred = prepared;
      prepared = null;
      await widget.onPlay(
        PlayerMedia(
          uri: address,
          title: '${widget.item.title} · ${chapter.title}',
          headers: direct == null
              ? SourcePlayback.contentHeaders(content, source: _source!)
              : null,
        ),
        VideoPlayTarget(
          sourceId: _source!.id,
          itemId: widget.item.id,
          title: widget.item.title,
          cover: widget.item.cover,
          chapterIndex: selected,
          chapterId: chapter.id,
          chapterTitle: chapter.title,
        ),
        SourcePlayback.contentQualities(content, source: _source!),
        transferred,
      );
      if (mounted) {
        final last = widget.library.videoProgress(widget.item.id);
        final index = chapters.indexWhere(
          (entry) => entry.id == last?.chapterId,
        );
        if (index >= 0) setState(() => selected = index);
      }
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('解析失败：$failure')));
      }
    } finally {
      if (prepared != null) unawaited(prepared.discard());
      if (mounted) setState(() => resolving = false);
    }
  }

  void favorite() {
    if (widget.library.onShelf(widget.item.id)) {
      widget.library.removeFavorite(widget.item.id);
    } else {
      widget.library.shelve(
        sourceId: _source!.id,
        itemId: widget.item.id,
        title: detail?.title ?? widget.item.title,
        cover: sourceCover,
      );
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tmdb,
    builder: (context, _) => GlassScaffold(
      title: widget.item.title,
      actions: [TmdbRematchMenu(controller: tmdb)],
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 110,
                      height: 160,
                      child: TmdbPosterGallery(
                        controller: tmdb,
                        fallback: PosterCover(
                          pipeline: pipeline,
                          url: sourceCover,
                          title: widget.item.title,
                          headers:
                              detail?.coverHeaders ?? widget.item.coverHeaders,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            detail?.title ?? widget.item.title,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          Text(detail?.subtitle ?? widget.item.subtitle ?? ''),
                          TextButton.icon(
                            onPressed: _source == null ? null : favorite,
                            icon: Icon(
                              widget.library.onShelf(widget.item.id)
                                  ? Icons.bookmark
                                  : Icons.bookmark_outline,
                            ),
                            label: Text(
                              widget.library.onShelf(widget.item.id)
                                  ? '已收藏'
                                  : '收藏',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TmdbInformation(controller: tmdb),
                const Text('简介'),
                const SizedBox(height: 8),
                Text(
                  tmdb.metadata?.overview.trim().isNotEmpty == true
                      ? tmdb.metadata!.overview
                      : (detail?.description?.trim().isNotEmpty == true
                            ? detail!.description!
                            : '暂无简介'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!),
                  TextButton(onPressed: load, child: const Text('重试')),
                ],
                const SizedBox(height: 20),
                Text('选集（${chapters.length}）'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var index = 0; index < chapters.length; index++)
                      ChoiceChip(
                        key: ValueKey('video-detail-episode-$index'),
                        label: Text(chapters[index].title),
                        selected: index == selected,
                        onSelected: resolving
                            ? null
                            : (_) => setState(() => selected = index),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const Key('video-detail-play'),
                  onPressed: resolving || chapters.isEmpty ? null : play,
                  icon: resolving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: Text(resolving ? '正在解析' : '播放'),
                ),
              ],
            ),
    ),
  );
}
