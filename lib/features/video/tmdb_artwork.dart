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
  Timer? _timer;
  Future<void> refresh() async {
    final sequence = ++_sequence;
    _timer?.cancel();
    metadata = null;
    index = 0;
    if (!_closed) notifyListeners();
    if (!settings.configured) return;
    final result = await client.lookup(title);
    if (_closed || sequence != _sequence || !settings.configured) return;
    metadata = result;
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
