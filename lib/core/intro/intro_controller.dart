import 'dart:async';

import 'package:flutter/foundation.dart';

import '../player/abstract_player.dart';
import 'intro_backend.dart';
import 'intro_models.dart';
import 'intro_service.dart';
import 'intro_store.dart';

/// Playback never waits for detection. Heavy tasks stop on resume/background,
/// and restart when the same media is idle in the foreground.
class IntroController extends ChangeNotifier {
  IntroController(this.store, {IntroScanBackend Function()? backend})
    : _backend = backend ?? NativeIntroBackend.new {
    store.addListener(_settingsChanged);
  }
  final IntroStore store;
  final IntroScanBackend Function() _backend;
  IntroRequest? request;
  List<SkipSegment> segments = [];
  SkipSegment? prompt;
  int secondsLeft = 0;
  String status = '等待媒体';
  bool scanning = false, _disposed = false, _foreground = true;
  bool _heavy = false, _completedHeavy = false, _seekPending = false;
  int _generation = 0;
  IntroCancellation? _token;
  IntroRecognitionService? _service;
  Timer? _timer;
  Timer? _idleRetry;
  PlayerSnapshot _snapshot = const PlayerSnapshot();
  final Set<String> _dismissed = {};
  Future<void> Function(Duration)? seek;
  void bind(IntroRequest next, Future<void> Function(Duration) onSeek) {
    cancel();
    request = next;
    seek = onSeek;
    _dismissed.clear();
    prompt = null;
    _completedHeavy = false;
    segments = [];
    unawaited(_run(false));
  }

  void _settingsChanged() {
    final current = request;
    if (current == null) return;
    cancel();
    segments = [];
    _completedHeavy = false;
    if (store.value.active) unawaited(_run(false));
    _notify();
  }

  Future<void> _run(bool heavy) async {
    final current = request;
    if (_disposed || current == null || !store.value.active || scanning) return;
    final generation = ++_generation;
    final token = _token = IntroCancellation();
    final service = _service = IntroRecognitionService(
      store: store,
      backend: _backend(),
    );
    scanning = true;
    _heavy = heavy;
    _notify();
    try {
      final found = await service.recognize(
        current,
        token,
        allowHeavy: heavy,
        onStatus: (value) {
          if (generation != _generation || _disposed) return;
          status = value;
          _notify();
        },
      );
      if (generation != _generation || _disposed) return;
      if (found.isNotEmpty) segments = found;
      if (heavy) _completedHeavy = !service.deferred;
      status = segments.isEmpty
          ? (service.deferred
                ? '等待网络、供电或温控条件后继续预扫描'
                : heavy
                ? '本次未识别到可靠片段，可手动打点'
                : '轻量查询完成，等待空闲预扫描')
          : '已识别 ${segments.length} 个片段';
    } on IntroCancelled {
      /* stale/background work cannot publish results */
    } catch (error) {
      if (generation == _generation) status = '识别暂不可用';
    } finally {
      await service.close();
      if (!_disposed && generation == _generation) {
        scanning = false;
        _service = null;
        _notify();
        if (heavy && service.deferred) {
          _idleRetry?.cancel();
          _idleRetry = Timer(const Duration(seconds: 60), () {
            if (!_disposed && _foreground && !_snapshot.playing) {
              unawaited(_run(true));
            }
          });
        }
        if (!heavy &&
            !_snapshot.playing &&
            _foreground &&
            !_completedHeavy &&
            store.value.active) {
          scheduleMicrotask(() => _run(true));
        }
      }
    }
  }

  void update(PlayerSnapshot snapshot, {required bool foreground}) {
    _snapshot = snapshot;
    _foreground = foreground;
    if (_disposed) return;
    if ((!foreground || (snapshot.playing && store.value.idleOnly)) &&
        scanning &&
        _heavy) {
      cancel();
      status = '预扫描暂停，等待前台空闲';
      _notify();
    }
    if (foreground &&
        (!snapshot.playing || !store.value.idleOnly) &&
        !snapshot.buffering &&
        !scanning &&
        !_completedHeavy &&
        !(_idleRetry?.isActive ?? false) &&
        store.value.active) {
      unawaited(_run(true));
    }
    final position = snapshot.position.inMilliseconds;
    if (prompt != null &&
        (position < prompt!.startMs || position >= prompt!.endMs)) {
      _clearPrompt();
    }
    if (!foreground ||
        !snapshot.playing ||
        snapshot.buffering ||
        snapshot.error != null ||
        prompt != null ||
        !store.value.active) {
      return;
    }
    final candidate = segments
        .where(
          (s) =>
              position >= s.startMs &&
              position < s.endMs - 1000 &&
              !_dismissed.contains(s.id) &&
              (s.kind == SegmentKind.opening ||
                  s.kind == SegmentKind.ending ||
                  store.value.enabled('skip${s.kind.name}')),
        )
        .firstOrNull;
    if (candidate == null) return;
    prompt = candidate;
    secondsLeft = store.value.countdown;
    _notify();
    if (!store.value.autoSkip) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_foreground ||
          !_snapshot.playing ||
          _snapshot.buffering ||
          _snapshot.error != null) {
        return;
      }
      if (--secondsLeft <= 0) {
        unawaited(skipNow());
      } else {
        _notify();
      }
    });
  }

  void dismiss() {
    final candidate = prompt;
    if (candidate != null) {
      _dismissed.add(candidate.id);
      final current = request;
      if (current != null) {
        store.record(
          RecognitionRecord(
            current.episode.key,
            RecognitionStage.manual,
            'user-cancelled-skip',
            0,
            [candidate],
          ),
        );
      }
    }
    _clearPrompt();
    _notify();
  }

  Future<void> skipNow() async {
    final candidate = prompt;
    if (_seekPending || candidate == null || seek == null) return;
    final position = _snapshot.position.inMilliseconds;
    if (position < candidate.startMs ||
        position >= candidate.endMs ||
        !store.value.active) {
      _clearPrompt();
      _notify();
      return;
    }
    _seekPending = true;
    _dismissed.add(candidate.id);
    _clearPrompt();
    _notify();
    try {
      await seek!(Duration(milliseconds: candidate.endMs));
      final current = request;
      if (current != null) {
        store.record(
          RecognitionRecord(
            current.episode.key,
            RecognitionStage.manual,
            'skip-executed',
            0,
            [candidate],
          ),
        );
      }
    } catch (_) {
      status = '跳转失败，请使用手动跳过';
    } finally {
      _seekPending = false;
      _notify();
    }
  }

  void saveManual(List<SkipSegment> marks) {
    final current = request;
    if (current == null) throw StateError('No media');
    store.saveSegments(
      current.episode,
      current.durationMs,
      marks,
      manual: true,
    );
    cancel();
    segments = marks;
    _completedHeavy = false;
    _clearPrompt();
    // Marking at the current location must not unexpectedly seek immediately.
    _dismissed.addAll(marks.map((s) => s.id));
    status = '已保存手动片头片尾';
    _notify();
  }

  void retryIdle() {
    _completedHeavy = false;
    if (!_snapshot.playing && _foreground) unawaited(_run(true));
  }

  void _clearPrompt() {
    _timer?.cancel();
    _timer = null;
    prompt = null;
  }

  void cancel() {
    _generation++;
    _token?.cancelled = true;
    _idleRetry?.cancel();
    _idleRetry = null;
    unawaited(_service?.backend.cancel());
    _service = null;
    scanning = false;
    _clearPrompt();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    store.removeListener(_settingsChanged);
    _disposed = true;
    cancel();
    super.dispose();
  }
}
