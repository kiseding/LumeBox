import 'video_episode_catalog.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/lume_icon.dart';
import '../settings/tmdb_settings_page.dart';

import 'dart:ui' as ui;

import '../../core/theme/cover_palette.dart';
import '../../shared/widgets/source_translation.dart';
import '../../shared/widgets/network_owned_state.dart';
import '../../core/net/network_cancellation.dart';

import '../../core/media/media_library.dart';
import '../../core/media/media_resource_service.dart';
import '../reading/search_results_page.dart';
import '../reading/explore_view.dart';
import '../reading/section_toolbar.dart';
import '../media/media_resource_router.dart';
import 'tmdb_artwork.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/player_experience_store.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/reading/comic_image_tools.dart';
import '../../core/reading/reading.dart';
import '../../core/source/source.dart';

import 'package:flutter/services.dart';

import '../reading/poster_card.dart';
import 'bangumi_match_sheet.dart';
import 'source_playback.dart';
import 'source_web_player_page.dart';
import 'video_play_target.dart';
import '../../core/cat/cat_web_parse.dart';
import '../cat/cat_web_parse_page.dart';

typedef OpenVideoPlayer = Future<void> Function(
  PlayerMedia media,
  VideoPlayTarget target,
  List<VideoQuality> qualities,
  PlayerPrelaunch? prelaunch,
);

/// Episode selection opens playback; the play button remains a second entry.
class VideoDetailPage extends StatefulWidget {
  const VideoDetailPage({
    super.key,
    this.source,
    this.loadSource,
    this.sourceId,
    this.manager,
    this.recordHistory = true,
    this.imagePipeline,
    required this.item,
    required this.library,
    required this.onPlay,
    this.prelaunch,
  });
  final DataSource? source;
  final Future<DataSource?> Function()? loadSource;
  final String? sourceId;
  final SourceManager? manager;
  final bool recordHistory;
  final SectionImagePipeline? imagePipeline;
  final SourceItem item;
  final ReadingLibrary library;
  final OpenVideoPlayer onPlay;
  final PlayerPrelaunch? Function()? prelaunch;
  @override
  State<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends State<VideoDetailPage>
    with NetworkOwnedState<VideoDetailPage> {
  late final tmdb = TmdbDetailController(widget.item.title);
  DataSource? _source;
  SourceDetail? detail;
  String? get sourceCover => detail?.cover?.trim().isNotEmpty == true
      ? detail!.cover
      : widget.item.cover;
  List<SourceChapter> chapters = [];
  int selected = 0;
  Map<String, List<SourceChapter>> lines = {};
  String currentLine = '';
  bool descriptionExpanded = false, reversed = false, collapsedHeader = false;
  int episodePage = 0;
  bool originalStyle = true;
  final _episodesKey = GlobalKey();
  final _scroll = ScrollController();

  bool loading = true, resolving = false;
  String? error;
  late final pipeline =
      widget.imagePipeline ??
      SectionImagePipeline(
        cacheDir: widget.library.imageCacheDir,
        decodeTransform: (bytes) =>
            automaticUpscale(bytes, UpscaleSurface.videoPoster),
      );
  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final collapsed = _scroll.offset > 170;
      if (collapsed != collapsedHeader && mounted) {
        setState(() => collapsedHeader = collapsed);
      }
    });
    unawaited(load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    tmdb.dispose();
    if (widget.imagePipeline == null) pipeline.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      await networkRequests.run('detail', loadOwned);
    } on NetworkCancelled {
      // Leaving the page or replacing this load is not a source failure.
    }
  }

  Future<void> loadOwned() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final source = widget.source ?? await widget.loadSource?.call();
      if (source == null) throw StateError('源不可用（未启用或脚本加载失败）');
      _source = source;
      pipeline.bindSource(source);
      pipeline.bindSession(source.section, source.id);
      final direct = SourcePlayback.itemAddress(widget.item.id);
      SourceDetail? metadata;
      try {
        metadata = await source.detail(widget.item.id);
      } catch (_) {
        // Some video sources only implement episodes/content. Metadata is optional.
      }
      NetworkCancellation.current?.check();
      if (!mounted) return;
      final cover = metadata?.cover ?? widget.item.cover;
      if (cover != null) {
        pipeline.configureImageHeaders({
          cover: metadata?.coverHeaders ?? widget.item.coverHeaders,
        });
      }
      setState(() => detail = metadata);
      tmdb.updateTitles([
        metadata?.title ?? widget.item.title,
        widget.item.title,
      ]);
      unawaited(updatePalette());
      List<SourceChapter> episodes;
      if (direct != null) {
        episodes = [SourceChapter(id: widget.item.id, title: '正片')];
      } else {
        try {
          episodes = await source.chapters(widget.item.id);
        } catch (_) {
          if (metadata?.chapters.isNotEmpty != true) rethrow;
          episodes = metadata!.chapters;
        }
        if (episodes.isEmpty && metadata?.chapters.isNotEmpty == true) {
          episodes = metadata!.chapters;
        }
      }
      if (!mounted) return;
      final saved = widget.library.videoProgress(widget.item.id);
      final grouped = VideoEpisodeCatalog.group(episodes);
      final resumed = episodes
          .where((e) => e.id == saved?.chapterId)
          .firstOrNull;
      final line = resumed == null
          ? grouped.keys.firstOrNull ?? ''
          : VideoEpisodeCatalog.lineOf(resumed);
      final activeEpisodes = grouped[line] ?? <SourceChapter>[];
      var index = activeEpisodes.indexWhere((e) => e.id == saved?.chapterId);
      if (index < 0) index = 0;
      setState(() {
        detail = metadata;
        lines = grouped;
        currentLine = line;
        chapters = activeEpisodes;
        selected = index;
        episodePage = index ~/ 50;
        loading = false;
      });
      tmdb.updateTitles([
        metadata?.title ?? widget.item.title,
        widget.item.title,
      ]);
      // 查看详情只写历史（favorite = 0）；收藏只能由心形按钮触发。
      if (widget.recordHistory) {
        widget.library.recordHistoryItem(
          sourceId: source.id,
          itemId: widget.item.id,
          title: metadata?.title ?? widget.item.title,
          cover: sourceCover,
          subtitle: metadata?.subtitle ?? widget.item.subtitle,
          chapterCount: activeEpisodes.length,
        );
      }
    } catch (failure) {
      if (NetworkCancellation.current?.isCancelled ?? false) return;
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
      ChapterContent? content;
      {
        try {
          content = await _source!.content(
            itemId: widget.item.id,
            chapterId: chapter.id,
          );
        } on CatWebParseRequired catch (request) {
          if (!mounted) return;
          if (request.webPlayer) {
            await showSourceWebPlayer(context, request);
            return;
          }
          final parsed = await showCatWebParsePage(context, request);
          if (parsed == null || !mounted) return;
          content = VideoContent(
            url: parsed,
            headers: {...request.headers, 'Referer': request.page.toString()},
          );
        } catch (_) {
          if (direct == null) rethrow;
          content = VideoContent(url: direct);
        }
      }
      if (!mounted) return;
      await MediaLibrary.instance.boot();
      final saved = MediaLibrary.instance.byId(
        MediaResource.sourceKey(_source!.section, _source!.id, widget.item.id),
      );
      final address =
          SourcePlayback.contentAddress(content) ??
          direct ??
          MediaResourceService.address(content);
      if (address == null) throw StateError('源未返回有效的播放地址');
      final tracks = saved?.manual == true
          ? const MediaTrackInfo()
          : await const MediaTrackProbe().inspect(
              address,
              headers: SourcePlayback.contentHeaders(content, source: _source!),
            );
      if ((saved?.manual == true && saved!.kind != ResourceKind.video) ||
          (saved?.manual != true &&
              (tracks.kind == ResourceKind.audioBook ||
                  !tracks.known &&
                      (content is VideoContent && content.audioOnly ||
                          RegExp(
                            r'\.(mp3|m4a|aac|flac|ogg|opus|wav)$',
                            caseSensitive: false,
                          ).hasMatch(address.path))))) {
        final entry = saved?.manual == true
            ? saved!
            : await MediaResourceService().source(
                source: _source!,
                item: widget.item,
                chapters: chapters,
                firstContent:
                    content ?? VideoContent(url: address, audioOnly: true),
                hint: ResourceKind.audioBook,
              );
        if (!mounted) return;
        await openMediaResource(context, entry, index: selected);
        widget.library.refresh();
        return;
      }
      if (!mounted) return;
      prepared = widget.prelaunch?.call();
      final transferred = prepared;
      prepared = null;
      await widget.onPlay(
        PlayerMedia(
          uri: address,
          title:
              '${widget.item.title} · ${VideoEpisodeCatalog.labelOf(chapter)}',
          headers: SourcePlayback.contentHeaders(content, source: _source!),
        ),
        VideoPlayTarget(
          sourceId: _source!.id,
          itemId: widget.item.id,
          title: widget.item.title,
          cover: widget.item.cover,
          chapterIndex: selected,
          chapterId: chapter.id,
          chapterTitle: VideoEpisodeCatalog.labelOf(chapter),
        ),
        SourcePlayback.contentQualities(content, source: _source!),
        transferred,
      );
      widget.library.refresh();
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

  Color? _coverColor;
  Color get _pageColor {
    if (originalStyle) {
      return _coverColor == null
          ? const Color(0xff55516e)
          : Color.lerp(_coverColor, const Color(0xff686183), .55)!;
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? const Color(0xff11131a) : const Color(0xfff7f7fa);
    if (_coverColor == null) return base;
    return Color.lerp(base, _coverColor, dark ? .12 : .045)!;
  }

  Future<void> updatePalette() async {
    final cover = sourceCover;
    if (cover == null || cover.isEmpty) return;
    try {
      final sample = await pipeline.colorSample(cover);
      if (sample == null) return;
      Color? color;
      try {
        final pixels = await sample.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (pixels != null) {
          color = dominantCoverColor(pixels.buffer.asUint8List());
        }
      } finally {
        sample.dispose();
      }
      if (color == null || cover != sourceCover) return;
      if (mounted) {
        setState(() => _coverColor = color);
      }
    } catch (_) {
      /* Keep the soft poster fallback for unavailable images. */
    }
  }

  Future<void> searchCurrentVideo([String? keyword]) async {
    final source = _source;
    if (source == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SearchResultsPage(
          section: widget.library.section,
          keyword: keyword ?? detail?.title ?? widget.item.title,
          mode: SearchMode.aggregate,
          manager: widget.manager,
          onOpenItem: (ExploreSelection selection) async {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => VideoDetailPage(
                  sourceId: selection.sourceId,
                  manager: widget.manager,
                  loadSource: () =>
                      (widget.manager ??
                              LumeSources.manager(widget.library.section))
                          .open(selection.sourceId),
                  item: selection.item,
                  library: widget.library,
                  onPlay: widget.onPlay,
                  prelaunch: widget.prelaunch,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      originalStyle ? _buildOriginal(context) : _buildCompact(context);

  Widget styleMenu() => PopupMenuButton<bool>(
    key: const Key('video-detail-style'),
    tooltip: '详情页样式',
    icon: const Icon(Icons.view_carousel_outlined),
    onSelected: (value) {
      setState(() => originalStyle = value);
      if (_scroll.hasClients) _scroll.jumpTo(0);
    },
    itemBuilder: (_) => [
      CheckedPopupMenuItem(
        value: true,
        checked: originalStyle,
        child: const Text('大封面版（旧版）'),
      ),
      CheckedPopupMenuItem(
        value: false,
        checked: !originalStyle,
        child: const Text('紧凑版（当前版）'),
      ),
    ],
  );

  Widget metadataRow(String subtitle, String title) => Row(
    key: const Key('video-detail-metadata-row'),
    children: [
      Expanded(
        child: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: originalStyle ? TextAlign.center : TextAlign.left,
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            color: originalStyle
                ? Colors.white
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      if (tmdb.metadata != null)
        IconButton(
          key: const Key('video-detail-tmdb-status'),
          tooltip:
              'TMDB 已匹配${tmdb.metadata!.cast.isEmpty ? '' : ' · ${tmdb.metadata!.cast.length} 位演员'}',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const TmdbSettingsPage()),
          ),
          icon: Icon(
            Icons.verified_outlined,
            size: 18,
            color: originalStyle ? Colors.white70 : null,
          ),
        ),
      SourceTranslationAction(texts: [title, synopsis]),
    ],
  );

  String get synopsis => tmdb.metadata?.overview.trim().isNotEmpty == true
      ? tmdb.metadata!.overview
      : detail?.description?.trim().isNotEmpty == true
      ? detail!.description!
      : '暂无简介';

  Widget summaryBlock(String title, String text) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      InkWell(
        key: const Key('video-detail-summary'),
        onTap: () => setState(() => descriptionExpanded = !descriptionExpanded),
        child: SourceText(
          text,
          maxLines: descriptionExpanded ? null : 2,
          overflow: descriptionExpanded ? null : TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            height: 1.6,
            color: originalStyle
                ? Colors.white
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ],
  );

  Widget linePicker() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '播放线路',
        style: TextStyle(
          fontSize: 14,
          color: originalStyle
              ? Colors.white70
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<String>(
              key: ValueKey('video-detail-line-$currentLine'),
              initialValue: lines.isEmpty ? null : currentLine,
              isExpanded: true,
              dropdownColor: _pageColor,
              style: TextStyle(
                color: originalStyle
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurface,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: originalStyle
                    ? Colors.white.withValues(alpha: .09)
                    : Colors.black.withValues(alpha: .04),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
              items: [
                for (final e in lines.entries)
                  DropdownMenuItem(
                    value: e.key,
                    child: Text(
                      '${e.key} · ${e.value.length} 集',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: resolving || lines.length < 2
                  ? null
                  : (v) {
                      if (v != null) changeLine(v);
                    },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: MediaQuery.textScalerOf(context).scale(1) > 1.3 ? 2 : 1,
            child: OutlinedButton.icon(
              // Keep the secondary entry usable with large accessibility text.
              key: const Key('video-detail-select-episodes'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: originalStyle ? Colors.white : null,
                side: BorderSide(
                  color: originalStyle ? Colors.white24 : Colors.black12,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              onPressed: chapters.isEmpty ? null : showEpisodes,
              icon: const Icon(Icons.grid_view, size: 17),
              label: const Text('选集'),
            ),
          ),
        ],
      ),
    ],
  );

  Widget episodeStrip(List<int> visible) => LayoutBuilder(
    builder: (context, bounds) {
      final width = (bounds.maxWidth - 20) / 3;
      final height = width * 9 / 16;
      return SizedBox(
        height: height + 12 + MediaQuery.textScalerOf(context).scale(13) * 1.5,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: visible.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (_, i) {
            final index = visible[i], chapter = chapters[index];
            final cover = chapter.cover?.trim().isNotEmpty == true
                ? chapter.cover
                : sourceCover;
            return SizedBox(
              width: width,
              child: InkWell(
                key: ValueKey('video-detail-episode-$index'),
                onTap: resolving ? null : () => chooseEpisode(index),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        height: height,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            PosterCover(
                              pipeline: pipeline,
                              url: cover,
                              title: chapter.title,
                              headers: chapter.coverHeaders.isEmpty
                                  ? detail?.coverHeaders ??
                                        widget.item.coverHeaders
                                  : chapter.coverHeaders,
                            ),
                            if (selected == index)
                              const Center(
                                child: Icon(
                                  Icons.play_circle_fill,
                                  color: Colors.white,
                                  size: 26,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      VideoEpisodeCatalog.labelOf(chapter),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    },
  );

  Widget quickActions() {
    final color = originalStyle
        ? Colors.white
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final saved = widget.library.onShelf(widget.item.id);
    Widget action(String label, IconData icon, VoidCallback? onPressed) =>
        SizedBox(
          width: 88,
          child: TextButton(
            onPressed: onPressed,
            style: TextButton.styleFrom(
              foregroundColor: color,
              padding: const EdgeInsets.symmetric(vertical: 10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22),
                const SizedBox(height: 4),
                Text(label, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
        );
    return Padding(
      key: const Key('video-detail-quick-actions'),
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        children: [
          action(
            '全站找片',
            Icons.search,
            _source == null ? null : () => searchCurrentVideo(),
          ),
          action(
            saved ? '已收藏' : '收藏',
            saved ? Icons.favorite : Icons.favorite_border,
            _source == null || !widget.recordHistory ? null : favorite,
          ),
          action(
            '追番',
            Icons.live_tv_outlined,
            () => showBangumiMatchSheet(
              context: context,
              library: widget.library,
              item: widget.item,
              initialTitle: detail?.title ?? widget.item.title,
            ),
          ),
        ],
      ),
    );
  }

  Widget recommendationsSection() {
    final items = tmdb.metadata?.recommendations ?? [];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const Key('video-detail-recommendations'),
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '相似影片',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '点击影片，全站查找播放源',
            style: TextStyle(
              fontSize: 11,
              color: originalStyle
                  ? Colors.white60
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, bounds) {
              final width = (bounds.maxWidth - 20) / 3;
              return SizedBox(
                height:
                    width * 1.5 +
                    8 +
                    MediaQuery.textScalerOf(context).scale(12) * 2.6,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (_, index) {
                    final item = items[index];
                    return SizedBox(
                      width: width,
                      child: InkWell(
                        onTap: () => searchCurrentVideo(item.title),
                        borderRadius: BorderRadius.circular(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                height: width * 1.5,
                                child: PosterCover(
                                  pipeline: pipeline,
                                  url: item.poster,
                                  title: item.title,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, height: 1.3),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget castSection() {
    final metadata = tmdb.metadata;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '演员',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          if (metadata == null || metadata.cast.isEmpty)
            Text(
              tmdb.loading ? '正在获取演员资料…' : '匹配到演员资料后显示头像与姓名',
              style: TextStyle(
                fontSize: 12,
                color: originalStyle
                    ? Colors.white60
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          else
            SizedBox(
              height: 110 + MediaQuery.textScalerOf(context).scale(12) * 1.5,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: metadata.cast.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (_, i) => SizedBox(
                  width: 76,
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: 76,
                          height: 104,
                          child:
                              i < metadata.profiles.length &&
                                  metadata.profiles[i].isNotEmpty
                              ? PosterCover(
                                  pipeline: pipeline,
                                  url: metadata.profiles[i],
                                  title: metadata.cast[i],
                                )
                              : const ColoredBox(
                                  color: Color(0x22666666),
                                  child: Center(
                                    child: Icon(Icons.person_outline, size: 32),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        metadata.cast[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void changeLine(String next) {
    if (next == currentLine || resolving || !lines.containsKey(next)) return;
    final label = chapters.isEmpty
        ? ''
        : VideoEpisodeCatalog.labelOf(chapters[selected]);
    final nextChapters = lines[next]!;
    final matched = nextChapters.indexWhere(
      (e) => VideoEpisodeCatalog.labelOf(e) == label,
    );
    setState(() {
      currentLine = next;
      chapters = nextChapters;
      selected = matched >= 0
          ? matched
          : selected.clamp(0, (chapters.length - 1).clamp(0, 999999));
      episodePage = selected ~/ 50;
    });
  }

  Future<void> chooseEpisode(int index) async {
    if (resolving || index < 0 || index >= chapters.length) return;
    setState(() => selected = index);
    if (PlayerExperienceStore.current.selectEpisodeOnly) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已选中剧集，点击上方播放按钮开始')));
      return;
    }
    await play();
  }

  void locateEpisodes() {
    setState(
      () => episodePage =
          (reversed ? chapters.length - 1 - selected : selected) ~/ 50,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _episodesKey.currentContext;
      if (context != null) {
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 280),
          alignment: .1,
        );
      }
    });
  }

  Widget episodeButton(int index, {bool modal = false}) {
    final chapter = chapters[index];
    final active = selected == index;
    final colors = Theme.of(context).colorScheme;
    return OutlinedButton(
      key: ValueKey(
        modal
            ? 'video-detail-picker-episode-$index'
            : 'video-detail-episode-$index',
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        foregroundColor: active ? colors.primary : colors.onSurface,
        backgroundColor: active
            ? colors.primary.withValues(alpha: .12)
            : colors.onSurface.withValues(alpha: .035),
        side: BorderSide(
          color: active
              ? colors.primary.withValues(alpha: .5)
              : colors.onSurface.withValues(alpha: .08),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: resolving
          ? null
          : () {
              if (modal) Navigator.pop(context);
              chooseEpisode(index);
            },
      child: Text(
        VideoEpisodeCatalog.labelOf(chapter),
        maxLines: 2,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }

  Widget episodeGrid(List<int> indexes, {bool modal = false}) => LayoutBuilder(
    builder: (context, bounds) {
      final count = bounds.maxWidth < 340 ? 4 : 5;
      final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: count,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          mainAxisExtent: 44 * scale,
        ),
        itemCount: indexes.length,
        itemBuilder: (_, i) => episodeButton(indexes[i], modal: modal),
      );
    },
  );

  Future<void> showEpisodes() async {
    if (chapters.isEmpty) return;
    var page = selected ~/ 50, query = '';
    var listMode = chapters.any(
      (e) => VideoEpisodeCatalog.labelOf(e).length > 18,
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refresh) {
          final order = [
            for (var i = 0; i < chapters.length; i++)
              reversed ? chapters.length - 1 - i : i,
          ];
          final filtered = order
              .where(
                (i) =>
                    VideoEpisodeCatalog.labelOf(chapters[i])
                        .toLowerCase()
                        .contains(query.toLowerCase()),
              )
              .toList();
          final pages = (filtered.length / 50).ceil().clamp(1, 999999);
          page = page.clamp(0, pages - 1);
          final visible = filtered.skip(page * 50).take(50).toList();
          return SafeArea(
            top: false,
            child: FractionallySizedBox(
              heightFactor: .78,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '选集 · $currentLine · ${chapters.length} 集',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '倒序排列',
                        onPressed: () {
                          setState(() => reversed = !reversed);
                          refresh(() => page = 0);
                        },
                        icon: const Icon(Icons.swap_vert),
                      ),
                      IconButton(
                        tooltip: listMode ? '网格显示' : '列表显示',
                        onPressed: () => refresh(() => listMode = !listMode),
                        icon: Icon(
                          listMode ? Icons.grid_view : Icons.view_list,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭选集',
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  if (lines.length > 1)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final line in lines.keys)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(line),
                                selected: line == currentLine,
                                onSelected: resolving
                                    ? null
                                    : (_) {
                                        changeLine(line);
                                        refresh(() => page = 0);
                                      },
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    decoration: const InputDecoration(
                      hintText: '搜索剧集名称',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) => refresh(() {
                      query = v;
                      page = 0;
                    }),
                  ),
                  if (pages > 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: DropdownButtonFormField<int>(
                        key: ValueKey('video-episode-picker-range-$page'),
                        initialValue: page,
                        isExpanded: true,
                        items: [
                          for (var i = 0; i < pages; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text(
                                '${i * 50 + 1}—${((i + 1) * 50).clamp(0, filtered.length)} 集',
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) refresh(() => page = v);
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (filtered.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('没有匹配的剧集'),
                    )
                  else if (listMode) ...[
                    for (final i in visible)
                      ListTile(
                        key: ValueKey('video-detail-picker-episode-$i'),
                        selected: i == selected,
                        leading: Text('${i + 1}'),
                        title: Text(
                          VideoEpisodeCatalog.labelOf(chapters[i]),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.play_circle_outline),
                        onTap: resolving
                            ? null
                            : () {
                                Navigator.pop(sheetContext);
                                chooseEpisode(i);
                              },
                      ),
                  ] else
                    episodeGrid(visible, modal: true),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget episodeSection({bool immersive = false}) {
    final order = [
      for (var i = 0; i < chapters.length; i++)
        reversed ? chapters.length - 1 - i : i,
    ];
    final page = episodePage.clamp(
      0,
      ((chapters.length - 1) ~/ 50).clamp(0, 999999),
    );
    final visible = order.skip(page * 50).take(50).toList();
    final artwork =
        immersive ||
        sourceCover?.trim().isNotEmpty == true ||
        chapters.any((e) => e.cover?.trim().isNotEmpty == true);
    return Column(
      key: _episodesKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '选集 · 共 ${chapters.length} 集',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: reversed ? '恢复正序' : '倒序排列',
              onPressed: chapters.isEmpty
                  ? null
                  : () => setState(() => reversed = !reversed),
              icon: const Icon(Icons.swap_vert, size: 20),
            ),
            IconButton(
              tooltip: '定位当前集',
              onPressed: chapters.isEmpty ? null : locateEpisodes,
              icon: const Icon(Icons.my_location_outlined, size: 19),
            ),
            TextButton(
              onPressed: chapters.isEmpty ? null : showEpisodes,
              child: const Text('全部'),
            ),
          ],
        ),
        if (chapters.length > 50)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DropdownButtonFormField<int>(
              key: ValueKey('video-episode-range-$page'),
              initialValue: page,
              isExpanded: true,
              items: [
                for (var i = 0; i < (chapters.length / 50).ceil(); i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '${i * 50 + 1}—${((i + 1) * 50).clamp(0, chapters.length)} 集',
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => episodePage = v);
              },
            ),
          ),
        if (chapters.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('暂无可用剧集'),
          )
        else if (artwork)
          episodeStrip(visible)
        else
          episodeGrid(visible),
      ],
    );
  }

  Widget _buildCompact(BuildContext context) => ListenableBuilder(
    listenable: tmdb,
    builder: (context, _) {
      final baseTheme = Theme.of(context);
      final colors = baseTheme.colorScheme;
      final title = detail?.title ?? widget.item.title;
      final description = synopsis;
      final subtitle = (detail?.subtitle ?? widget.item.subtitle ?? '')
          .replaceAll(RegExp(r'(?:更新至\s*){2,}'), '更新至')
          .replaceAll(RegExp(r'集\s*集'), '集');
      final progress = widget.library.videoProgress(widget.item.id);
      final canResume =
          chapters.isNotEmpty && progress?.chapterId == chapters[selected].id;
      return Scaffold(
        backgroundColor: _pageColor,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: collapsedHeader ? _pageColor : Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          foregroundColor: collapsedHeader ? colors.onSurface : Colors.white,
          actionsIconTheme: IconThemeData(
            color: collapsedHeader ? colors.onSurface : Colors.white,
          ),
          systemOverlayStyle:
              collapsedHeader && baseTheme.brightness == Brightness.light
              ? SystemUiOverlayStyle.dark
              : SystemUiOverlayStyle.light,
          leading: Padding(
            padding: const EdgeInsets.all(8),
            child: IconButton.filledTonal(
              tooltip: '返回',
              style: IconButton.styleFrom(
                backgroundColor: collapsedHeader
                    ? colors.onSurface.withValues(alpha: .06)
                    : Colors.black.withValues(alpha: .22),
                foregroundColor: collapsedHeader
                    ? colors.onSurface
                    : Colors.white,
                padding: EdgeInsets.zero,
              ),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
            ),
          ),
          title: collapsedHeader
              ? Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                )
              : null,
          actions: [
            styleMenu(),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (action) {
                if (action == 'search') searchCurrentVideo();
                if (action == 'tmdb') tmdb.rematch();
                if (action == 'settings') {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const TmdbSettingsPage(),
                    ),
                  );
                }
                if (action == 'bangumi') {
                  showBangumiMatchSheet(
                    context: context,
                    library: widget.library,
                    item: widget.item,
                    initialTitle: title,
                  );
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'search',
                  enabled: widget.recordHistory,
                  child: const Text('搜索同名视频'),
                ),
                const PopupMenuItem(
                  value: 'bangumi',
                  child: Text('Bangumi 追番'),
                ),
                PopupMenuItem(
                  value: 'tmdb',
                  enabled: tmdb.settings.configured && !tmdb.loading,
                  child: const Text('重新匹配TMDB'),
                ),
                const PopupMenuItem(
                  value: 'settings',
                  child: Text('TMDB 设置与测试'),
                ),
                if (tmdb.status != null)
                  PopupMenuItem(
                    enabled: false,
                    child: Text(
                      tmdb.status!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, bounds) {
            final heroHeight = (bounds.maxWidth * .82).clamp(300.0, 420.0);
            final hasArtwork =
                sourceCover?.trim().isNotEmpty == true || tmdb.metadata != null;
            return SingleChildScrollView(
              controller: _scroll,
              key: const Key('video-detail-scroll'),
              child: Stack(
                key: const Key('video-detail-immersive'),
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: heroHeight,
                    child: IgnorePointer(
                      child: TmdbPosterGallery(
                        controller: tmdb,
                        fit: BoxFit.cover,
                        fallback: PosterCover(
                          pipeline: pipeline,
                          url: sourceCover,
                          title: widget.item.title,
                          headers:
                              detail?.coverHeaders ?? widget.item.coverHeaders,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: heroHeight + 2,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        key: const Key('video-detail-gradient'),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0, .3, .52, .72, 1],
                            colors: [
                              Colors.black.withValues(alpha: .38),
                              Colors.transparent,
                              _pageColor.withValues(alpha: .4),
                              _pageColor.withValues(alpha: .94),
                              _pageColor,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      hasArtwork
                          ? heroHeight * .66
                          : MediaQuery.paddingOf(context).top +
                                kToolbarHeight +
                                24,
                      16,
                      24 + MediaQuery.paddingOf(context).bottom,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SourceText(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 24,
                            height: 1.2,
                            fontWeight: FontWeight.w700,
                            color: colors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 8),
                        metadataRow(subtitle, title),
                        summaryBlock(title, description),
                        const SizedBox(height: 18),
                        Center(
                          child: FractionallySizedBox(
                            widthFactor: .72,
                            child: FilledButton.icon(
                              key: const Key('video-detail-play'),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(50),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed:
                                  loading || resolving || chapters.isEmpty
                                  ? null
                                  : play,
                              icon: resolving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.play_arrow),
                              label: Text(
                                resolving
                                    ? '正在解析'
                                    : !canResume
                                    ? '立即播放'
                                    : '继续播放 · ${chapters.isEmpty ? '' : VideoEpisodeCatalog.labelOf(chapters[selected])}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                        quickActions(),
                        if (canResume &&
                            progress != null &&
                            progress.position > Duration.zero) ...[
                          const SizedBox(height: 10),
                          Text(
                            '上次看到 ${progress.position.inMinutes}:${progress.position.inSeconds.remainder(60).toString().padLeft(2, '0')}',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          if (progress.duration > Duration.zero)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: LinearProgressIndicator(
                                value: progress.ratio,
                                minHeight: 3,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                        ],
                        if (loading)
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        if (error != null) ...[
                          const SizedBox(height: 12),
                          Text(error!),
                          TextButton(onPressed: load, child: const Text('重试')),
                        ],
                        const SizedBox(height: 24),
                        linePicker(),
                        const SizedBox(height: 10),
                        episodeSection(),
                        castSection(),
                        recommendationsSection(),
                        if ((tmdb.metadata?.rating ?? 0) > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              'TMDB ${tmdb.metadata!.rating.toStringAsFixed(1)} / 10',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
  Widget _buildOriginal(BuildContext context) => ListenableBuilder(
    listenable: tmdb,
    builder: (context, _) {
      final dark = ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: _pageColor,
        textTheme: LumeTheme.readableTextTheme(
          Brightness.dark,
        ).apply(fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffb5b9df),
          brightness: Brightness.dark,
          surface: _pageColor,
        ),
      );
      return Theme(
        data: dark,
        child: Scaffold(
          backgroundColor: _pageColor,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            flexibleSpace: const SizedBox.expand(),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            foregroundColor: Colors.white,
            systemOverlayStyle: SystemUiOverlayStyle.light,
            actions: [
              styleMenu(),
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (v) {
                  if (v == 'retry') {
                    tmdb.rematch();
                  } else {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const TmdbSettingsPage(),
                      ),
                    );
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'retry',
                    enabled: tmdb.settings.configured && !tmdb.loading,
                    child: const Text('重新匹配TMDB'),
                  ),
                  const PopupMenuItem(
                    value: 'settings',
                    child: Text('TMDB 设置与测试'),
                  ),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final artworkHeight = (constraints.maxWidth * 1.48).clamp(
                460.0,
                760.0,
              );
              return SingleChildScrollView(
                controller: _scroll,
                key: const Key('video-detail-scroll'),
                child: Stack(
                  key: const Key('video-detail-immersive'),
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: artworkHeight,
                      child: IgnorePointer(
                        child: TmdbPosterGallery(
                          controller: tmdb,
                          fit: BoxFit.cover,
                          fallback: PosterCover(
                            pipeline: pipeline,
                            url: sourceCover,
                            title: widget.item.title,
                            headers:
                                detail?.coverHeaders ??
                                widget.item.coverHeaders,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: artworkHeight + 2,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          key: const Key('video-detail-gradient'),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: [0, .32, .55, .76, .92, 1],
                              colors: [
                                Color(0x55151820),
                                Color(0x00151820),
                                Color(0x33151820),
                                _pageColor.withValues(alpha: .65),
                                _pageColor.withValues(alpha: .95),
                                _pageColor,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        artworkHeight * .61,
                        16,
                        24 + MediaQuery.paddingOf(context).bottom,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SourceText(
                            detail?.title ?? widget.item.title,
                            textAlign: TextAlign.center,
                            style: dark.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              shadows: const [
                                Shadow(color: Colors.black54, blurRadius: 12),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          metadataRow(
                            (detail?.subtitle ?? widget.item.subtitle ?? '')
                                .replaceAll(RegExp(r'(?:更新至\s*){2,}'), '更新至')
                                .replaceAll(RegExp(r'集\s*集'), '集'),
                            detail?.title ?? widget.item.title,
                          ),
                          summaryBlock(
                            detail?.title ?? widget.item.title,
                            synopsis,
                          ),
                          const SizedBox(height: 12),
                          Center(
                            child: FractionallySizedBox(
                              widthFactor: .72,
                              child: FilledButton.icon(
                                key: const Key('video-detail-play'),
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(50),
                                  backgroundColor: Colors.white.withValues(
                                    alpha: .35,
                                  ),
                                  foregroundColor: Colors.white,
                                  shape: const StadiumBorder(),
                                  elevation: 4,
                                ),
                                onPressed:
                                    loading || resolving || chapters.isEmpty
                                    ? null
                                    : play,
                                icon: resolving
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const LumeIcon(
                                        Icons.play_arrow,
                                        slot: 'video_detail_page.4',
                                      ),
                                label: Text(
                                  resolving
                                      ? '正在解析'
                                      : widget.library.videoProgress(
                                              widget.item.id,
                                            ) ==
                                            null
                                      ? '播放'
                                      : '继续播放 · ${chapters.isEmpty ? '' : chapters[selected].title}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                          quickActions(),
                          if (loading)
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          if (error != null) ...[
                            const SizedBox(height: 12),
                            Text(error!),
                            TextButton(
                              onPressed: load,
                              child: const Text('重试'),
                            ),
                          ],
                          const SizedBox(height: 24),
                          linePicker(),
                          const SizedBox(height: 10),
                          episodeSection(immersive: true),
                          castSection(),
                          recommendationsSection(),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    },
  );
}
