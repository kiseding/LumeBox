part of 'music_page.dart';

const _musicQualities = {
  'low': '流畅',
  'standard': '标准',
  'high': '无损',
  'super': '高解析',
};

class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key, this.session});
  final MusicSession? session;
  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage>
    with NetworkOwnedState<MusicPlayerPage> {
  late final _session = widget.session ?? MusicSession.instance;
  String? _lyricKey, _lyricError;
  List<LyricLine> _lyrics = [];
  bool _lyricLoading = false;
  double? _drag;

  @override
  void initState() {
    super.initState();
    _session.addListener(_changed);
    _changed();
  }

  void _changed() {
    final track = _session.current;
    if (track == null || track.key == _lyricKey) return;
    _lyricKey = track.key;
    _lyrics = [];
    _drag = null;
    _lyricError = null;
    _lyricLoading = true;
    unawaited(_loadLyrics(track));
  }

  Future<void> _loadLyrics(MusicTrack track) async {
    try {
      final lyrics = await networkRequests.run(
        'lyrics',
        () => _session.service.lyrics(track),
      );
      if (mounted && _lyricKey == track.key) {
        setState(() {
          _lyrics = LyricLine.parse(lyrics.original);
          _lyricLoading = false;
        });
      }
    } catch (_) {
      if (mounted && _lyricKey == track.key) {
        setState(() {
          _lyricError = '歌词暂不可用';
          _lyricLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    super.dispose();
  }

  static String _time(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  void _queue() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              '播放队列 · ${_session.queue.length} 首',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _session.queue.length,
              itemBuilder: (context, index) => ListTile(
                leading: Icon(
                  index == _session.audio.current
                      ? Icons.equalizer_rounded
                      : Icons.music_note_rounded,
                ),
                selected: index == _session.audio.current,
                title: Text(
                  _session.queue[index].title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  _session.queue[index].artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_session.select(index));
                },
              ),
            ),
          ),
        ],
      ),
    ),
  );

  void _options() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: AnimatedBuilder(
          animation: Listenable.merge([_session, _session.library]),
          builder: (context, _) {
            final theme = Theme.of(context);
            final sleepAt = _session.audio.sleepAt;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('播放设置', style: theme.textTheme.titleLarge),
                const SizedBox(height: 20),
                const Text('优先音质'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final quality in _musicQualities.entries)
                      ChoiceChip(
                        label: Text(quality.value),
                        selected: _session.library.quality == quality.key,
                        onSelected: (_) async {
                          _session.library.quality = quality.key;
                          try {
                            await _session.library.save();
                          } catch (e) {
                            if (context.mounted) {
                              _message(context, '音质设置保存失败，请重试');
                            }
                          }
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '后续加载歌曲时优先生效，实际音质取决于音源支持。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Divider(height: 1),
                ),
                Row(
                  children: [
                    const Icon(Icons.bedtime_outlined, size: 19),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        sleepAt == null
                            ? '定时关闭'
                            : '将在 ${sleepAt.hour.toString().padLeft(2, '0')}:${sleepAt.minute.toString().padLeft(2, '0')} 停止播放',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final minutes in [15, 30, 45, 60])
                      ActionChip(
                        label: Text('$minutes 分钟'),
                        onPressed: () => _session.audio.setSleep(minutes),
                      ),
                    if (sleepAt != null)
                      ActionChip(
                        label: const Text('取消定时'),
                        onPressed: () => _session.audio.setSleep(0),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _metadata(MusicTrack track) {
    final theme = Theme.of(context), colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.5,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                track.artist.isEmpty ? '未知歌手' : track.artist,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        AnimatedBuilder(
          animation: _session.library,
          builder: (context, _) => IconButton(
            tooltip: '收藏',
            onPressed: () => _session.library.toggleFavorite(track),
            style: IconButton.styleFrom(
              backgroundColor: colors.primary.withValues(alpha: .08),
              foregroundColor: colors.primary,
            ),
            icon: Icon(
              _session.library.isFavorite(track)
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
            ),
          ),
        ),
      ],
    );
  }

  Widget _controls(bool landscape) {
    final theme = Theme.of(context), colors = Theme.of(context).colorScheme;
    final audio = _session.audio;
    final busy = _session.opening || audio.loading || audio.seeking;
    final failed = _session.error != null || audio.error != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<(Duration, Duration)>(
          valueListenable: audio.progress,
          builder: (context, progress, _) {
            final duration = progress.$2.inMilliseconds.toDouble();
            final position = (_drag ?? progress.$1.inMilliseconds.toDouble())
                .clamp(0.0, duration > 0 ? duration : 1.0);
            final current = _lyrics.lastIndexWhere(
              (line) => line.time <= progress.$1,
            );
            final lyric = current >= 0
                ? _lyrics[current].text
                : _lyricLoading
                ? '正在获取歌词…'
                : _lyricError ?? (_lyrics.isEmpty ? '暂无歌词，静静听歌' : '前奏 · 稍候');
            return Column(
              children: [
                SizedBox(
                  key: const Key('music-lyric-region'),
                  height:
                      (landscape ? 72 : 96) *
                      MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      child: Column(
                        key: ValueKey(lyric),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            lyric,
                            key: const Key('music-current-lyric'),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colors.primary,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            current >= 0 && current + 1 < _lyrics.length
                                ? _lyrics[current + 1].text
                                : ' ',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant.withValues(
                                alpha: .65,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 15,
                    ),
                  ),
                  child: Slider(
                    key: const Key('music-seek-slider'),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    min: 0,
                    max: duration > 0 ? duration : 1,
                    value: position,
                    onChanged: duration <= 0 || busy
                        ? null
                        : (value) => setState(() => _drag = value),
                    onChangeEnd: duration <= 0 || busy
                        ? null
                        : (value) {
                            setState(() => _drag = null);
                            unawaited(
                              audio.seek(Duration(milliseconds: value.round())),
                            );
                          },
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _time(Duration(milliseconds: position.round())),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      _time(progress.$2),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
        SizedBox(height: landscape ? 8 : 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              tooltip: '上一首',
              iconSize: 32,
              onPressed: !busy && audio.current > 0 ? _session.previous : null,
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            SizedBox.square(
              dimension: landscape ? 58 : 68,
              child: IconButton.filled(
                tooltip: busy
                    ? '正在缓冲'
                    : failed
                    ? '重试播放'
                    : audio.playing
                    ? '暂停'
                    : '播放',
                onPressed: busy
                    ? null
                    : failed
                    ? _session.retry
                    : _session.toggle,
                style: IconButton.styleFrom(foregroundColor: colors.onPrimary),
                iconSize: 36,
                icon: busy
                    ? SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(
                          key: const Key('music-play-buffering'),
                          strokeWidth: 2.5,
                          color: colors.primary,
                        ),
                      )
                    : Icon(
                        failed
                            ? Icons.refresh_rounded
                            : audio.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
              ),
            ),
            IconButton(
              tooltip: '下一首',
              iconSize: 32,
              onPressed: !busy && audio.current + 1 < _session.queue.length
                  ? _session.next
                  : null,
              icon: const Icon(Icons.skip_next_rounded),
            ),
          ],
        ),
        SizedBox(height: landscape ? 0 : 4),
        // Reserve this line even when healthy: an error must not move the controls.
        SizedBox(
          height: 20 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
          child: failed
              ? TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('播放失败'),
                      content: SingleChildScrollView(
                        child: Text(_session.error ?? audio.error ?? '暂时无法播放'),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                  ),
                  child: Text(
                    '暂时无法播放 · 查看原因',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    ),
                  ),
                )
              : null,
        ),
        Tooltip(
          message: '播放队列',
          child: TextButton.icon(
            onPressed: _queue,
            icon: const Icon(Icons.queue_music_rounded, size: 18),
            label: Text('播放队列 · ${_session.queue.length} 首'),
            style: TextButton.styleFrom(
              foregroundColor: colors.onSurfaceVariant,
              minimumSize: Size(0, landscape ? 32 : 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _session,
    builder: (context, _) {
      final track = _session.current;
      return GlassScaffold(
        title: '正在播放',
        actions: [
          IconButton(
            tooltip: '播放设置',
            onPressed: _options,
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ],
        child: track == null
            ? Center(
                child: Text(
                  _session.error == null ? '暂无正在播放的音乐' : '暂时无法播放，请返回重试',
                ),
              )
            : _MusicArtworkBackdrop(
                cover: track.cover,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final landscape =
                        constraints.maxWidth >= 600 &&
                        constraints.maxWidth > constraints.maxHeight * 1.25;
                    final compact = constraints.maxHeight < 650;
                    final coverSize = landscape
                        ? (constraints.maxHeight - 48).clamp(160.0, 310.0)
                        : (constraints.maxWidth - 72).clamp(
                            160.0,
                            (constraints.maxHeight - 470).clamp(160.0, 310.0),
                          );
                    final artwork = Center(
                      child: _MusicAlbumArtwork(track: track, size: coverSize),
                    );
                    return SingleChildScrollView(
                      key: const Key('music-player-scroll'),
                      padding: EdgeInsets.fromLTRB(
                        28,
                        landscape
                            ? 12
                            : compact
                            ? 18
                            : 24,
                        28,
                        landscape ? 12 : 20,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: landscape ? 960 : 390,
                          ),
                          child: landscape
                              ? Row(
                                  key: const Key('music-player-landscape'),
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: artwork),
                                    const SizedBox(width: 32),
                                    Expanded(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _metadata(track),
                                          _controls(true),
                                        ],
                                      ),
                                    ),
                                  ],
                                )
                              : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    artwork,
                                    const SizedBox(height: 24),
                                    _metadata(track),
                                    _controls(false),
                                  ],
                                ),
                        ),
                      ),
                    );
                  },
                ),
              ),
      );
    },
  );
}

ImageProvider _musicCoverProvider(String url) =>
    ResizeImage(NetworkImage(url), width: 512);

class _MusicArtworkBackdrop extends StatefulWidget {
  const _MusicArtworkBackdrop({required this.cover, required this.child});
  final String? cover;
  final Widget child;
  @override
  State<_MusicArtworkBackdrop> createState() => _MusicArtworkBackdropState();
}

class _MusicArtworkBackdropState extends State<_MusicArtworkBackdrop> {
  Color? _color;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    _palette();
  }

  @override
  void didUpdateWidget(covariant _MusicArtworkBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cover != widget.cover) {
      _color = null;
      _palette();
    }
  }

  Future<void> _palette() async {
    final revision = ++_revision, url = MusicTrack.artworkUrl(widget.cover);
    if (url == null) return;
    final color = await PosterPaletteCache.resolve('music:$url', () async {
      final palette = await PaletteGenerator.fromImageProvider(
        _musicCoverProvider(url),
        size: const Size(80, 80),
        maximumColorCount: 12,
        timeout: const Duration(seconds: 6),
      );
      return palette.mutedColor?.color ?? palette.dominantColor?.color;
    });
    if (mounted && revision == _revision) setState(() => _color = color);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = _color ?? colors.primary;
    return AnimatedContainer(
      key: const Key('music-artwork-background'),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 650),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(color.withValues(alpha: .20), colors.surface),
            colors.surface,
            Color.alphaBlend(color.withValues(alpha: .10), colors.surface),
          ],
        ),
      ),
      child: widget.child,
    );
  }
}

class _MusicAlbumArtwork extends StatelessWidget {
  const _MusicAlbumArtwork({required this.track, required this.size});
  final MusicTrack track;
  final double size;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = DecoratedBox(
      key: const Key('music-album-fallback'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.primaryContainer, colors.tertiaryContainer],
        ),
      ),
      child: Center(
        child: Container(
          width: size * .70,
          height: size * .70,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                colors.primary.withValues(alpha: .55),
                colors.primary.withValues(alpha: .9),
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: .2)),
            boxShadow: [
              BoxShadow(
                color: colors.primary.withValues(alpha: .2),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Center(
            child: Container(
              width: size * .25,
              height: size * .25,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.primaryContainer,
                border: Border.all(
                  color: Colors.white.withValues(alpha: .35),
                  width: 3,
                ),
              ),
              child: Icon(
                Icons.music_note_rounded,
                color: colors.onPrimaryContainer,
                size: size * .12,
              ),
            ),
          ),
        ),
      ),
    );
    final url = MusicTrack.artworkUrl(track.cover);
    return Container(
      key: const Key('music-album-artwork'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: colors.primary.withValues(alpha: .16),
            blurRadius: 32,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: url == null
            ? fallback
            : Image(
                image: _musicCoverProvider(url),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : fallback,
              ),
      ),
    );
  }
}
