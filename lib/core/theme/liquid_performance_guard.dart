import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

enum LiquidQuality { normal, reduced, legacy }

/// Measures real build/raster timings; never changes the user's stored preferences.
class LiquidPerformanceGuard extends ChangeNotifier {
  static final instance = LiquidPerformanceGuard();
  int active = 0;
  LiquidQuality quality = LiquidQuality.normal;
  final List<double> _costs = [];
  int _good = 0;
  DateTime _changed = DateTime.fromMillisecondsSinceEpoch(0);
  bool _queued = false;
  bool _disposed = false;
  int get animationFps => quality == LiquidQuality.normal ? 30 : 15;
  String get status => switch (quality) {
    LiquidQuality.normal => '正常：动画上限 30 帧',
    LiquidQuality.reduced => '保护中：动画 15 帧并降低效果开销',
    LiquidQuality.legacy => '保护中：暂用普通 UI，设置仍保留',
  };
  void attach() {
    active++;
    if (active == 1) SchedulerBinding.instance.addTimingsCallback(_timings);
    if (active >= 16 && quality == LiquidQuality.normal) {
      _set(LiquidQuality.reduced);
    }
    _notify();
  }

  void detach() {
    active = (active - 1).clamp(0, 100000);
    if (active == 0) {
      SchedulerBinding.instance.removeTimingsCallback(_timings);
      quality = LiquidQuality.normal;
      _costs.clear();
      _good = 0;
    }
    _notify();
  }

  void _timings(List<FrameTiming> frames) {
    for (final frame in frames) {
      sample(
        buildMs: frame.buildDuration.inMicroseconds / 1000,
        rasterMs: frame.rasterDuration.inMicroseconds / 1000,
      );
    }
  }

  @visibleForTesting
  void sample({
    required double buildMs,
    required double rasterMs,
    DateTime? now,
  }) {
    if (active == 0) return;
    final time = now ?? DateTime.now();
    final cost = buildMs > rasterMs ? buildMs : rasterMs;
    _costs.add(cost);
    if (_costs.length > 20) _costs.removeAt(0);
    if (_costs.length >= 10 && _costs.where((v) => v > 40).length >= 8) {
      _set(LiquidQuality.legacy, now: time);
      _good = 0;
      return;
    }
    if (quality != LiquidQuality.legacy &&
        _costs.length >= 10 &&
        _costs.where((v) => v > 22).length >= 6) {
      _set(LiquidQuality.reduced, now: time);
      _good = 0;
      return;
    }
    _good = cost < 18 ? _good + 1 : 0;
    if (_good >= 120 &&
        time.difference(_changed) > const Duration(seconds: 30)) {
      if (quality == LiquidQuality.legacy) {
        _set(LiquidQuality.reduced, now: time);
      } else if (active < 16) {
        _set(LiquidQuality.normal, now: time);
      }
      _costs.clear();
      _good = 0;
    }
  }

  void _set(LiquidQuality next, {DateTime? now}) {
    if (quality == next) return;
    quality = next;
    _changed = now ?? DateTime.now();
    _notify();
  }

  void _notify() {
    if (_queued) return;
    _queued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    if (active > 0) SchedulerBinding.instance.removeTimingsCallback(_timings);
    super.dispose();
  }
}
