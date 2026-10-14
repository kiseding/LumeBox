import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 选集与线路面板：先列剧集并标记当前集，再提供线路与播放地址。
/// 切集交给宿主统一处理，失败时留在面板重试；手动地址没有剧集时如实提示。
class PlayerSourceSheet extends StatefulWidget {
  const PlayerSourceSheet({
    super.key,
    required this.address,
    this.qualities = const <VideoQuality>[],
    this.currentIndex = 0,
    this.onSelectQuality,
    required this.onPlayAddress,
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

  /// 播放手动输入的地址；返回 null 表示已交出去，否则返回给用户看的错误文案
  /// （由本弹窗就地展示，不弹 SnackBar——用户的手还在输入框上）。
  final Future<String?> Function(String text) onPlayAddress;

  final Future<List<SourceChapter>> Function()? loadEpisodes;
  final String? currentChapterId;
  final Future<bool> Function(int index)? onSelectEpisode;

  @override
  State<PlayerSourceSheet> createState() => _PlayerSourceSheetState();
}

class _PlayerSourceSheetState extends State<PlayerSourceSheet> {
  late final TextEditingController _input = TextEditingController();
  String? _error;
  bool _busy = false;

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

  Widget _buildEpisodes() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _label('选集'),
      const SizedBox(height: 8),
      if (_episodes == null)
        const Text('当前视频没有剧集列表')
      else
        FutureBuilder<List<SourceChapter>>(
          future: _episodes,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return TextButton.icon(
                onPressed: () =>
                    setState(() => _episodes = widget.loadEpisodes!()),
                icon: const Icon(Icons.refresh),
                label: const Text('剧集加载失败，点击重试'),
              );
            }
            final chapters = snapshot.data ?? [];
            if (chapters.isEmpty) return const Text('图源暂未提供剧集');
            return SizedBox(
              height: 192,
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 140,
                  mainAxisExtent: 44,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: chapters.length,
                itemBuilder: (context, index) => ChoiceChip(
                  label: Text(
                    chapters[index].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: chapters[index].id == widget.currentChapterId,
                  onSelected: _selectingEpisode
                      ? null
                      : (_) => _selectEpisode(index),
                ),
              ),
            );
          },
        ),
      if (_selectingEpisode) const LinearProgressIndicator(),
      if (_episodeError != null)
        Text(
          _episodeError!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      const SizedBox(height: 16),
    ],
  );

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.onPlayAddress(_input.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    // 交出去了才关面板；出错就留在原地让用户改。
    if (error == null) Navigator.of(context).pop();
  }

  Future<void> _copy() async {
    final text = widget.address.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(duration: Duration(seconds: 1), content: Text('已复制播放地址')),
    );
  }

  /// 线路那一行的副标题：地址太长，只留「域名/最后一段」这类一眼能分辨的部分。
  static String _shortUrl(Uri uri) {
    final text = uri.toString();
    if (text.length <= 64) return text;
    return '…${text.substring(text.length - 63)}';
  }

  @override
  Widget build(BuildContext context) {
    final address = widget.address.trim();
    final lines = widget.qualities;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          top: false,
          child: Padding(
            // 键盘顶上来时把面板一起顶上去（贴地址离不开键盘）。
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.85,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '选集与线路',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: LumeTheme.textPrimary,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: <Widget>[
                        _buildEpisodes(),
                        Align(
                          alignment: Alignment.centerRight,
                          child: IconButton(
                            tooltip: '复制地址',
                            iconSize: 22,
                            icon: const Icon(Icons.copy_outlined),
                            onPressed: address.isEmpty ? null : _copy,
                          ),
                        ),
                        if (lines.length > 1) ...<Widget>[
                          const SizedBox(height: 12),
                          GlassCard(
                            radius: 14,
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                _label('线路（切换后从当前位置继续）'),
                                const SizedBox(height: 4),
                                for (var i = 0; i < lines.length; i++)
                                  ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(
                                      i == widget.currentIndex
                                          ? Icons.check_circle
                                          : Icons.circle_outlined,
                                      size: 20,
                                      color: i == widget.currentIndex
                                          ? LumeTheme.accent
                                          : LumeTheme.muted,
                                    ),
                                    title: Text(
                                      lines[i].label,
                                      style: TextStyle(
                                        color: LumeTheme.textPrimary,
                                      ),
                                    ),
                                    subtitle: Text(
                                      _shortUrl(lines[i].url),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: LumeTheme.muted,
                                      ),
                                    ),
                                    onTap: widget.onSelectQuality == null
                                        ? null
                                        : () {
                                            Navigator.of(context).pop();
                                            widget.onSelectQuality!(i);
                                          },
                                  ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        GlassCard(
                          radius: 14,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              _label('手动地址'),
                              const SizedBox(height: 4),
                              TextField(
                                controller: _input,
                                autofocus: false,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: LumeTheme.textPrimary,
                                ),
                                decoration: InputDecoration(
                                  border: InputBorder.none,
                                  isDense: true,
                                  hintText: '视频地址或本地路径',
                                  hintStyle: TextStyle(color: LumeTheme.muted),
                                ),
                                onSubmitted: (_) => _play(),
                              ),
                              if (_error != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    _error!,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: LumeTheme.danger,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: _busy ? null : _play,
                                  icon: const Icon(Icons.play_arrow, size: 18),
                                  label: const Text('播放这个地址'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
    text,
    style: TextStyle(fontSize: 12, color: LumeTheme.textSecondary),
  );
}
