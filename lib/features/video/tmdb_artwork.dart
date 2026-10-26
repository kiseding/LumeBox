import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/tmdb/tmdb.dart';

class TmdbDetailController extends ChangeNotifier {
  TmdbDetailController(
    this.title, {
    TmdbSettings? settings,
    TmdbClient? client,
    bool autoLoad = true,
  }) : settings = settings ?? TmdbSettings.instance {
    this.client = client ?? TmdbClient(this.settings);
    this.settings.addListener(refresh);
    if (autoLoad) unawaited(refresh());
  }
  String title;

  /// 列表标题与详情标题可能不一致（猫源尤其常见）；按顺序回退查询。
  List<String> _alternateTitles = const <String>[];

  final TmdbSettings settings;
  late final TmdbClient client;
  TmdbMetadata? metadata;
  int index = 0, _sequence = 0;
  bool _closed = false;
  bool loading = false;
  bool _started = false;
  String? _year, _mediaType;
  String? status;
  Future<void> rematch() => refresh(force: true);

  /// 用详情页拿到的标题再次匹配：列表标题可能带站点前缀/别名，而详情标题
  /// 才是视频模块里能命中的那个干净标题。多个候选按顺序回退，全部失败才
  /// 显示「未匹配」。
  void updateTitles(
    Iterable<String> values, {
    String? year,
    String? mediaType,
  }) {
    final unique = <String>[];
    for (final value in values) {
      final text = value.trim();
      if (text.isEmpty ||
          unique.any(
            (v) =>
                TmdbClient.normalized(TmdbClient.cleanTitle(v)) ==
                TmdbClient.normalized(TmdbClient.cleanTitle(text)),
          )) {
        continue;
      }
      unique.add(text);
    }
    if (_closed || unique.isEmpty) return;
    final samePrimary =
        TmdbClient.normalized(TmdbClient.cleanTitle(unique.first)) ==
        TmdbClient.normalized(TmdbClient.cleanTitle(title));
    final sameAlternates =
        unique.length - 1 == _alternateTitles.length &&
        <int>[
              for (var i = 1; i < unique.length; i++)
                if (unique[i] == _alternateTitles[i - 1]) i,
            ].length ==
            _alternateTitles.length;
    if (_started &&
        samePrimary &&
        sameAlternates &&
        _year == year &&
        _mediaType == mediaType) {
      return;
    }
    _year = year;
    _mediaType = mediaType;
    title = unique.first;
    _alternateTitles = unique.skip(1).toList(growable: false);
    unawaited(refresh());
  }

  Timer? _timer;
  Future<void> refresh({bool force = false}) async {
    _started = true;
    final sequence = ++_sequence;
    _timer?.cancel();
    metadata = null;
    loading = settings.configured;
    status = null;
    index = 0;
    if (!_closed) notifyListeners();
    if (!settings.configured) return;
    TmdbMetadata? result;
    for (final candidate in <String>[title, ..._alternateTitles]) {
      result = await client.lookup(
        candidate,
        force: force,
        year: _year,
        mediaType: _mediaType,
      );
      if (_closed || sequence != _sequence || !settings.configured) return;
      if (result != null) break;
    }
    metadata = result;
    loading = false;
    status = result == null ? (client.lastError ?? '未匹配到 TMDB 资料，保留源信息') : null;
    final count = result?.posters.length ?? 0;
    if (count > 0 && settings.posterStyle == TmdbPosterStyle.random) {
      index = Random().nextInt(count);
    }
    if (count > 1 && settings.posterStyle == TmdbPosterStyle.carousel) {
      _timer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => show((index + 1) % count),
      );
    }
    notifyListeners();
  }

  void show(int value) {
    if (_closed || index == value) return;
    index = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _sequence++;
    _timer?.cancel();
    settings.removeListener(refresh);
    client.dispose();
    super.dispose();
  }
}

class TmdbPosterGallery extends StatefulWidget {
  const TmdbPosterGallery({
    super.key,
    required this.controller,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.onArtworkDisplayed,
  });
  final TmdbDetailController controller;
  final Widget fallback;
  final BoxFit fit;
  final ValueChanged<String?>? onArtworkDisplayed;
  @override
  State<TmdbPosterGallery> createState() => _TmdbPosterGalleryState();
}

class _TmdbPosterGalleryState extends State<TmdbPosterGallery> {
  final pages = PageController();
  @override
  void dispose() {
    pages.dispose();
    super.dispose();
  }

  String? _reportedArtwork;
  bool _hasReported = false;
  void reportArtwork(String? url) {
    if (_hasReported && _reportedArtwork == url) return;
    _hasReported = true;
    _reportedArtwork = url;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _reportedArtwork == url) {
        widget.onArtworkDisplayed?.call(url);
      }
    });
  }

  bool isCurrent(String url) {
    final urls = widget.controller.metadata?.posters ?? const <String>[];
    return urls.isNotEmpty &&
        urls[widget.controller.index.clamp(0, urls.length - 1)] == url;
  }

  Widget poster(String url) => Image.network(
    url,
    fit: widget.fit,
    filterQuality: FilterQuality.high,
    frameBuilder: (_, child, frame, synchronouslyLoaded) {
      if ((frame != null || synchronouslyLoaded) && isCurrent(url)) {
        reportArtwork(url);
      }
      return child;
    },
    errorBuilder: (_, _, _) {
      if (isCurrent(url)) reportArtwork(null);
      return widget.fallback;
    },
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final state = widget.controller;
      final urls = state.metadata?.posters ?? const <String>[];
      if (!state.settings.enabled || urls.isEmpty) {
        reportArtwork(null);
        return widget.fallback;
      }
      if (state.settings.posterStyle != TmdbPosterStyle.carousel ||
          urls.length < 2) {
        return poster(urls[state.index.clamp(0, urls.length - 1)]);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            pages.hasClients &&
            (pages.page ?? 0).round() != state.index) {
          pages.animateToPage(
            state.index,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
          );
        }
      });
      return PageView.builder(
        key: const Key('tmdb-poster-carousel'),
        controller: pages,
        itemCount: urls.length,
        onPageChanged: state.show,
        itemBuilder: (_, index) => poster(urls[index]),
      );
    },
  );
}

class TmdbInformation extends StatelessWidget {
  const TmdbInformation({super.key, required this.controller});
  final TmdbDetailController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.settings.configured) return const SizedBox.shrink();
      final data = controller.metadata;
      Widget inset(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: child,
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            inset(
              Text('TMDB 影片资料', style: Theme.of(context).textTheme.titleMedium),
            ),
            if (controller.loading)
              inset(
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(),
                ),
              ),
            if (controller.status != null) inset(Text(controller.status!)),
            if (data != null) ...[
              inset(
                Text(
                  data.voteCount > 0
                      ? 'TMDB 评分 ${data.rating.toStringAsFixed(1)} / 10 · ${data.voteCount} 人评价'
                      : 'TMDB 暂无评分',
                ),
              ),
              if (data.cast.isNotEmpty) ...[
                const SizedBox(height: 8),
                inset(const Text('演员')),
                inset(
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: data.cast
                        .map((name) => Chip(label: Text(name)))
                        .toList(),
                  ),
                ),
              ],
              if (data.backdrops.isNotEmpty) ...[
                const SizedBox(height: 12),
                SizedBox(
                  key: const Key('tmdb-backdrop'),
                  height: 220,
                  width: double.infinity,
                  child: PageView(
                    children: [
                      for (final url in data.backdrops)
                        Image.network(
                          url,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const Center(child: Text('背景图暂时无法加载')),
                        ),
                    ],
                  ),
                ),
              ],
              if (data.overview.isNotEmpty) ...[
                const SizedBox(height: 12),
                inset(const Text('TMDB 官方剧情简介')),
                inset(Text(data.overview)),
              ],
            ],
          ],
        ),
      );
    },
  );
}

class TmdbRematchMenu extends StatelessWidget {
  const TmdbRematchMenu({super.key, required this.controller});
  final TmdbDetailController controller;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: '更多',
    onSelected: (_) => controller.rematch(),
    itemBuilder: (_) => [
      PopupMenuItem(
        value: 'tmdb',
        enabled: controller.settings.configured && !controller.loading,
        child: const Text('重新匹配TMDB'),
      ),
    ],
  );
}

/// TMDB title artwork is separate from the poster; missing/failed logos keep the
/// real text title. Do not recolour the supplied PNG (green lettering stays green).
class TmdbTitleArtwork extends StatelessWidget {
  const TmdbTitleArtwork({
    super.key,
    required this.controller,
    required this.fallback,
  });
  final TmdbDetailController controller;
  final Widget fallback;
  @override
  Widget build(BuildContext context) {
    final logo = controller.settings.enabled
        ? controller.metadata?.logos
              .where(
                (url) => !Uri.parse(url).path.toLowerCase().endsWith('.svg'),
              )
              .firstOrNull
        : null;
    if (logo == null) return fallback;
    return Center(
      child: SizedBox(
        key: const Key('tmdb-title-artwork'),
        width: MediaQuery.sizeOf(context).width * .62,
        height: 76,
        child: Image.network(
          logo,
          fit: BoxFit.contain,
          cacheWidth: 900,
          filterQuality: FilterQuality.high,
          frameBuilder: (_, child, frame, sync) =>
              frame != null || sync ? child : Center(child: fallback),
          errorBuilder: (_, _, _) => Center(child: fallback),
        ),
      ),
    );
  }
}
