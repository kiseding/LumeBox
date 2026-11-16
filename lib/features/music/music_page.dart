import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../core/music/lx_catalog.dart';
import '../../core/music/music_library.dart';
import '../../core/music/music_models.dart';
import '../../core/music/music_service.dart';
import '../../core/music/music_session.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/video_glass_surface.dart';
import '../../shared/widgets/poster_gradient_scaffold.dart'
    show PosterPaletteCache;
import '../../shared/widgets/network_owned_state.dart';
import '../../core/net/network_cancellation.dart';
import '../../core/net/lume_http.dart';
import '../../core/net/lume_net.dart';
import '../shell/shell_dock.dart';

part 'music_discover_home.dart';
part 'music_now_playing.dart';

void _message(BuildContext context, Object error) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$error')));

Future<String?> _input(
  BuildContext context,
  String title,
  String hint, {
  String initial = '',
}) async {
  return showDialog<String>(
    context: context,
    builder: (_) => _MusicInput(title: title, hint: hint, initial: initial),
  );
}

class _MusicInput extends StatefulWidget {
  const _MusicInput({
    required this.title,
    required this.hint,
    required this.initial,
  });
  final String title, hint, initial;
  @override
  State<_MusicInput> createState() => _MusicInputState();
}

class _MusicInputState extends State<_MusicInput> {
  late final _controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(hintText: widget.hint),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('确定')),
    ],
  );
}

class MusicPage extends StatefulWidget {
  const MusicPage({super.key, this.library, this.service});
  final MusicLibrary? library;
  final MusicService? service;
  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage>
    with NetworkOwnedState<MusicPage> {
  late final _library = widget.library ?? MusicLibrary.instance;
  late final _service = widget.service ?? MusicService.instance;
  final _query = TextEditingController();
  final _searchFocus = FocusNode();
  ShellDockController? _dockSearch;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = ShellDockScope.maybeScopeOf(context);
    final controller =
        scope?.integratedSearch == true && TickerMode.valuesOf(context).enabled
        ? scope?.notifier
        : null;
    if (!identical(controller, _dockSearch)) _dockSearch?.detachSearch(this);
    _dockSearch = controller;
    controller?.attachSearch(this, () {
      if (!mounted) return;
      setState(() => _tab = 0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_dockSearch, controller)) {
          _searchFocus.requestFocus();
        }
      });
    });
  }

  int _tab = 0, _page = 1, _searchRevision = 0;
  bool _busy = false, _more = false, _ready = false, _searched = false;
  String? _error, _pluginId;
  String? get _activePluginId =>
      _library.plugin(_pluginId ?? '')?.enabled == true ? _pluginId : null;
  final _tracks = <MusicTrack>[];
  List<String> _failures = [];
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _library.load();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '音乐库加载失败：$e');
    }
  }

  Future<void> _search({bool next = false}) async {
    if (_query.text.trim().isEmpty) return;
    final revision = ++_searchRevision;
    final page = next ? _page + 1 : 1;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _searched = true;
      _error = null;
      if (!next) _tracks.clear();
    });
    try {
      final result = await networkRequests.run(
        'music-search',
        () => _service.search(
          _query.text.trim(),
          page: page,
          pluginId: _activePluginId,
        ),
      );
      if (!mounted || revision != _searchRevision) return;
      setState(() {
        final seen = _tracks.map((t) => t.key).toSet();
        _tracks.addAll(result.tracks.where((t) => seen.add(t.key)));
        _page = page;
        _more = result.hasMore;
        _failures = result.failures;
      });
    } catch (e) {
      if (e is! NetworkCancelled && mounted && revision == _searchRevision) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted && revision == _searchRevision) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _dockSearch?.detachSearch(this);
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_library, MusicSession.instance]),
    builder: (context, _) => GlassScaffold(
      title: _tab == 2 ? '音乐源' : '音乐',
      leading: _tab == 2
          ? IconButton(
              tooltip: '返回音乐',
              onPressed: () => setState(() => _tab = 0),
              icon: const Icon(Icons.arrow_back_ios_new_rounded),
            )
          : null,
      actions: [
        if (MusicSession.instance.current != null &&
            MusicSession.instance.miniPlayerHidden)
          IconButton(
            tooltip: '显示迷你播放器',
            onPressed: MusicSession.instance.showMiniPlayer,
            icon: const Icon(Icons.picture_in_picture_alt_rounded),
          ),
        if (_tab != 2)
          IconButton(
            tooltip: '音乐源',
            onPressed: () => setState(() => _tab = 2),
            icon: const Icon(Icons.library_music_outlined),
          ),
        IconButton(
          tooltip: '添加音乐源',
          onPressed: () => showMusicImport(context),
          icon: const Icon(Icons.add_rounded),
        ),
      ],
      child: Column(
        children: [
          if (_tab != 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                children: [
                  for (final (index, label) in [(0, '发现'), (1, '我的')])
                    Padding(
                      padding: const EdgeInsets.only(right: 24),
                      child: Semantics(
                        selected: _tab == index,
                        button: true,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => setState(() => _tab = index),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: _tab == index
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: _tab == index
                                          ? Theme.of(context)
                                                .colorScheme
                                                .primary
                                          : Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  width: 18,
                                  height: 3,
                                  decoration: BoxDecoration(
                                    color: _tab == index
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (!_ready && _error == null) const LinearProgressIndicator(),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          Expanded(
            child: switch (_tab) {
              0 => _discover(),
              1 => _mine(),
              _ => _sources(),
            },
          ),
        ],
      ),
    ),
  );
  void _resetSearch() {
    networkRequests.cancel('music-search');
    ++_searchRevision;
    _query.clear();
    setState(() {
      _searched = false;
      _busy = false;
      _tracks.clear();
      _failures = [];
      _error = null;
    });
  }

  Widget _discover() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _query,
                focusNode: _searchFocus,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: '搜索歌曲、歌手',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searched
                      ? IconButton(
                          tooltip: '返回推荐',
                          onPressed: _resetSearch,
                          icon: const Icon(Icons.close_rounded),
                        )
                      : null,
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '选择音乐源',
              initialValue: _activePluginId ?? '',
              icon: const Icon(Icons.tune_rounded),
              itemBuilder: (_) => [
                const PopupMenuItem(value: '', child: Text('全部已启用音乐源')),
                for (final p in _library.plugins.where((p) => p.enabled))
                  PopupMenuItem(value: p.id, child: Text(p.name)),
              ],
              onSelected: (value) {
                setState(() => _pluginId = value.isEmpty ? null : value);
                if (_searched) unawaited(_search());
              },
            ),
          ],
        ),
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_searched && _failures.isNotEmpty)
        ExpansionTile(
          title: Text('${_failures.length} 项搜索失败'),
          children: [
            for (final error in _failures)
              ListTile(dense: true, title: Text(error)),
          ],
        ),
      Expanded(
        child: !_searched
            ? MusicDiscoverHome(
                library: _library,
                service: _service,
                pluginId: _activePluginId,
                onSearch: (keyword) {
                  _query.text = keyword;
                  unawaited(_search());
                },
                onAdd: () => showMusicImport(context),
                onLibrary: () => setState(() => _tab = 1),
                onSources: () => setState(() => _tab = 2),
              )
            : _tracks.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _busy ? '正在搜索…' : '未搜索到相关歌曲',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView.builder(
                padding: EdgeInsets.only(
                  bottom: ShellDockScope.bottomInset(context),
                ),
                itemCount: _tracks.length + (_more ? 1 : 0),
                itemBuilder: (context, index) => index == _tracks.length
                    ? TextButton(
                        onPressed: _busy ? null : () => _search(next: true),
                        child: const Text('加载更多'),
                      )
                    : MusicTrackTile(
                        track: _tracks[index],
                        tracks: _tracks,
                        index: index,
                      ),
              ),
      ),
    ],
  );
  Widget _mine() => ListView(
    padding: EdgeInsets.only(bottom: ShellDockScope.bottomInset(context)),
    children: [
      const ListTile(title: Text('我的收藏')),
      if (_library.favorites.isEmpty)
        const ListTile(subtitle: Text('在歌曲右侧点爱心收藏')),
      for (final row in _library.favorites.indexed)
        MusicTrackTile(
          track: row.$2,
          tracks: _library.favorites,
          index: row.$1,
        ),
      const Divider(),
      const ListTile(title: Text('最近播放')),
      if (_library.recent.isEmpty)
        const ListTile(subtitle: Text('播放过的歌曲会出现在这里')),
      for (final row in _library.recent.indexed)
        MusicTrackTile(track: row.$2, tracks: _library.recent, index: row.$1),
      if (_library.queue.isNotEmpty)
        ListTile(
          leading: const Icon(Icons.queue_music),
          title: const Text('恢复上次播放队列'),
          onTap: () async {
            await MusicSession.instance.play(List.of(_library.queue));
            if (mounted) openMusicPlayer(context);
          },
        ),
    ],
  );
  Widget _sources() => ListView(
    padding: EdgeInsets.only(bottom: ShellDockScope.bottomInset(context)),
    children: [
      ListTile(
        leading: const Icon(Icons.add_circle_outline),
        title: const Text('添加音乐源'),
        subtitle: const Text('本地 JS / 脚本链接 / MusicFree 订阅'),
        onTap: () => showMusicImport(context),
      ),
      ListTile(
        title: const Text('优先音质'),
        trailing: DropdownButton<String>(
          value: _library.quality,
          items: [
            for (final row in [
              ('low', '流畅'),
              ('standard', '标准'),
              ('high', '无损'),
              ('super', '高解析'),
            ])
              DropdownMenuItem(value: row.$1, child: Text(row.$2)),
          ],
          onChanged: (value) async {
            if (value == null) return;
            _library.quality = value;
            try {
              await _library.save();
            } catch (e) {
              if (mounted) _message(context, e);
            }
          },
        ),
      ),
      if (_library.plugins.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '尚未添加音乐源。MusicFree 插件可以提供搜索、歌词和歌单；LX 脚本负责播放地址解析，搜索由平台曲库提供。',
          ),
        ),
      for (final plugin in _library.plugins)
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [
              SwitchListTile(
                title: Text(plugin.name),
                subtitle: Text(
                  '${plugin.label} · ${plugin.version}\n${plugin.platforms.keys.map(LxCatalog.label).join(' / ')}',
                ),
                value: plugin.enabled,
                onChanged: (value) async {
                  try {
                    MusicService.instance.invalidate(plugin.id);
                    await _library.change(plugin.copyWith(enabled: value));
                  } catch (e) {
                    if (mounted) _message(context, e);
                  }
                },
              ),
              Wrap(
                children: [
                  if (plugin.origin.isNotEmpty)
                    TextButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('更新'),
                      onPressed: () => _update(plugin),
                    ),
                  if (plugin.variables.isNotEmpty)
                    TextButton.icon(
                      icon: const Icon(Icons.tune),
                      label: const Text('参数'),
                      onPressed: () => _variables(plugin),
                    ),
                  if (plugin.capabilities.contains('importMusicSheet'))
                    TextButton.icon(
                      icon: const Icon(Icons.playlist_add),
                      label: const Text('导入歌单'),
                      onPressed: () => _sheet(plugin),
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除'),
                    onPressed: () async {
                      try {
                        MusicService.instance.invalidate(plugin.id);
                        await _library.remove(plugin.id);
                      } catch (e) {
                        if (mounted) _message(context, e);
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
    ],
  );
  Future<void> _update(MusicPlugin plugin) async {
    try {
      final result = await MusicService.instance.importUrl(plugin.origin);
      if (mounted) {
        _message(
          context,
          '已更新 ${result.imported} 个音乐源${result.failures.isEmpty ? '' : '，失败 ${result.failures.length} 个'}',
        );
      }
    } catch (e) {
      if (mounted) _message(context, e);
    }
  }

  Future<void> _variables(MusicPlugin plugin) async {
    final values = Map<String, String>.of(plugin.values);
    for (final variable in plugin.variables) {
      if (!mounted) return;
      final key = '${variable['key']}';
      final value = await _input(
        context,
        '${variable['name'] ?? key}',
        '插件参数',
        initial: values[key] ?? '',
      );
      if (value == null) return;
      values[key] = value;
    }
    try {
      await _library.change(plugin.copyWith(values: values));
    } catch (e) {
      if (mounted) _message(context, e);
    }
  }

  Future<void> _sheet(MusicPlugin plugin) async {
    final url = await _input(context, '导入歌单', '粘贴此平台的歌单链接');
    if (url == null || url.isEmpty) return;
    try {
      final tracks = await MusicService.instance.importSheet(plugin.id, url);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GlassScaffold(
            title: '导入的歌单',
            child: ListView(
              children: [
                if (tracks.isEmpty) const ListTile(title: Text('歌单为空')),
                for (final row in tracks.indexed)
                  MusicTrackTile(track: row.$2, tracks: tracks, index: row.$1),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) _message(context, e);
    }
  }
}

Future<void> showMusicImport(BuildContext context) async {
  final method = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('添加音乐源'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'url'),
          child: const ListTile(
            leading: Icon(Icons.link),
            title: Text('脚本 / 订阅链接'),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'file'),
          child: const ListTile(
            leading: Icon(Icons.file_open_outlined),
            title: Text('本地 JS 文件'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text('支持 MusicFree 和 LX 标准脚本；插件可联网，请使用你信任的来源。'),
        ),
      ],
    ),
  );
  if (!context.mounted || method == null) return;
  try {
    if (method == 'file') {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'JavaScript',
            extensions: ['js'],
            uniformTypeIdentifiers: ['public.javascript'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 4 * 1024 * 1024) {
        throw const FormatException('音乐插件超过 4 MB');
      }
      final plugin = await MusicService.instance.importScript(
        await file.readAsString(),
      );
      if (context.mounted) {
        _message(context, '已添加 ${plugin.name}（${plugin.label}）');
      }
    } else {
      final url = await _input(context, '脚本 / 订阅链接', 'https://…');
      if (url == null || url.isEmpty) return;
      final result = await MusicService.instance.importUrl(url);
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('已导入 ${result.imported} 个音乐源'),
            content: result.failures.isEmpty
                ? null
                : SingleChildScrollView(
                    child: Text(result.failures.join('\n')),
                  ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成'),
              ),
            ],
          ),
        );
      }
    }
  } catch (e) {
    if (context.mounted) _message(context, e);
  }
}

class MusicTrackTile extends StatelessWidget {
  const MusicTrackTile({
    super.key,
    required this.track,
    required this.tracks,
    required this.index,
  });
  final MusicTrack track;
  final List<MusicTrack> tracks;
  final int index;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: MusicLibrary.instance,
    builder: (context, _) => ListTile(
      leading: const Icon(Icons.music_note_outlined),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          track.artist,
          track.album,
          MusicLibrary.instance.plugin(track.pluginId)?.name ?? '音源已删除',
        ].where((s) => s.isNotEmpty).join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: MusicLibrary.instance.isFavorite(track) ? '取消收藏' : '收藏',
        icon: Icon(
          MusicLibrary.instance.isFavorite(track)
              ? Icons.favorite
              : Icons.favorite_border,
        ),
        onPressed: () async {
          try {
            await MusicLibrary.instance.toggleFavorite(track);
          } catch (e) {
            if (context.mounted) _message(context, e);
          }
        },
      ),
      onTap: () {
        unawaited(MusicSession.instance.play(List.of(tracks), index: index));
        openMusicPlayer(context);
      },
    ),
  );
}

void openMusicPlayer(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const MusicPlayerPage()));

class MusicMiniPlayer extends StatelessWidget {
  const MusicMiniPlayer({super.key, this.session});
  final MusicSession? session;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session ?? MusicSession.instance,
    builder: (context, _) {
      final player = session ?? MusicSession.instance, track = player.current;
      if (track == null || player.miniPlayerHidden) {
        return const SizedBox.shrink();
      }
      final theme = Theme.of(context);
      final dark = theme.brightness == Brightness.dark;
      final ink = dark ? Colors.white : VideoGlassSurface.foreground;
      final accent = theme.colorScheme.primary;
      final busy =
          player.opening || player.audio.loading || player.audio.seeking;
      final failed = player.error != null || player.audio.error != null;
      final duration = player.audio.duration.inMilliseconds;
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .08),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: VideoGlassSurface(
          key: const Key('music-mini-player'),
          preferNative: true,
          dark: dark,
          radius: 24,
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => openMusicPlayer(context),
                          child: Row(
                            children: [
                              if (constraints.maxWidth >= 220)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: SizedBox.square(
                                    dimension: 36,
                                    child: track.cover?.isNotEmpty == true
                                        ? Image.network(
                                            track.cover!,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) =>
                                                _cover(accent),
                                          )
                                        : _cover(accent),
                                  ),
                                ),
                              if (constraints.maxWidth >= 220)
                                const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      track.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: ink,
                                      ),
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      failed
                                          ? '播放失败，点击重试'
                                          : (busy
                                                ? '正在加载…'
                                                : track.artist.isEmpty
                                                ? '正在播放'
                                                : track.artist),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: ink.withValues(alpha: .6),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox.square(
                        dimension: 44,
                        child: IconButton(
                          tooltip: failed
                              ? '重试播放'
                              : player.audio.playing
                              ? '暂停'
                              : '播放',
                          onPressed: busy
                              ? null
                              : failed
                              ? player.retry
                              : player.toggle,
                          style: IconButton.styleFrom(
                            backgroundColor: accent.withValues(alpha: .12),
                            foregroundColor: accent,
                          ),
                          icon: busy
                              ? SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: accent,
                                  ),
                                )
                              : Icon(
                                  failed
                                      ? Icons.refresh_rounded
                                      : player.audio.playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                        ),
                      ),
                      if (constraints.maxWidth >= 260)
                        SizedBox.square(
                          dimension: 44,
                          child: IconButton(
                            tooltip: '下一首',
                            onPressed:
                                busy ||
                                    player.audio.current + 1 >=
                                        player.queue.length
                                ? null
                                : player.next,
                            icon: const Icon(Icons.skip_next_rounded, size: 23),
                          ),
                        ),
                      SizedBox.square(
                        dimension: 44,
                        child: IconButton(
                          tooltip: '隐藏迷你播放器（继续播放）',
                          onPressed: player.hideMiniPlayer,
                          icon: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 22,
                            color: ink.withValues(alpha: .6),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                LinearProgressIndicator(
                  key: const Key('music-mini-progress'),
                  minHeight: 2,
                  value: duration > 0
                      ? (player.audio.position.inMilliseconds / duration).clamp(
                          0,
                          1,
                        )
                      : 0,
                  color: accent.withValues(alpha: .7),
                  backgroundColor: accent.withValues(alpha: .06),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _cover(Color accent) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [accent.withValues(alpha: .22), accent.withValues(alpha: .06)],
      ),
    ),
    child: Icon(Icons.music_note_rounded, color: accent, size: 25),
  );
}
