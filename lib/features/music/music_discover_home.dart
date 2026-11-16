part of 'music_page.dart';

/// Discovery uses the user's enabled providers. Local listening history remains
/// useful when a provider is unavailable or the device is offline.
class MusicDiscoverHome extends StatefulWidget {
  const MusicDiscoverHome({
    super.key,
    required this.library,
    required this.service,
    required this.onSearch,
    required this.onAdd,
    required this.onLibrary,
    required this.onSources,
    this.pluginId,
  });
  final MusicLibrary library;
  final MusicService service;
  final String? pluginId;
  final ValueChanged<String> onSearch;
  final VoidCallback onAdd, onLibrary, onSources;
  @override
  State<MusicDiscoverHome> createState() => _MusicDiscoverHomeState();
}

class _MusicDiscoverHomeState extends State<MusicDiscoverHome>
    with NetworkOwnedState<MusicDiscoverHome> {
  MusicDiscoveryResult _data = const MusicDiscoveryResult();
  bool _loading = false, _booting = true;
  String _signature = '';
  int _revision = 0, _sheetOffset = 0;
  String? _error;
  List<MusicPlugin> get _enabled => widget.library.plugins
      .where(
        (p) =>
            p.enabled && (widget.pluginId == null || p.id == widget.pluginId),
      )
      .toList();
  String get _fingerprint =>
      _enabled.map((p) => '${p.id}:${p.version}:${p.values}').join('|');
  @override
  void initState() {
    super.initState();
    widget.library.addListener(_libraryChanged);
    unawaited(_boot());
  }

  Future<void> _boot() async {
    try {
      await widget.library.load();
      if (!mounted) return;
      _booting = false;
      _signature = _fingerprint;
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() {
          _booting = false;
          _error = '音乐库加载失败，请重试';
        });
      }
    }
  }

  void _libraryChanged() {
    if (!mounted || _booting) return;
    if (_signature != _fingerprint) {
      _signature = _fingerprint;
      _data = const MusicDiscoveryResult();
      _sheetOffset = 0;
      unawaited(_load());
    } else {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(MusicDiscoverHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pluginId != widget.pluginId) _libraryChanged();
  }

  Future<void> _load({bool refresh = false}) async {
    final revision = ++_revision;
    if (_enabled.isEmpty) {
      networkRequests.cancel('discovery');
      setState(() {
        _loading = false;
        _error = null;
        _data = const MusicDiscoveryResult();
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await networkRequests.run(
        'discovery',
        () => widget.service.discover(
          pluginId: widget.pluginId,
          refresh: refresh,
        ),
        timeout: const Duration(seconds: 35),
      );
      if (mounted && revision == _revision) setState(() => _data = data);
    } catch (e) {
      if (mounted && revision == _revision && e is! NetworkCancelled) {
        setState(() => _error = '推荐暂时没有加载成功，请稍后重试');
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    widget.library.removeListener(_libraryChanged);
    super.dispose();
  }

  void _openCollection(MusicCollection collection) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) =>
          MusicCollectionPage(collection: collection, service: widget.service),
    ),
  );

  Widget _section(String title, {String? action, VoidCallback? onTap}) =>
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (action != null)
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: onTap,
                child: Text(action, style: const TextStyle(fontSize: 12)),
              ),
          ],
        ),
      );

  Widget _notice(
    String title,
    String text, {
    String? action,
    VoidCallback? onTap,
    IconData icon = Icons.music_note_rounded,
  }) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 24, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          text,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (action != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: FilledButton.tonal(onPressed: onTap, child: Text(action)),
          ),
      ],
    ),
  );

  Widget _emptyLine(String text, {IconData icon = Icons.music_note_rounded}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _libraryEntry(String title, IconData icon, {int? count}) => InkWell(
    onTap: widget.onLibrary,
    borderRadius: BorderRadius.circular(18),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary
                  .withValues(alpha: .08),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              icon,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          if (count != null && count > 0) ...[
            const SizedBox(width: 4),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _collections(List<MusicCollection> items) => LayoutBuilder(
    builder: (context, bounds) {
      final largeText = MediaQuery.textScalerOf(context).scale(13) > 17;
      final columns = bounds.maxWidth >= 720
          ? 4
          : bounds.maxWidth >= 340 && !largeText
          ? 3
          : 2;
      final width = (bounds.maxWidth - 10 * (columns - 1)) / columns;
      return Wrap(
        spacing: 10,
        runSpacing: 12,
        children: [
          for (final item in items)
            SizedBox(
              width: width,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _openCollection(item),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: _MusicArtwork(
                        url: item.cover,
                        title: item.title,
                        chart: item.chart,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _songSection(
    String title,
    List<MusicTrack> tracks,
    MusicCollection? chart,
  ) => Column(
    children: [
      _section(
        title,
        action: '查看榜单',
        onTap: chart == null ? null : () => _openCollection(chart),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          chart?.title ?? '',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      const SizedBox(height: 6),
      for (final entry in tracks.take(5).indexed)
        MusicTrackTile(track: entry.$2, tracks: tracks, index: entry.$1),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () {
            unawaited(MusicSession.instance.play(tracks));
            openMusicPlayer(context);
          },
          icon: const Icon(Icons.play_circle_outline_rounded),
          label: const Text('播放全部'),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    final recent = library.recent
        .where((track) => library.plugin(track.pluginId)?.enabled == true)
        .toList();
    final last = MusicSession.instance.current ?? recent.firstOrNull;
    final sheets = _data.sheets;
    final visibleSheets = sheets.isEmpty
        ? <MusicCollection>[]
        : [
            for (var i = 0; i < sheets.length.clamp(0, 6); i++)
              sheets[(_sheetOffset + i) % sheets.length],
          ];
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: ListView(
        key: const PageStorageKey('music-discover-home'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16,
          4,
          16,
          ShellDockScope.bottomInset(context) + 24,
        ),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Theme.of(context).colorScheme.primaryContainer,
                  Theme.of(context).colorScheme.secondaryContainer
                      .withValues(alpha: .65),
                ],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  last == null ? '让喜欢的音乐，陪你一会儿' : '继续听',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  last == null ? '发现一张歌单，或从一首熟悉的歌开始。' : last.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                if (last != null && last.artist.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(last.artist),
                  ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  onPressed: last != null
                      ? () {
                          unawaited(MusicSession.instance.resume());
                          openMusicPlayer(context);
                        }
                      : _enabled.isEmpty
                      ? widget.onAdd
                      : () => widget.onSearch('华语'),
                  icon: Icon(
                    last != null
                        ? Icons.play_arrow_rounded
                        : _enabled.isEmpty
                        ? Icons.add_rounded
                        : Icons.explore_outlined,
                  ),
                  label: Text(
                    last != null
                        ? '继续播放'
                        : _enabled.isEmpty
                        ? '添加音乐源'
                        : '开始听歌',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          GlassCard(
            radius: 18,
            padding: EdgeInsets.zero,
            child: IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(
                    child: _libraryEntry(
                      '收藏',
                      Icons.favorite_border_rounded,
                      count: library.favorites.length,
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    indent: 16,
                    endIndent: 16,
                    color: Theme.of(context).dividerColor
                        .withValues(alpha: .12),
                  ),
                  Expanded(child: _libraryEntry('最近播放', Icons.history_rounded)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final topic in ['华语', '粤语', '纯音乐', '经典老歌', '轻音乐', '爵士'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text(topic),
                      labelStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: const StadiumBorder(),
                      onPressed: () => _enabled.isEmpty
                          ? widget.onAdd()
                          : widget.onSearch(topic),
                    ),
                  ),
              ],
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 20),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          _section(
            '精选歌单',
            action: sheets.length > 6 ? '换一批' : null,
            onTap: () => setState(
              () => _sheetOffset = (_sheetOffset + 6) % sheets.length,
            ),
          ),
          if (visibleSheets.isNotEmpty)
            _collections(visibleSheets)
          else if (!_loading)
            if (_enabled.isEmpty)
              _emptyLine('添加音乐源后，在这里发现精选歌单。')
            else
              _notice(
                '歌单正在等你发现',
                '当前音源暂未提供推荐歌单。你可以搜索喜欢的歌手，或切换其他音乐源。',
                action: '选择音乐源',
                onTap: widget.onSources,
              ),
          if (_data.hot.isNotEmpty)
            _songSection('热门歌曲', _data.hot, _data.hotChart),
          if (_data.fresh.isNotEmpty)
            _songSection('新歌速递', _data.fresh, _data.freshChart),
          if (_data.charts.isNotEmpty) ...[
            _section('排行榜'),
            _collections(_data.charts.take(4).toList()),
            if (_data.charts.length > 4)
              TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (context) => SafeArea(
                    child: SizedBox(
                      height: MediaQuery.sizeOf(context).height * .65,
                      child: ListView(
                        children: [
                          const ListTile(title: Text('全部榜单')),
                          for (final chart in _data.charts)
                            ListTile(
                              title: Text(chart.title),
                              subtitle: Text(chart.subtitle),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {
                                Navigator.pop(context);
                                _openCollection(chart);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                child: const Text('全部榜单'),
              ),
          ],
          if (_error != null || _data.failures.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: _notice(
                '部分推荐暂不可用',
                _error ?? '已保留可用内容，你可以重试或切换音乐源。',
                icon: Icons.cloud_off_outlined,
                action: '重新加载',
                onTap: () => _load(refresh: true),
              ),
            ),
          _section('最近播放', action: '查看全部', onTap: widget.onLibrary),
          if (recent.isEmpty)
            _emptyLine('听过的歌，会自动留在这里。', icon: Icons.history_rounded)
          else
            SizedBox(
              height: 164 + MediaQuery.textScalerOf(context).scale(12),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: recent.length.clamp(0, 10),
                separatorBuilder: (_, index) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final track = recent[index];
                  return SizedBox(
                    width: 112,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        unawaited(
                          MusicSession.instance.play(recent, index: index),
                        );
                        openMusicPlayer(context);
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox.square(
                            dimension: 112,
                            child: _MusicArtwork(
                              url: track.cover,
                              title: track.title,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            track.artist,
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
            ),
        ],
      ),
    );
  }
}

class _MusicArtwork extends StatefulWidget {
  const _MusicArtwork({this.url, required this.title, this.chart = false});
  final String? url;
  final String title;
  final bool chart;
  @override
  State<_MusicArtwork> createState() => _MusicArtworkState();
}

class _MusicArtworkState extends State<_MusicArtwork>
    with NetworkOwnedState<_MusicArtwork> {
  static final _cache = <String, Uint8List>{};
  Uint8List? _bytes;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_MusicArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final url = widget.url;
    networkRequests.cancel('artwork');
    if (url == null || url.isEmpty) return;
    _bytes = _cache.remove(url);
    if (_bytes != null) {
      _cache[url] = _bytes!;
      return;
    }
    final http = LumeHttp(settings: LumeNet.settings, source: '音乐封面');
    try {
      final response = await networkRequests.run(
        'artwork',
        () => http.send(
          url: url,
          headers: {
            'User-Agent': 'Mozilla/5.0',
            if (Uri.tryParse(url)?.host.endsWith('.music.126.net') == true)
              'Referer': 'https://music.163.com/',
          },
          maxBytes: 2 * 1024 * 1024,
          timeout: const Duration(seconds: 12),
        ),
      );
      if (!mounted || widget.url != url || response.statusCode != 200) return;
      if (_cache.length >= 24) _cache.remove(_cache.keys.first);
      _cache[url] = response.body;
      setState(() => _bytes = response.body);
    } catch (_) {
      /* An unavailable cover never prevents listening. */
    } finally {
      http.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [colors.primaryContainer, colors.secondaryContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          widget.chart ? Icons.equalizer_rounded : Icons.album_rounded,
          size: 42,
          color: colors.primary.withValues(alpha: .7),
        ),
      ),
    );
    return Semantics(
      label: widget.title,
      image: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: _bytes == null
            ? fallback
            : Image.memory(
                _bytes!,
                fit: BoxFit.cover,
                cacheWidth: 480,
                errorBuilder: (_, error, stack) => fallback,
              ),
      ),
    );
  }
}

class MusicCollectionPage extends StatefulWidget {
  const MusicCollectionPage({
    super.key,
    required this.collection,
    required this.service,
  });
  final MusicCollection collection;
  final MusicService service;
  @override
  State<MusicCollectionPage> createState() => _MusicCollectionPageState();
}

class _MusicCollectionPageState extends State<MusicCollectionPage>
    with NetworkOwnedState<MusicCollectionPage> {
  final _tracks = <MusicTrack>[];
  bool _busy = false, _more = false;
  int _page = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await networkRequests.run(
        'collection',
        () =>
            widget.service.collectionTracks(widget.collection, page: _page + 1),
        timeout: const Duration(seconds: 25),
      );
      if (!mounted) return;
      setState(() {
        final seen = _tracks.map((t) => t.key).toSet();
        final added = result.tracks.where((t) => seen.add(t.key)).toList();
        _tracks.addAll(added);
        _page++;
        _more = result.hasMore && added.isNotEmpty;
      });
    } catch (e) {
      if (mounted && e is! NetworkCancelled) {
        setState(() => _error = '歌单加载失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.collection.title)),
    body: ListView(
      padding: EdgeInsets.only(
        bottom: ShellDockScope.bottomInset(context) + 24,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 88,
                child: _MusicArtwork(
                  url: widget.collection.cover,
                  title: widget.collection.title,
                  chart: widget.collection.chart,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.collection.title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(widget.collection.subtitle),
                    const SizedBox(height: 8),
                    Text(
                      '已加载 ${_tracks.length} 首',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            onPressed: _tracks.isEmpty
                ? null
                : () {
                    unawaited(MusicSession.instance.play(List.of(_tracks)));
                    openMusicPlayer(context);
                  },
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('播放全部'),
          ),
        ),
        const SizedBox(height: 12),
        for (final entry in _tracks.indexed)
          MusicTrackTile(track: entry.$2, tracks: _tracks, index: entry.$1),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_error != null)
          ListTile(
            title: Text(_error!),
            trailing: TextButton(onPressed: _load, child: const Text('重试')),
          ),
        if (!_busy && _error == null && _tracks.isEmpty)
          const ListTile(title: Text('歌单里暂时没有歌曲')),
        if (_more && !_busy && _error == null)
          TextButton(onPressed: _load, child: const Text('加载更多')),
      ],
    ),
  );
}
