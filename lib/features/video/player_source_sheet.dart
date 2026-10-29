import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/source/source.dart';
import '../../shared/widgets/video_glass_surface.dart';
import 'player_layout.dart';
import 'video_episode_catalog.dart';

class PlayerSourceLine {
  const PlayerSourceLine(
    this.name, {
    this.current = false,
    this.available = true,
  });
  final String name;
  final bool current, available;
}

enum PlayerSourceTab { episodes, lines, quality }

/// Chapters, source routes and media variants have distinct selection semantics.
class PlayerSourceSheet extends StatefulWidget {
  const PlayerSourceSheet({
    super.key,
    required this.address,
    this.qualities = const [],
    this.currentIndex = 0,
    this.onSelectQuality,
    this.loadEpisodes,
    this.currentChapterId,
    this.onSelectEpisode,
    this.onSwitchLine,
    this.loadLines,
    this.onSelectLine,
    this.initialTab = PlayerSourceTab.episodes,
  });
  final String address;
  final List<VideoQuality> qualities;
  final int currentIndex;
  final FutureOr<void> Function(int)? onSelectQuality;
  final Future<List<SourceChapter>> Function()? loadEpisodes;
  final String? currentChapterId;
  final Future<bool> Function(int)? onSelectEpisode;
  final VoidCallback? onSwitchLine;
  final Future<List<PlayerSourceLine>> Function()? loadLines;
  final Future<bool> Function(String)? onSelectLine;
  final PlayerSourceTab initialTab;

  @override
  State<PlayerSourceSheet> createState() => _PlayerSourceSheetState();
}

class _PlayerSourceSheetState extends State<PlayerSourceSheet> {
  Future<List<SourceChapter>>? _episodes;
  Future<List<PlayerSourceLine>>? _lines;
  late PlayerSourceTab _tab = widget.initialTab;
  final _scroll = ScrollController();
  bool _busy = false, _reverse = false, _located = false;
  String? _error;
  int? _pending;
  int _columns = 4, _segment = 0;
  List<SourceChapter> _chapters = [];

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _select(int index, {bool quality = false, String? line}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _pending = quality ? null : index;
      _error = null;
    });
    try {
      final bool ok;
      if (line != null) {
        ok = await widget.onSelectLine?.call(line) ?? false;
      } else if (quality) {
        await widget.onSelectQuality?.call(index);
        ok = true;
      } else {
        ok = await widget.onSelectEpisode?.call(index) ?? false;
      }
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _error = line != null ? '切换失败，请重试' : '切集失败，请重试');
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = quality || line != null ? '切换失败，请重试' : '切集失败，请重试',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _pending = null;
        });
      }
    }
  }

  void _locate(int index) {
    if (index < 0 || index >= _chapters.length) return;
    final orderedIndex = _reverse ? _chapters.length - 1 - index : index;
    final segment = orderedIndex ~/ 50;
    if (_segment != segment) setState(() => _segment = segment);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        ((orderedIndex % 50) ~/ _columns * 52.0).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        ),
        duration: PlayerLayout.motion(context),
        curve: Curves.easeOutCubic,
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _locateCurrent() =>
      _locate(_chapters.indexWhere((c) => c.id == widget.currentChapterId));

  Future<void> _jump() async {
    final controller = TextEditingController();
    final index = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('跳转集数'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: '第几集（1–${_chapters.length}）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = int.tryParse(controller.text);
              if (value != null && value >= 1 && value <= _chapters.length) {
                Navigator.pop(context, value - 1);
              }
            },
            child: const Text('定位'),
          ),
        ],
      ),
    );
    // Dialog exit animation can still reference its controller.
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    if (mounted && index != null) _locate(index);
  }

  Widget _buildEpisodes() {
    _episodes ??= widget.loadEpisodes?.call();
    return FutureBuilder<List<SourceChapter>>(
      future: _episodes,
      builder: (context, snapshot) {
        if (_episodes == null) return const Center(child: Text('当前视频没有剧集列表'));
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: TextButton.icon(
              onPressed: () => setState(() {
                _located = false;
                _episodes = widget.loadEpisodes?.call();
              }),
              icon: const Icon(Icons.refresh),
              label: const Text('剧集加载失败，点击重试'),
            ),
          );
        }
        _chapters = snapshot.data ?? [];
        if (_chapters.isEmpty) return const Center(child: Text('图源暂未提供剧集'));
        if (!_located) {
          _located = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _locateCurrent();
          });
        }
        final start = _segment * 50;
        final end = (start + 50).clamp(0, _chapters.length);
        return Column(
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                Text(
                  '共 ${_chapters.length} 集',
                  style: const TextStyle(fontSize: 12),
                ),
                TextButton(
                  onPressed: _locateCurrent,
                  child: const Text('定位当前'),
                ),
                TextButton(
                  onPressed: () {
                    setState(() => _reverse = !_reverse);
                    _locateCurrent();
                  },
                  child: Text(_reverse ? '倒序' : '正序'),
                ),
              ],
            ),
            if (_chapters.length > 50)
              Row(
                children: [
                  Expanded(
                    child: DropdownButton<int>(
                      value: _segment,
                      isExpanded: true,
                      items: List.generate((_chapters.length / 50).ceil(), (i) {
                        final first = _reverse
                            ? _chapters.length - i * 50
                            : i * 50 + 1;
                        final last = _reverse
                            ? (_chapters.length - i * 50 - 49).clamp(
                                1,
                                _chapters.length,
                              )
                            : (i * 50 + 50).clamp(1, _chapters.length);
                        return DropdownMenuItem(
                          value: i,
                          child: Text('$first–$last 集'),
                        );
                      }),
                      onChanged: _busy
                          ? null
                          : (v) {
                              if (v != null) {
                                setState(() {
                                  _segment = v;
                                  _scroll.jumpTo(0);
                                });
                              }
                            },
                    ),
                  ),
                  TextButton(onPressed: _jump, child: const Text('跳转集数')),
                ],
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, bounds) {
                  final longLabels = _chapters.any(
                    (c) => VideoEpisodeCatalog.labelOf(c).length > 8,
                  );
                  final longest = [
                    for (final (i, chapter) in _chapters.indexed)
                      VideoEpisodeCatalog.displayLabel(chapter, i),
                  ].reduce((a, b) => a.length >= b.length ? a : b);
                  final measure = TextPainter(
                    text: TextSpan(
                      text: longest,
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(fontSize: 12),
                    ),
                    textDirection: Directionality.of(context),
                    textScaler: MediaQuery.textScalerOf(context),
                  )..layout();
                  _columns = PlayerLayout.episodeColumns(
                    bounds.maxWidth,
                    longLabels: longLabels,
                    labelWidth: measure.width,
                  );
                  measure.dispose();
                  return GridView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 12),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _columns,
                      mainAxisExtent: 44,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: end - start,
                    itemBuilder: (context, visibleIndex) {
                      final orderedIndex = start + visibleIndex;
                      final index = _reverse
                          ? _chapters.length - 1 - orderedIndex
                          : orderedIndex;
                      final chapter = _chapters[index];
                      final current = chapter.id == widget.currentChapterId;
                      return Tooltip(
                        message: chapter.title,
                        child: ChoiceChip(
                          label: SizedBox(
                            width: double.infinity,
                            child: _pending == index
                                ? const Center(
                                    child: SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : Text(
                                    VideoEpisodeCatalog.displayLabel(
                                      chapter,
                                      index,
                                    ),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                          ),
                          selected: current,
                          showCheckmark: false,
                          padding: EdgeInsets.zero,
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 2,
                          ),
                          labelStyle: TextStyle(
                            fontSize: 12,
                            color: current
                                ? Theme.of(context).colorScheme.onPrimary
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                          selectedColor: Theme.of(context).colorScheme.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          onSelected: _busy ? null : (_) => _select(index),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _copy() async {
    if (widget.address.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: widget.address.trim()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(duration: Duration(seconds: 1), content: Text('已复制播放地址')),
    );
  }

  Widget _variants() {
    if (widget.qualities.isEmpty) {
      return const Center(child: Text('当前片源未提供多画质选项'));
    }
    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('按片源原始名称显示，切换后恢复当前进度', style: TextStyle(fontSize: 12)),
        ),
        for (var i = 0; i < widget.qualities.length; i++)
          ListTile(
            title: Text(widget.qualities[i].label),
            trailing: i == widget.currentIndex ? const Icon(Icons.check) : null,
            enabled: !_busy && widget.onSelectQuality != null,
            onTap: () => _select(i, quality: true),
          ),
      ],
    );
  }

  Widget _buildLines() {
    _lines ??= widget.loadLines?.call();
    return FutureBuilder<List<PlayerSourceLine>>(
      future: _lines,
      builder: (context, snapshot) {
        if (_lines != null &&
            snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: () =>
                  setState(() => _lines = widget.loadLines?.call()),
              child: const Text('线路加载失败，点击重试'),
            ),
          );
        }
        final lines = snapshot.data ?? const <PlayerSourceLine>[];
        return ListView(
          children: [
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('剧集线路'),
              subtitle: Text('仅切换到对应集，保留当前进度和暂停状态'),
            ),
            for (final line in lines)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(line.name),
                subtitle: line.current
                    ? const Text('当前线路')
                    : !line.available
                    ? const Text('没有对应集，请在详情页手动选择')
                    : null,
                enabled: !_busy && line.available,
                trailing: line.current ? const Icon(Icons.check) : null,
                onTap: () => line.current
                    ? Navigator.of(context).pop()
                    : _select(-1, line: line.name),
              ),
            if (lines.isEmpty && widget.onSwitchLine != null)
              ListTile(title: const Text('换线路继续看'), onTap: widget.onSwitchLine)
            else if (lines.isEmpty)
              const ListTile(title: Text('当前视频没有其他剧集线路')),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Material(
    color: VideoGlassScope.active(context)
        ? Colors.transparent
        : Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(24),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '选集与线路',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 22),
              ),
            ],
          ),
          Row(
            children: [
              for (final entry in [
                (PlayerSourceTab.episodes, '选集'),
                (PlayerSourceTab.lines, '线路'),
                (PlayerSourceTab.quality, '画质'),
              ])
                Expanded(
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _tab = entry.$1;
                            _error = null;
                          }),
                    style: TextButton.styleFrom(
                      foregroundColor: _tab == entry.$1
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      backgroundColor: _tab == entry.$1
                          ? Theme.of(context).colorScheme.primary
                                .withValues(alpha: .1)
                          : null,
                      minimumSize: const Size(44, 44),
                    ),
                    child: Text(entry.$2),
                  ),
                ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          Expanded(
            child: switch (_tab) {
              PlayerSourceTab.episodes => _buildEpisodes(),
              PlayerSourceTab.quality => _variants(),
              PlayerSourceTab.lines => _buildLines(),
            },
          ),
          const Divider(height: 1),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('播放信息', style: TextStyle(fontSize: 12)),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('播放地址'),
                subtitle: Text(
                  widget.address.isEmpty ? '尚未获取地址' : widget.address,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: '复制地址',
                  onPressed: widget.address.isEmpty ? null : _copy,
                  icon: const Icon(Icons.copy, size: 20),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
