import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';

/// 选集与线路面板：先列剧集并标记当前集，再列出线路与当前地址（可复制）。
/// 切集交给宿主统一处理，失败时留在面板重试。
///
/// **手动贴地址的入口已按用户口径删除**（面板里不再有地址输入框与「播放这个
/// 地址」按钮）：播放页只播图源给的地址，这个面板只剩「选集 / 换线路 / 复制」。
class PlayerSourceSheet extends StatefulWidget {
  const PlayerSourceSheet({
    super.key,
    required this.address,
    this.qualities = const <VideoQuality>[],
    this.currentIndex = 0,
    this.onSelectQuality,
    this.loadEpisodes,
    this.currentChapterId,
    this.onSelectEpisode,
  });

  /// 当前播放地址（为空表示还没装载任何媒体）。
  final String address;

  /// 候选线路（图源给多条时才有）；单条 / 空时不出「线路」一栏。
  final List<VideoQuality> qualities;

  /// 当前线路下标。
  final int currentIndex;

  /// 切线路（宿主页负责重新装载并提示）。
  final ValueChanged<int>? onSelectQuality;

  final Future<List<SourceChapter>> Function()? loadEpisodes;
  final String? currentChapterId;
  final Future<bool> Function(int index)? onSelectEpisode;

  @override
  State<PlayerSourceSheet> createState() => _PlayerSourceSheetState();
}

class _PlayerSourceSheetState extends State<PlayerSourceSheet> {
  late Future<List<SourceChapter>>? _episodes = widget.loadEpisodes?.call();
  bool _selectingEpisode = false;
  String? _episodeError;

  Future<void> _selectEpisode(int index) async {
    if (_selectingEpisode || widget.onSelectEpisode == null) return;
    setState(() {
      _selectingEpisode = true;
      _episodeError = null;
    });
    try {
      final ok = await widget.onSelectEpisode!(index);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _episodeError = '切集失败，请重试');
    } catch (_) {
      if (mounted) setState(() => _episodeError = '切集失败，请重试');
    } finally {
      if (mounted) setState(() => _selectingEpisode = false);
    }
  }

  final _scroll = ScrollController();
  bool _reverse = false;
  int _columns = 4;
  List<SourceChapter> _chapters = [];

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _locateCurrent() {
    if (!_scroll.hasClients) return;
    var index = _chapters.indexWhere(
      (chapter) => chapter.id == widget.currentChapterId,
    );
    if (index < 0) return;
    if (_reverse) index = _chapters.length - 1 - index;
    _scroll.animateTo(
      (index ~/ _columns * 52.0).clamp(0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Widget _buildEpisodes() => FutureBuilder<List<SourceChapter>>(
    future: _episodes,
    builder: (context, snapshot) {
      if (_episodes == null) return const Center(child: Text('当前视频没有剧集列表'));
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) {
        return Center(
          child: TextButton.icon(
            onPressed: () => setState(() => _episodes = widget.loadEpisodes!()),
            icon: const Icon(Icons.refresh),
            label: const Text('剧集加载失败，点击重试'),
          ),
        );
      }
      final chapters = snapshot.data ?? [];
      _chapters = chapters;
      if (chapters.isEmpty) return const Center(child: Text('图源暂未提供剧集'));
      return Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '共 ${chapters.length} 集',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(onPressed: _locateCurrent, child: const Text('定位当前')),
              TextButton.icon(
                onPressed: () => setState(() => _reverse = !_reverse),
                icon: const Icon(Icons.swap_vert, size: 18),
                label: Text(_reverse ? '倒序' : '正序'),
              ),
            ],
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _columns = (constraints.maxWidth / 90).floor().clamp(2, 6);
                return GridView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.only(bottom: 12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _columns,
                    mainAxisExtent: 44,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: chapters.length,
                  itemBuilder: (context, visibleIndex) {
                    final index = _reverse
                        ? chapters.length - 1 - visibleIndex
                        : visibleIndex;
                    final chapter = chapters[index];
                    final current = chapter.id == widget.currentChapterId;
                    return Tooltip(
                      message: chapter.title,
                      child: ChoiceChip(
                        label: SizedBox(
                          width: double.infinity,
                          child: Text(
                            chapter.title,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        selected: current,
                        labelStyle: Theme.of(context).textTheme.labelLarge
                            ?.copyWith(
                              color: current
                                  ? LumeTheme.onAccent
                                  : LumeTheme.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                        showCheckmark: false,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        onSelected: _selectingEpisode
                            ? null
                            : (_) => _selectEpisode(index),
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

  Future<void> _copy() async {
    final text = widget.address.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(duration: Duration(seconds: 1), content: Text('已复制播放地址')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final landscape = media.size.width > media.size.height;
    return Align(
      alignment: landscape ? Alignment.centerRight : Alignment.bottomCenter,
      child: SizedBox(
        width: landscape ? 440 : double.infinity,
        height: media.size.height * (landscape ? .94 : .76),
        child: Material(
          color: LumeTheme.base,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '选集与线路',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '复制地址',
                        onPressed: widget.address.trim().isEmpty ? null : _copy,
                        icon: const Icon(Icons.link, size: 22),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  if (widget.qualities.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 42,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemCount: widget.qualities.length,
                        itemBuilder: (context, index) => ChoiceChip(
                          label: Text(widget.qualities[index].label),
                          selected: index == widget.currentIndex,
                          labelStyle: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: index == widget.currentIndex
                                    ? LumeTheme.onAccent
                                    : LumeTheme.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                          onSelected: widget.onSelectQuality == null
                              ? null
                              : (_) {
                                  Navigator.pop(context);
                                  widget.onSelectQuality!(index);
                                },
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        '切换线路后从当前位置继续',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                  const Divider(height: 12),
                  if (_selectingEpisode) const LinearProgressIndicator(),
                  if (_episodeError != null)
                    Text(
                      _episodeError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  Expanded(child: _buildEpisodes()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
