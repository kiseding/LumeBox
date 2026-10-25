import 'detail_poster_background.dart';
import 'detail_artwork_motion.dart';
import 'video_episode_catalog.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/lume_icon.dart';
import '../settings/tmdb_settings_page.dart';

import 'dart:ui' as ui;

import 'package:palette_generator/palette_generator.dart';

import '../../shared/widgets/poster_gradient_scaffold.dart';
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

// Increase weight without changing font sizes or accessibility scaling.
TextTheme _bolderTextTheme(TextTheme base) => base.copyWith(
  displayLarge: base.displayLarge?.apply(fontWeightDelta: 1),
  displayMedium: base.displayMedium?.apply(fontWeightDelta: 1),
  displaySmall: base.displaySmall?.apply(fontWeightDelta: 1),
  headlineLarge: base.headlineLarge?.apply(fontWeightDelta: 1),
  headlineMedium: base.headlineMedium?.apply(fontWeightDelta: 1),
  headlineSmall: base.headlineSmall?.apply(fontWeightDelta: 1),
  titleLarge: base.titleLarge?.apply(fontWeightDelta: 1),
  titleMedium: base.titleMedium?.apply(fontWeightDelta: 1),
  titleSmall: base.titleSmall?.apply(fontWeightDelta: 1),
  bodyLarge: base.bodyLarge?.apply(fontWeightDelta: 1),
  bodyMedium: base.bodyMedium?.apply(fontWeightDelta: 1),
  bodySmall: base.bodySmall?.apply(fontWeightDelta: 1),
  labelLarge: base.labelLarge?.apply(fontWeightDelta: 1),
  labelMedium: base.labelMedium?.apply(fontWeightDelta: 1),
  labelSmall: base.labelSmall?.apply(fontWeightDelta: 1),
);

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
  int episodePage = 0, compactEpisodeStart = 0;
  static const styleSetting = 'video.detail.originalStyle';
  bool originalStyle = true, playbackFailed = false;
  VideoProgress? lineResume;
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
    originalStyle = widget.library.setting(styleSetting) != 'false';
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
        lineResume = null;
        detail = metadata;
        lines = grouped;
        currentLine = line;
        chapters = activeEpisodes;
        selected = index;
        episodePage = index ~/ 50;
        compactEpisodeStart = index ~/ 6 * 6;
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
    setState(() {
      resolving = true;
      playbackFailed = false;
    });
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
      if (lineResume != null && widget.recordHistory) {
        final saved = lineResume!;
        widget.library.saveProgress(
          VideoProgress(
            section: widget.library.section,
            itemId: widget.item.id,
            chapterIndex: selected,
            chapterId: chapter.id,
            chapterTitle: chapter.title,
            updatedAt: DateTime.now(),
            position: saved.position,
            duration: saved.duration,
          ),
        );
        lineResume = null;
      }
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
        for (final entry in lines.entries) {
          final index = entry.value.indexWhere(
            (chapter) => chapter.id == last?.chapterId,
          );
          if (index >= 0) {
            setState(() {
              currentLine = entry.key;
              chapters = entry.value;
              selected = index;
              episodePage = index ~/ 50;
              compactEpisodeStart =
                  (reversed ? chapters.length - 1 - index : index) ~/ 6 * 6;
            });
            break;
          }
        }
      }
    } catch (failure) {
      if (mounted) {
        setState(() => playbackFailed = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('解析失败：$failure'),
            action: lines.length > 1
                ? SnackBarAction(
                    label: '换线路',
                    onPressed: switchLineAfterFailure,
                  )
                : null,
          ),
        );
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
  String? _displayedPoster;
  int _paletteRevision = 0;
  void _artworkDisplayed(String? url) {
    if (_displayedPoster == url) return;
    _displayedPoster = url;
    unawaited(updatePalette());
  }

  Color get _pageColor {
    if (originalStyle) {
      return tmdb.settings.detailBackdropEnabled
          ? (_coverColor ?? Colors.black)
          : const Color(0xff11131a);
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? const Color(0xff11131a) : const Color(0xfff7f7fa);
    if (_coverColor == null) return base;
    return Color.lerp(base, _coverColor, dark ? .12 : .045)!;
  }

  Future<ui.Image?> _displayedPosterSample(String url) async {
    // The gallery has already decoded this NetworkImage. Reuse Flutter's image
    // cache rather than downloading the same poster again through the source.
    final ImageProvider provider = url == tmdb.metadata?.backdrops.firstOrNull
        ? ResizeImage.resizeIfNeeded(384, null, NetworkImage(url))
        : NetworkImage(url);
    final stream = provider.resolve(ImageConfiguration.empty);
    final ready = Completer<ui.Image?>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!ready.isCompleted) ready.complete(info.image.clone());
      },
      onError: (Object _, StackTrace? _) {
        if (!ready.isCompleted) ready.complete(null);
      },
    );
    stream.addListener(listener);
    ui.Image? original;
    try {
      original = await ready.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      if (original == null) return null;
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        original,
        Rect.fromLTWH(
          0,
          0,
          original.width.toDouble(),
          original.height.toDouble(),
        ),
        const Rect.fromLTWH(0, 0, 48, 48),
        Paint(),
      );
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(48, 48);
      } finally {
        picture.dispose();
      }
    } finally {
      stream.removeListener(listener);
      original?.dispose();
    }
  }

  Future<void> updatePalette() async {
    final backdrop =
        tmdb.settings.enabled && tmdb.settings.detailBackdropEnabled
        ? tmdb.metadata?.backdrops.firstOrNull
        : null;
    final cover = backdrop ?? _displayedPoster ?? sourceCover;
    if (cover == null || cover.isEmpty) return;
    final revision = ++_paletteRevision;
    try {
      final color = await PosterPaletteCache.resolve(
        ('video-detail-backdrop-v2', cover),
        () async {
          final sample = backdrop == cover || _displayedPoster == cover
              ? await _displayedPosterSample(cover)
              : await pipeline.colorSample(cover);
          if (sample == null) throw StateError('Poster unavailable');
          try {
            // Reuse the decoded, downsampled poster and its existing session.
            final palette = await PaletteGenerator.fromImage(
              sample,
              maximumColorCount: 24,
              filters: const [],
            );
            // Very dark neutral swatches usually describe clothes, not the
            // poster's atmosphere. Prefer a coloured swatch in that case.
            final muted = palette.darkMutedColor?.color;
            final hsl = muted == null ? null : HSLColor.fromColor(muted);
            final swatches = palette.paletteColors.where((swatch) {
              final value = HSLColor.fromColor(swatch.color);
              return value.saturation > .22 && value.lightness > .12;
            }).toList()..sort((a, b) => b.population.compareTo(a.population));
            final chosen =
                hsl != null && hsl.lightness > .13 && hsl.saturation > .2
                ? muted
                : swatches.firstOrNull?.color ??
                      muted ??
                      palette.dominantColor?.color;
            if (chosen == null) return null;
            final tone = HSLColor.fromColor(chosen);
            return tone.withLightness(tone.lightness.clamp(.18, .30)).toColor();
          } finally {
            sample.dispose();
          }
        },
      );
      if (revision != _paletteRevision) return;
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
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context)
        .copyWith(textTheme: _bolderTextTheme(Theme.of(context).textTheme)),
    child: Builder(
      builder: (context) =>
          originalStyle ? _buildOriginal(context) : _buildCompact(context),
    ),
  );

  void setDetailStyle(bool original) {
    widget.library.setSetting(styleSetting, '$original');
    setState(() => originalStyle = original);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  List<Widget> detailActions() => [
    IconButton(
      key: const Key('video-detail-search'),
      tooltip: '其他源找这部',
      onPressed: _source == null ? null : () => searchCurrentVideo(),
      icon: const Icon(Icons.search),
    ),
    IconButton(
      key: const Key('video-detail-favorite'),
      tooltip: widget.library.onShelf(widget.item.id) ? '已收藏' : '收藏',
      onPressed: _source == null || !widget.recordHistory ? null : favorite,
      icon: Icon(
        widget.library.onShelf(widget.item.id)
            ? Icons.favorite
            : Icons.favorite_border,
      ),
    ),
    PopupMenuButton<String>(
      key: const Key('video-detail-more'),
      tooltip: '更多',
      onSelected: (action) {
        switch (action) {
          case 'bangumi':
            openBangumi();
          case 'original':
            setDetailStyle(true);
          case 'compact':
            setDetailStyle(false);
          case 'tmdb':
            tmdb.rematch();
          case 'settings':
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const TmdbSettingsPage()),
            );
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'bangumi', child: Text('Bangumi 追番')),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: 'original',
          checked: originalStyle,
          child: const Text('大封面版（旧版）'),
        ),
        CheckedPopupMenuItem(
          value: 'compact',
          checked: !originalStyle,
          child: const Text('紧凑版（当前版）'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'tmdb',
          enabled: tmdb.settings.configured && !tmdb.loading,
          child: const Text('重新匹配TMDB'),
        ),
        const PopupMenuItem(value: 'settings', child: Text('TMDB 设置与测试')),
        PopupMenuItem(
          enabled: false,
          child: Text(
            tmdbStatusLabel,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
    const SizedBox(width: 8),
  ];

  String get tmdbStatusLabel {
    if (!tmdb.settings.enabled) return 'TMDB 未开启';
    if (!tmdb.settings.configured) return 'TMDB 未填写 API Key 或 Token';
    if (tmdb.loading) return 'TMDB 正在匹配资料…';
    final data = tmdb.metadata;
    if (data != null) {
      return 'TMDB 已匹配 · 演员 ${data.cast.length}';
    }
    return tmdb.status ?? 'TMDB 尚未匹配到资料';
  }

  Widget metadataRow(String subtitle, String title) => Row(
    key: const Key('video-detail-metadata-row'),
    children: [
      Expanded(
        child: Text(
          [
            if (subtitle.trim().isNotEmpty)
              subtitle
                  .split(' · ')
                  .where(
                    (part) =>
                        !originalStyle ||
                        !(tmdb.metadata?.genres.contains(part.trim()) ?? false),
                  )
                  .join(' · '),
            if ((tmdb.metadata?.episodeCount ?? 0) > 0 &&
                !subtitle.contains('集'))
              '共 ${tmdb.metadata!.episodeCount} 集',
            if (tmdb.metadata?.year.isNotEmpty == true &&
                !subtitle.contains(tmdb.metadata!.year))
              tmdb.metadata!.year,
            if (!originalStyle &&
                tmdb.metadata?.genres.isNotEmpty == true &&
                !tmdb.metadata!.genres.any(subtitle.contains))
              tmdb.metadata!.genres.join(' · '),
            if ((tmdb.metadata?.rating ?? 0) > 0)
              '★ ${tmdb.metadata!.rating.toStringAsFixed(1)}',
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: originalStyle ? TextAlign.center : TextAlign.left,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
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
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: const EdgeInsets.all(4),
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
    ],
  );

  String get synopsis => tmdb.metadata?.overview.trim().isNotEmpty == true
      ? tmdb.metadata!.overview
      : detail?.description?.trim().isNotEmpty == true
      ? detail!.description!
      : '暂无简介';

  Widget summaryBlock(String title, String text) => Row(
    key: const Key('video-detail-summary-row'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: InkWell(
          key: const Key('video-detail-summary'),
          onTap: () =>
              setState(() => descriptionExpanded = !descriptionExpanded),
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
      ),
    ],
  );

  Widget linePicker() => Row(
    key: const Key('video-detail-line-heading'),
    children: [
      Text(
        '线路',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: originalStyle
              ? Colors.white70
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(width: 10),
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
            fontWeight: FontWeight.w500,
          ),
          decoration: InputDecoration(
            isDense: !originalStyle,
            filled: true,
            fillColor: originalStyle
                ? Colors.white.withValues(alpha: .09)
                : Colors.black.withValues(alpha: .04),
            contentPadding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: originalStyle ? 12 : 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(originalStyle ? 14 : 12),
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
      SizedBox(width: originalStyle ? 38 : 10),
      Expanded(
        flex: MediaQuery.textScalerOf(context).scale(1) > 1.3 ? 2 : 1,
        child: OutlinedButton.icon(
          // Keep the secondary entry usable with large accessibility text.
          key: const Key('video-detail-select-episodes'),
          style: OutlinedButton.styleFrom(
            minimumSize: Size.fromHeight(originalStyle ? 48 : 44),
            tapTargetSize: originalStyle
                ? null
                : MaterialTapTargetSize.shrinkWrap,
            shape: originalStyle
                ? null
                : RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
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
  );

  Widget episodeStrip(List<int> visible, {bool grid = false}) => LayoutBuilder(
    builder: (context, bounds) {
      final width = (bounds.maxWidth - 20) / 3;
      final height = width * 9 / 16;
      final extent =
          height + 12 + MediaQuery.textScalerOf(context).scale(13) * 1.5;
      Widget tile(int i) {
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
                              ? detail?.coverHeaders ?? widget.item.coverHeaders
                              : chapter.coverHeaders,
                        ),
                        if (episodeProgress(index)?.position != null &&
                            episodeProgress(index)!.position > Duration.zero)
                          Positioned(
                            left: 4,
                            top: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                child: Text(
                                  episodeProgress(index)!.isFinished
                                      ? '已看完'
                                      : '观看中',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
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
                episodeProgressBar(index),
                const SizedBox(height: 6),
                Text(
                  VideoEpisodeCatalog.displayLabel(chapter, index),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        );
      }

      if (grid) {
        return GridView.builder(
          key: const Key('video-detail-compact-episode-grid'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 12,
            mainAxisExtent: extent,
          ),
          itemCount: visible.length,
          itemBuilder: (_, i) => tile(i),
        );
      }
      return SizedBox(
        height: extent,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: visible.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (_, i) => tile(i),
        ),
      );
    },
  );

  Future<void> openBangumi() async {
    await showBangumiMatchSheet(
      context: context,
      library: widget.library,
      item: widget.item,
      initialTitle: detail?.title ?? widget.item.title,
    );
  }

  VideoProgress? episodeProgress(int index) {
    final chapter = chapters[index];
    return widget.library.videoEpisodeProgress(widget.item.id, chapter.id) ??
        (index == selected ? lineResume : null);
  }

  String get playLabel {
    if (resolving) return '正在解析';
    if (chapters.isEmpty) return '暂无可播放剧集';
    final progress = episodeProgress(selected);
    final label = VideoEpisodeCatalog.displayLabel(
      chapters[selected],
      selected,
    );
    return '${progress?.isFinished == true
        ? '重播'
        : progress != null && progress.position > Duration.zero
        ? '继续看'
        : '播放'} · $label';
  }

  Widget resumeHint() {
    final progress = chapters.isEmpty ? null : episodeProgress(selected);
    if (progress == null || progress.position <= Duration.zero) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        progress.isFinished ? '本集已看完' : '看到 ${progress.timeLabel}',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: originalStyle
              ? Colors.white70
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget episodeProgressBar(int index) {
    final progress = episodeProgress(index);
    if (progress == null || progress.position <= Duration.zero) {
      return const SizedBox.shrink();
    }
    return LinearProgressIndicator(
      key: ValueKey('video-episode-progress-$index'),
      value: progress.duration > Duration.zero ? progress.ratio : 0,
      minHeight: 3,
      color: originalStyle
          ? Colors.white
          : Theme.of(context).colorScheme.primary,
      backgroundColor: originalStyle
          ? Colors.white24
          : Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }

  Widget castSection() {
    final metadata = tmdb.metadata;
    if (metadata == null || metadata.cast.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.only(top: originalStyle ? 24 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '演员',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 68 + MediaQuery.textScalerOf(context).scale(12) * 1.5,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: metadata.cast.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (_, i) => SizedBox(
                width: 68,
                child: Column(
                  children: [
                    ClipOval(
                      child: SizedBox.square(
                        dimension: 60,
                        child:
                            i < metadata.profiles.length &&
                                metadata.profiles[i].isNotEmpty
                            ? PosterCover(
                                pipeline: pipeline,
                                url: metadata.profiles[i],
                                title: metadata.cast[i],
                                width: 180,
                                borderRadius: BorderRadius.zero,
                              )
                            : const ColoredBox(
                                color: Color(0x22666666),
                                child: Center(
                                  child: Icon(Icons.person_outline, size: 28),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
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

  bool changeLine(String next, {bool allowMissing = false}) {
    if (next == currentLine) return true;
    if (resolving || !lines.containsKey(next) || lines[next]!.isEmpty) {
      return false;
    }
    final previous = chapters.isEmpty ? null : chapters[selected];
    final nextChapters = lines[next]!;
    final matched = previous == null
        ? -1
        : VideoEpisodeCatalog.matchingIndex(previous, nextChapters);
    if (matched < 0 && !allowMissing) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('该线路没有对应集，请在选集里手动选择'),
          action: SnackBarAction(label: '选集', onPressed: showEpisodes),
        ),
      );
      return false;
    }
    final progress = matched >= 0 ? episodeProgress(selected) : null;
    setState(() {
      lineResume = progress;
      currentLine = next;
      chapters = nextChapters;
      selected = matched >= 0 ? matched : 0;
      episodePage = selected ~/ 50;
      compactEpisodeStart =
          (reversed ? chapters.length - 1 - selected : selected) ~/ 6 * 6;
    });
    return true;
  }

  Future<void> switchLineAfterFailure() async {
    final next = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('换线路继续看'),
              subtitle: Text('保留当前集数；有观看记录时继续上次位置'),
            ),
            for (final line in lines.keys.where((line) => line != currentLine))
              ListTile(
                title: Text(line),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, line),
              ),
          ],
        ),
      ),
    );
    if (next != null && mounted && changeLine(next)) await play();
  }

  Future<void> chooseEpisode(int index) async {
    if (resolving || index < 0 || index >= chapters.length) return;
    setState(() {
      if (index != selected) lineResume = null;
      selected = index;
      compactEpisodeStart =
          (reversed ? chapters.length - 1 - selected : selected) ~/ 6 * 6;
    });
    if (PlayerExperienceStore.current.selectEpisodeOnly) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已选中剧集，点击上方播放按钮开始')));
      return;
    }
    await play();
  }

  void locateEpisodes() {
    setState(() {
      final position = reversed ? chapters.length - 1 - selected : selected;
      episodePage = position ~/ 50;
      compactEpisodeStart = position ~/ 6 * 6;
    });
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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            VideoEpisodeCatalog.displayLabel(chapter, index),
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          episodeProgressBar(index),
        ],
      ),
    );
  }

  Widget episodeGrid(List<int> indexes, {bool modal = false}) => LayoutBuilder(
    builder: (context, bounds) {
      final count = !modal && !originalStyle
          ? 3
          : bounds.maxWidth < 340
          ? 4
          : 5;
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
    int? jumpIndex;
    var searchRevision = 0;
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
                (i) => (jumpIndex == null
                    ? VideoEpisodeCatalog.labelOf(chapters[i])
                          .toLowerCase()
                          .contains(query.toLowerCase())
                    : i == jumpIndex),
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
                            fontWeight: FontWeight.w700,
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
                                        changeLine(line, allowMissing: true);
                                        refresh(() {
                                          page = 0;
                                          jumpIndex = null;
                                        });
                                      },
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    key: ValueKey('episode-search-$searchRevision'),
                    decoration: const InputDecoration(
                      hintText: '搜索剧集名称',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) => refresh(() {
                      query = v;
                      jumpIndex = null;
                      page = 0;
                    }),
                  ),
                  TextField(
                    key: const Key('video-episode-jump'),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '跳转到第几集',
                      prefixIcon: Icon(Icons.numbers),
                    ),
                    onSubmitted: (value) {
                      final number = int.tryParse(value);
                      if (number == null ||
                          number < 1 ||
                          number > chapters.length) {
                        ScaffoldMessenger.of(sheetContext).showSnackBar(
                          const SnackBar(content: Text('请输入有效集数')),
                        );
                        return;
                      }
                      refresh(() {
                        jumpIndex = number - 1;
                        query = '';
                        searchRevision++;
                        page = 0;
                      });
                      FocusScope.of(context).unfocus();
                    },
                  ),
                  if (jumpIndex != null)
                    TextButton(
                      onPressed: () => refresh(() {
                        jumpIndex = null;
                        query = '';
                        searchRevision++;
                        page = 0;
                      }),
                      child: const Text('显示全部剧集'),
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
                          VideoEpisodeCatalog.displayLabel(chapters[i], i),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle:
                            VideoEpisodeCatalog.displayLabel(chapters[i], i) !=
                                VideoEpisodeCatalog.labelOf(chapters[i])
                            ? Text(
                                VideoEpisodeCatalog.labelOf(chapters[i]),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
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
    final visible = originalStyle
        ? order.skip(page * 50).take(50).toList()
        : order
              .skip(
                compactEpisodeStart.clamp(
                  0,
                  (order.length - 1).clamp(0, 999999),
                ),
              )
              .take(6)
              .toList();
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
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SourceTranslationAction(
              key: const Key('video-detail-translation'),
              texts: [detail?.title ?? widget.item.title, synopsis],
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
          ],
        ),
        if (originalStyle && chapters.length > 50)
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
          episodeStrip(visible, grid: !originalStyle)
        else
          episodeGrid(visible),
      ],
    );
  }

  Widget compactPlaybackControls() => LayoutBuilder(
    key: const Key('video-detail-compact-playback'),
    builder: (context, bounds) {
      final progress = chapters.isEmpty ? null : episodeProgress(selected);
      final hasProgress = progress != null && progress.position > Duration.zero;
      final button = FilledButton.icon(
        key: const Key('video-detail-play'),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: loading || resolving || chapters.isEmpty ? null : play,
        icon: resolving
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.play_arrow, size: 20),
        label: Text(
          playLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
      );
      final progressLabel = hasProgress
          ? Text(
              progress.isFinished ? '本集已看完' : '看到 ${progress.timeLabel}',
              key: const Key('video-detail-compact-progress'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                height: 1.4,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )
          : null;
      final stacked =
          bounds.maxWidth < 340 ||
          MediaQuery.textScalerOf(context).scale(1) > 1.3;
      if (stacked) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            button,
            if (progressLabel != null) ...[
              const SizedBox(height: 8),
              progressLabel,
            ],
          ],
        );
      }
      return Row(
        children: [
          Expanded(flex: 3, child: button),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerRight,
              child: progressLabel,
            ),
          ),
        ],
      );
    },
  );

  Widget _buildCompact(BuildContext context) => ListenableBuilder(
    listenable: tmdb,
    builder: (context, _) {
      final baseTheme = Theme.of(context);
      final colors = baseTheme.colorScheme;
      final title = detail?.title ?? widget.item.title;
      final subtitle = (detail?.subtitle ?? widget.item.subtitle ?? '')
          .replaceAll(RegExp(r'(?:更新至\s*){2,}'), '更新至')
          .replaceAll(RegExp(r'集\s*集'), '集');
      final hasArtwork =
          sourceCover?.trim().isNotEmpty == true ||
          tmdb.metadata?.posters.isNotEmpty == true ||
          tmdb.metadata?.backdrops.isNotEmpty == true;
      final overlayHeader = hasArtwork && !collapsedHeader;
      return Scaffold(
        backgroundColor: _pageColor,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: overlayHeader ? Colors.transparent : _pageColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          foregroundColor: overlayHeader ? Colors.white : colors.onSurface,
          actionsIconTheme: IconThemeData(
            color: overlayHeader ? Colors.white : colors.onSurface,
          ),
          systemOverlayStyle:
              !overlayHeader && baseTheme.brightness == Brightness.light
              ? SystemUiOverlayStyle.dark
              : SystemUiOverlayStyle.light,
          leading: Padding(
            padding: const EdgeInsets.all(8),
            child: IconButton.filledTonal(
              tooltip: '返回',
              style: IconButton.styleFrom(
                backgroundColor: !overlayHeader
                    ? colors.onSurface.withValues(alpha: .06)
                    : Colors.black.withValues(alpha: .22),
                foregroundColor: !overlayHeader
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
          actions: detailActions(),
        ),
        body: LayoutBuilder(
          builder: (context, bounds) {
            final heroHeight = (bounds.maxWidth * .54).clamp(220.0, 240.0);
            return SingleChildScrollView(
              controller: _scroll,
              key: const Key('video-detail-scroll'),
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              child: Stack(
                key: const Key('video-detail-immersive'),
                children: [
                  if (hasArtwork)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      key: const Key('video-detail-compact-banner'),
                      height: heroHeight,
                      child: DetailArtworkMotion(
                        scroll: _scroll,
                        height: heroHeight,
                        child: IgnorePointer(
                          child: tmdb.metadata?.backdrops.isNotEmpty == true
                              ? PosterCover(
                                  pipeline: pipeline,
                                  url: tmdb.metadata!.backdrops.first,
                                  title: title,
                                )
                              : TmdbPosterGallery(
                                  onArtworkDisplayed: _artworkDisplayed,
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
                    ),
                  if (hasArtwork)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: heroHeight + 2,
                      child: DetailArtworkMotion(
                        scroll: _scroll,
                        height: heroHeight,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            key: const Key('video-detail-gradient'),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                stops: const [0, .4, .72, .9, 1],
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
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      hasArtwork
                          ? heroHeight + 12
                          : MediaQuery.paddingOf(context).top +
                                kToolbarHeight +
                                16,
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
                            fontWeight: FontWeight.w800,
                            color: colors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 8),
                        metadataRow(subtitle, title),
                        const SizedBox(height: 20),
                        compactPlaybackControls(),
                        const SizedBox(height: 20),
                        summaryBlock(
                          detail?.title ?? widget.item.title,
                          synopsis,
                        ),
                        if (playbackFailed && lines.length > 1)
                          OutlinedButton.icon(
                            onPressed: switchLineAfterFailure,
                            icon: const Icon(Icons.alt_route),
                            label: const Text('换线路继续看'),
                          ),
                        if (playbackFailed)
                          TextButton.icon(
                            onPressed: () => searchCurrentVideo(),
                            icon: const Icon(Icons.search),
                            label: const Text('其他源找这部'),
                          ),
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
                        Divider(
                          height: 1,
                          color: colors.outlineVariant.withValues(alpha: .5),
                        ),
                        const SizedBox(height: 8),
                        linePicker(),
                        const SizedBox(height: 8),
                        episodeSection(),
                        castSection(),
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
        textTheme: _bolderTextTheme(
          LumeTheme.readableTextTheme(Brightness.dark).apply(
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          ),
        ),
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
            actions: detailActions(),
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final artworkHeight = (constraints.maxWidth * 1.48).clamp(
                460.0,
                760.0,
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (tmdb.settings.detailBackdropEnabled)
                    DetailPosterBackground(
                      key: const Key('video-detail-blurred-background'),
                      backdrop: tmdb.settings.enabled
                          ? tmdb.metadata?.backdrops.firstOrNull
                          : null,
                      tint: _pageColor,
                      fallback: sourceCover == null
                          ? ColoredBox(color: _pageColor)
                          : PosterCover(
                              pipeline: pipeline,
                              url: sourceCover,
                              width: 320,
                              borderRadius: null,
                              headers:
                                  detail?.coverHeaders ??
                                  widget.item.coverHeaders,
                            ),
                    ),
                  SingleChildScrollView(
                    controller: _scroll,
                    key: const Key('video-detail-scroll'),
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    child: Stack(
                      key: const Key('video-detail-immersive'),
                      children: [
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: artworkHeight,
                          child: DetailArtworkMotion(
                            scroll: _scroll,
                            height: artworkHeight,
                            child: IgnorePointer(
                              child: DetailPosterFade(
                                key: tmdb.settings.detailBackdropEnabled
                                    ? const Key('video-detail-gradient')
                                    : null,
                                child: TmdbPosterGallery(
                                  onArtworkDisplayed: _artworkDisplayed,
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
                          ),
                        ),
                        if (!tmdb.settings.detailBackdropEnabled)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: artworkHeight + 2,
                            child: DetailArtworkMotion(
                              scroll: _scroll,
                              height: artworkHeight,
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  key: const Key('video-detail-gradient'),
                                  decoration: BoxDecoration(
                                    gradient: posterOverlayGradient(_pageColor),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            artworkHeight * .61 + 24,
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
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  shadows: const [
                                    Shadow(
                                      color: Colors.black54,
                                      blurRadius: 12,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              metadataRow(
                                (detail?.subtitle ?? widget.item.subtitle ?? '')
                                    .replaceAll(
                                      RegExp(r'(?:更新至\s*){2,}'),
                                      '更新至',
                                    )
                                    .replaceAll(RegExp(r'集\s*集'), '集'),
                                detail?.title ?? widget.item.title,
                              ),
                              if (tmdb.metadata?.genres.isNotEmpty == true)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    tmdb.metadata!.genres.join(' · '),
                                    key: const Key('video-detail-genres'),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              resumeHint(),
                              const SizedBox(height: 4),
                              Center(
                                child: FractionallySizedBox(
                                  widthFactor: .82,
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
                                      playLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              summaryBlock(
                                detail?.title ?? widget.item.title,
                                synopsis,
                              ),
                              if (playbackFailed && lines.length > 1)
                                OutlinedButton.icon(
                                  onPressed: switchLineAfterFailure,
                                  icon: const Icon(Icons.alt_route),
                                  label: const Text('换线路继续看'),
                                ),
                              if (playbackFailed)
                                TextButton.icon(
                                  onPressed: () => searchCurrentVideo(),
                                  icon: const Icon(Icons.search),
                                  label: const Text('其他源找这部'),
                                ),
                              if (loading)
                                const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ),
                              if (error != null) ...[
                                const SizedBox(height: 12),
                                Text(error!),
                                TextButton(
                                  onPressed: load,
                                  child: const Text('重试'),
                                ),
                              ],
                              const SizedBox(height: 4),
                              linePicker(),
                              const SizedBox(height: 10),
                              episodeSection(immersive: true),
                              castSection(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}
