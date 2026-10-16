import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/tmdb/tmdb.dart';

class TmdbDetailController extends ChangeNotifier {
  TmdbDetailController(this.title, {TmdbSettings? settings, TmdbClient? client})
    : settings = settings ?? TmdbSettings.instance {
    this.client = client ?? TmdbClient(this.settings);
    this.settings.addListener(refresh);
    unawaited(refresh());
  }
  final String title;
  final TmdbSettings settings;
  late final TmdbClient client;
  TmdbMetadata? metadata;
  int index = 0, _sequence = 0;
  bool _closed = false;
  bool loading = false;
  String? status;
  Future<void> rematch() => refresh(force: true);
  Timer? _timer;
  Future<void> refresh({bool force = false}) async {
    final sequence = ++_sequence;
    _timer?.cancel();
    metadata = null;
    loading = settings.configured;
    status = null;
    index = 0;
    if (!_closed) notifyListeners();
    if (!settings.configured) return;
    final result = await client.lookup(title, force: force);
    if (_closed || sequence != _sequence || !settings.configured) return;
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
  });
  final TmdbDetailController controller;
  final Widget fallback;
  final BoxFit fit;
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

  Widget poster(String url) => Image.network(
    url,
    fit: widget.fit,
    errorBuilder: (_, _, _) => widget.fallback,
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final state = widget.controller;
      final urls = state.metadata?.posters ?? const <String>[];
      if (!state.settings.enabled || urls.isEmpty) return widget.fallback;
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
