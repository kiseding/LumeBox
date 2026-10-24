import 'video_episode_catalog.dart';

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

  Future<void> searchCurrentVideo() async {
    final source = _source;
    if (source == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SearchResultsPage(
          section: widget.library.section,
          keyword: detail?.title ?? widget.item.title,
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
    var page = (reversed ? chapters.length - 1 - selected : selected) ~/ 50;
    final order = [
      for (var i = 0; i < chapters.length; i++)
        reversed ? chapters.length - 1 - i : i,
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => SafeArea(
          top: false,
          child: FractionallySizedBox(
            heightFactor: .75,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$currentLine · 共 ${chapters.length} 集',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                if (chapters.length > 50)
                  DropdownButtonFormField<int>(
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
                    onChanged: (value) {
                      if (value != null) refresh(() => page = value);
                    },
                  ),
                const SizedBox(height: 12),
                episodeGrid(
                  order.skip(page * 50).take(50).toList(),
                  modal: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget episodeSection() {
    final order = [
      for (var i = 0; i < chapters.length; i++)
        reversed ? chapters.length - 1 - i : i,
    ];
    final page = episodePage.clamp(
      0,
      ((chapters.length - 1) ~/ 50).clamp(0, 999999),
    );
    final visible = order.skip(page * 50).take(50).toList();
    final artwork = chapters.any((e) => e.cover?.trim().isNotEmpty == true);
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
          SizedBox(
            height: 124,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: visible.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final index = visible[i], chapter = chapters[index];
                return SizedBox(
                  width: 160,
                  child: InkWell(
                    key: ValueKey('video-detail-episode-$index'),
                    onTap: resolving ? null : () => chooseEpisode(index),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            height: 90,
                            child: chapter.cover?.trim().isNotEmpty == true
                                ? PosterCover(
                                    pipeline: pipeline,
                                    url: chapter.cover,
                                    title: chapter.title,
                                    headers: chapter.coverHeaders,
                                  )
                                : Center(child: Text('${index + 1}')),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          VideoEpisodeCatalog.labelOf(chapter),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          )
        else
          episodeGrid(visible),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tmdb,
    builder: (context, _) {
      final baseTheme = Theme.of(context);
      final colors = baseTheme.colorScheme;
      final title = detail?.title ?? widget.item.title;
      final description = detail?.description?.trim().isNotEmpty == true
          ? detail!.description!
          : tmdb.metadata?.overview ?? '暂无简介';
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
            IconButton(
              tooltip: widget.library.onShelf(widget.item.id) ? '已收藏' : '收藏',
              onPressed: _source == null || !widget.recordHistory
                  ? null
                  : favorite,
              icon: Icon(
                widget.library.onShelf(widget.item.id)
                    ? Icons.favorite
                    : Icons.favorite_border,
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (action) {
                if (action == 'search') searchCurrentVideo();
                if (action == 'tmdb') tmdb.rematch();
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
                        Text(
                          [
                            if (subtitle.isNotEmpty) subtitle,
                            if (_source != null) _source!.name,
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: FilledButton.icon(
                                key: const Key('video-detail-play'),
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(48),
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
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                key: const Key('video-detail-select-episodes'),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                    color: colors.onSurface.withValues(
                                      alpha: .22,
                                    ),
                                  ),
                                  minimumSize: const Size.fromHeight(48),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                onPressed: chapters.isEmpty
                                    ? null
                                    : showEpisodes,
                                icon: const Icon(Icons.grid_view, size: 18),
                                label: const Text('选集'),
                              ),
                            ),
                          ],
                        ),
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
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '简介',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            SourceTranslationAction(
                              texts: [title, description],
                            ),
                          ],
                        ),
                        SourceText(
                          description,
                          maxLines: descriptionExpanded ? null : 3,
                          overflow: descriptionExpanded
                              ? null
                              : TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        if (description.length > 70)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () => setState(
                                () =>
                                    descriptionExpanded = !descriptionExpanded,
                              ),
                              child: Text(
                                descriptionExpanded ? '收起简介' : '展开简介',
                              ),
                            ),
                          ),
                        const SizedBox(height: 24),
                        const Text(
                          '播放线路',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (lines.isNotEmpty)
                          DropdownButtonFormField<String>(
                            key: ValueKey('video-detail-line-$currentLine'),
                            initialValue: currentLine,
                            isExpanded: true,
                            decoration: InputDecoration(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                              filled: true,
                              fillColor: colors.onSurface.withValues(
                                alpha: .04,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            items: [
                              for (final entry in lines.entries)
                                DropdownMenuItem(
                                  value: entry.key,
                                  child: Text(
                                    '${entry.key} · ${entry.value.length} 集',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: resolving || lines.length < 2
                                ? null
                                : (value) {
                                    if (value != null) changeLine(value);
                                  },
                          )
                        else
                          const Text('暂无可用线路'),
                        const SizedBox(height: 14),
                        episodeSection(),
                        if (tmdb.metadata?.cast.isNotEmpty == true) ...[
                          const SizedBox(height: 24),
                          const Text(
                            '演职人员',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 102,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: tmdb.metadata!.cast.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 12),
                              itemBuilder: (_, i) => SizedBox(
                                width: 64,
                                child: Column(
                                  children: [
                                    CircleAvatar(
                                      radius: 27,
                                      foregroundImage:
                                          i < tmdb.metadata!.profiles.length &&
                                              tmdb
                                                  .metadata!
                                                  .profiles[i]
                                                  .isNotEmpty
                                          ? NetworkImage(
                                              tmdb.metadata!.profiles[i],
                                            )
                                          : null,
                                      child: const Icon(Icons.person_outline),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      tmdb.metadata!.cast[i],
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
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
}
