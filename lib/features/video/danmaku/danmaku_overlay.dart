import 'package:flutter/scheduler.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'danmaku_models.dart';
import 'danmaku_settings.dart';

/// 弹幕叠加层：盖在播放器画面上，按播放时间滚动 / 固定显示弹幕。
///
/// 设计要点：
/// - **吃播放位置而不是自走时钟**：每帧从 [position] 取当前时间，因此拖动进度条、
///   切集、暂停都能立刻对齐（自走时钟会在 seek 后错位）；
/// - **分层轨道**：滚动弹幕按「已占用轨道」分配，避免同屏重叠；顶部 / 底部固定
///   弹幕各占独立轨道，按停留时长换位；
/// - **同屏上限**：超过 [DanmakuSettings.maxOnScreen] 就不再显示新弹幕——弹幕
///   刷屏时优先保证播放流畅；
/// - **暂停时静止**：暂停不推进动画，弹幕停在原处（与主流播放器一致）。
///
/// 这是一个纯渲染组件：不联网、不读库、不认识图源。数据由外层（播放页）喂进来。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.position,
    required this.playing,
    required this.track,
    required this.settings,
    this.playbackRate = 1.0,
    this.tickInterval = const Duration(milliseconds: 16),
  });

  /// 当前播放位置（每帧变化）。
  final Duration position;

  /// 是否正在播放（暂停时弹幕静止）。
  final bool playing;
  final double playbackRate;

  /// 本集弹幕。
  final DanmakuTrack track;

  final DanmakuSettings settings;

  /// 重绘节拍（测试可调大以减少 pump 次数）。
  final Duration tickInterval;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  /// 屏幕上的弹幕实例（含各自的出现时刻与轨道）。
  final List<_ActiveDanmaku> _active = <_ActiveDanmaku>[];

  /// 已投放到屏幕上的弹幕在 track 里的下标（单调推进，避免重复投放）。
  int _cursor = 0;
  Size _viewport = const Size(320, 180);
  int _rateSecond = -1, _rateCount = 0;
  final Map<String, Duration> _recentText = {};

  /// 上一次的位置：用于检测「跳转」（seek / 切集）并重置状态。
  Duration _lastPosition = Duration.zero;

  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;
  Duration _anchor = Duration.zero;
  Duration _lastFrame = Duration.zero;
  Duration _renderPosition = Duration.zero;
  Duration _clockPosition = Duration.zero;
  Duration _clockFrame = Duration.zero;
  bool get _animate =>
      widget.playing && widget.settings.enabled && !widget.track.isEmpty;
  void _frame(Duration elapsed) {
    _elapsed = elapsed;
    if (widget.tickInterval > const Duration(milliseconds: 16) &&
        elapsed - _lastFrame < widget.tickInterval) {
      return;
    }
    _lastFrame = elapsed;
    _onTick();
  }

  void _syncTicker() {
    if (_animate && !_ticker.isActive) {
      _elapsed = _anchor = _lastFrame = Duration.zero;
      _ticker.start();
    } else if (!_animate && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_frame);
    _renderPosition = _clockPosition = widget.position;
    _syncTicker();
    _onTick();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换集 / 换弹幕源：整层重置。
    if (!identical(oldWidget.track, widget.track)) _reset();
    if (oldWidget.position != widget.position ||
        oldWidget.playing != widget.playing ||
        oldWidget.playbackRate != widget.playbackRate) {
      _anchor = _elapsed;
    }
    if (oldWidget.settings != widget.settings) {
      final previous = List<_ActiveDanmaku>.of(_active);
      _active.clear();
      for (final entry in previous) {
        if (widget.settings.accepts(entry.item)) {
          final lane = _allocateLane(
            entry.item,
            _renderPosition,
            bornAt: entry.bornAt,
          );
          if (lane != null) {
            _active.add(
              _ActiveDanmaku(
                item: entry.item,
                lane: lane,
                bornAt: entry.bornAt,
              ),
            );
          }
        }
        entry.dispose();
      }
    }
    _syncTicker();
    _onTick();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _reset();
    super.dispose();
  }

  /// 每帧推进：投放新弹幕 + 清理过期弹幕。
  void _onTick() {
    if (!mounted) return;
    // Interpolate between engine reports, but never run far ahead during a stall.
    final advance = _animate
        ? (_elapsed - _anchor).inMicroseconds.clamp(0, 1000000)
        : 0;
    final target =
        widget.position +
        Duration(microseconds: (advance * widget.playbackRate).round());
    final frameDelta = (_elapsed - _clockFrame).inMicroseconds.clamp(0, 500000);
    _clockFrame = _elapsed;
    if (!_animate || (target - _clockPosition).inMilliseconds.abs() > 2000) {
      _clockPosition = target;
    } else {
      final predicted =
          _clockPosition +
          Duration(microseconds: (frameDelta * widget.playbackRate).round());
      // Correct sampling jitter gently, in proportion to this frame's length.
      // Never snap backwards at the interpolation limit (visible every 500ms).
      final limit = (frameDelta * widget.playbackRate * .1).round();
      final correction = ((target - predicted).inMicroseconds * .12)
          .round()
          .clamp(-limit, limit);
      final next = predicted + Duration(microseconds: correction);
      final ceiling =
          widget.position +
          Duration(microseconds: (1000000 * widget.playbackRate).round());
      _clockPosition = next > ceiling ? ceiling : next;
    }
    final position = _clockPosition;
    _renderPosition =
        position - Duration(milliseconds: widget.settings.delayMs);

    // 跳转检测：位置倒退（seek 回去 / 换集）或大幅前跳 → 重置。
    final delta = widget.position - _lastPosition;
    if (delta.isNegative || delta > const Duration(seconds: 2)) {
      _reset(keepCursorAt: widget.position);
    }
    _lastPosition = widget.position;

    if (!widget.settings.enabled || widget.track.isEmpty) {
      if (_active.isNotEmpty) {
        _reset();
        setState(() {});
      }
      return;
    }

    final previousCount = _active.length;
    _expire(_renderPosition);
    _spawn(_renderPosition);
    if (mounted &&
        (_active.isNotEmpty || previousCount != _active.length || !_animate)) {
      setState(() {});
    }
  }

  /// 重置：清屏、清轨道、把游标对齐到当前时间。
  void _reset({Duration? keepCursorAt}) {
    for (final entry in _active) {
      entry.dispose();
    }
    _active.clear();
    _cursor = 0;
    _rateSecond = -1;
    _rateCount = 0;
    _recentText.clear();
    if (keepCursorAt != null) {
      // 游标指向「当前时间之后的第一条」：重置后只投放新位置的弹幕。
      final items = widget.track.items;
      var low = 0;
      var high = items.length;
      while (low < high) {
        final mid = (low + high) >> 1;
        if (items[mid].time < keepCursorAt) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      _cursor = low;
    }
  }

  /// 投放：把时间窗口内还没上屏的弹幕加进来。
  void _spawn(Duration position) {
    final items = widget.track.items;
    // 只投放「已经到点」的弹幕（不提前显示）。
    while (_cursor < items.length && items[_cursor].time <= position) {
      final item = items[_cursor];
      _cursor++;
      // 太旧的弹幕不补投：seek 之后不该把几分钟前的弹幕一次性糊上来。
      if (position - item.time > const Duration(seconds: 1)) continue;
      final settings = widget.settings;
      if (!settings.accepts(item)) continue;
      final second = item.time.inSeconds;
      if (second != _rateSecond) {
        _rateSecond = second;
        _rateCount = 0;
      }
      if (_rateCount >= settings.maxPerSecond) continue;
      final previous = _recentText[item.text];
      if (settings.mergeDuplicates &&
          previous != null &&
          item.time - previous < const Duration(seconds: 5)) {
        continue;
      }
      if (_active.length >= settings.maxOnScreen) continue;
      final lane = _allocateLane(item, position, bornAt: item.time);
      if (lane == null) continue;
      _active.add(_ActiveDanmaku(item: item, lane: lane, bornAt: item.time));
      _rateCount++;
      _recentText[item.text] = item.time;
      _recentText.removeWhere(
        (text, time) => item.time - time > const Duration(seconds: 5),
      );
    }
  }

  /// 清理已经离开屏幕的弹幕，并释放轨道。
  void _expire(Duration position) {
    _active.removeWhere((entry) {
      if (!entry.isGone(position, widget.settings)) return false;
      entry.dispose();
      return true;
    });
  }

  /// 同排可以连续跟随；同时检查入场间距和离屏前的追尾风险。
  int? _allocateLane(
    DanmakuItem item,
    Duration position, {
    required Duration bornAt,
  }) {
    final settings = widget.settings;
    final text = _DanmakuPainter.textPainter(
      item.text,
      DanmakuStyle.of(item, settings),
    );
    final width = text.width;
    text.dispose();
    final span =
        DanmakuLayout.scrollDuration.inMilliseconds / settings.speedScale;
    final speed = (_viewport.width + width) / span;
    final left = _viewport.width - speed * (position - bornAt).inMilliseconds;
    final gap = 12 * settings.fontScale;
    final laneCount = DanmakuLayout.laneCount(_viewport, widget.settings);
    for (var index = 0; index < laneCount; index++) {
      final lane = item.mode == DanmakuMode.bottom
          ? laneCount - 1 - index
          : index;
      var available = true;
      for (final entry in _active) {
        if (entry.lane != lane || entry.isGone(position, settings)) continue;
        if (item.mode != DanmakuMode.scroll ||
            entry.item.mode != DanmakuMode.scroll) {
          available = false;
          break;
        }
        entry.layout(DanmakuStyle.of(entry.item, settings));
        final oldWidth = entry.fill!.width;
        final oldSpeed = (_viewport.width + oldWidth) / span;
        final right =
            _viewport.width -
            oldSpeed * (position - entry.bornAt).inMilliseconds +
            oldWidth;
        if (left < right + gap ||
            (speed > oldSpeed && left - speed * (right / oldSpeed) < gap)) {
          available = false;
          break;
        }
      }
      if (available) return lane;
    }
    return null; // 轨道满了：这条不显示（不硬挤，挤了就重叠）。
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.settings.enabled) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        if (_active.isEmpty) return const SizedBox.shrink();
        return IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _DanmakuPainter(
                entries: List<_ActiveDanmaku>.of(_active),
                position: _renderPosition,
                settings: widget.settings,
                playing: widget.playing,
                pixelRatio: MediaQuery.devicePixelRatioOf(context),
              ),
              size: Size.infinite,
              isComplex: true,
              willChange: widget.playing,
            ),
          ),
        );
      },
    );
  }
}

/// 弹幕布局常量（渲染层与计时共用的唯一出处）。
class DanmakuLayout {
  DanmakuLayout._();

  /// 滚动弹幕穿越屏幕的基准时长（1x 速度）。
  static const Duration scrollDuration = Duration(seconds: 8);

  /// 固定弹幕（顶 / 底）停留时长。
  static const Duration fixedDuration = Duration(seconds: 4);

  /// 轨道高度（与字号挂钩）。
  static const double laneHeight = 22;

  /// 轨道数上限（防病态配置）。
  static const int maxLanes = 64;
  static double rowHeight(DanmakuSettings settings) =>
      (DanmakuStyle.baseFontSize * settings.fontScale * settings.lineSpacing)
          .clamp(16, 128);
  static int laneCount(Size size, DanmakuSettings settings) {
    final available = size.height * (settings.avoidSubtitles ? .82 : 1.0);
    final region = settings.rows > 0
        ? available
        : (size.height * settings.displayArea).clamp(0.0, available);
    final count = (region / rowHeight(settings)).floor().clamp(0, maxLanes);
    return settings.rows > 0 ? count.clamp(0, settings.rows) : count;
  }
}

/// 屏幕上的一条弹幕。
class _ActiveDanmaku {
  _ActiveDanmaku({
    required this.item,
    required this.lane,
    required this.bornAt,
  });

  final DanmakuItem item;
  final int lane;
  TextPainter? fill, outline;
  DanmakuStyle? cachedStyle;
  void dispose() {
    fill?.dispose();
    outline?.dispose();
    fill = outline = null;
  }

  void layout(DanmakuStyle style) {
    if (cachedStyle?.fontSize == style.fontSize &&
        cachedStyle?.color == style.color &&
        cachedStyle?.strokeWidth == style.strokeWidth &&
        cachedStyle?.bold == style.bold) {
      return;
    }
    dispose();
    cachedStyle = style;
    fill = _DanmakuPainter.textPainter(item.text, style);
    if (style.strokeWidth > 0) {
      outline = _DanmakuPainter.textPainter(item.text, style, stroke: true);
    }
  }

  /// 上屏时刻（视频时间轴）。
  final Duration bornAt;

  /// 滚动进度 0..1（0 = 刚进右边缘，1 = 完全离开左边缘）。
  double progress(Duration position, DanmakuSettings settings) {
    final span =
        DanmakuLayout.scrollDuration.inMilliseconds / settings.speedScale;
    if (span <= 0) return 1;
    final elapsed = (position - bornAt).inMilliseconds.toDouble();
    return (elapsed / span).clamp(0.0, 1.0);
  }

  /// 固定弹幕的剩余停留比例 1..0。
  double fixedRemaining(Duration position) {
    final elapsed = (position - bornAt).inMilliseconds;
    final total = DanmakuLayout.fixedDuration.inMilliseconds;
    return (1 - elapsed / total).clamp(0.0, 1.0);
  }

  bool isGone(Duration position, DanmakuSettings settings) {
    if (item.mode == DanmakuMode.scroll) {
      return progress(position, settings) >= 1.0;
    }
    return fixedRemaining(position) <= 0;
  }
}

/// 弹幕绘制：滚动 / 顶部 / 底部三类，统一描边保证可读。
class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.entries,
    required this.position,
    required this.settings,
    required this.playing,
    required this.pixelRatio,
  });

  final List<_ActiveDanmaku> entries;
  final Duration position;
  final DanmakuSettings settings;
  final bool playing;
  final double pixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final laneCount = DanmakuLayout.laneCount(size, settings);
    final rowHeight = DanmakuLayout.rowHeight(settings);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, laneCount * rowHeight));
    for (final entry in entries) {
      if (entry.lane >= laneCount || !settings.accepts(entry.item)) continue;
      final style = DanmakuStyle.of(entry.item, settings);
      entry.layout(style);
      final painter = entry.fill!;

      double? dx;
      double? dy;
      switch (entry.item.mode) {
        case DanmakuMode.scroll:
          // 从右边缘外进入，滚到左边缘外。
          final progress = entry.progress(position, settings);
          dx = size.width - (size.width + painter.width) * progress;
          dy = entry.lane * rowHeight;
        case DanmakuMode.top:
          dx = (size.width - painter.width) / 2;
          dy = entry.lane * rowHeight;
        case DanmakuMode.bottom:
          dx = (size.width - painter.width) / 2;
          dy = entry.lane * rowHeight;
      }

      // 越界（固定弹幕轨道超区）就不画。
      if (dy < 0 || dy + painter.height > size.height) continue;
      // 固定弹幕淡出：最后 25% 时间渐隐。
      final opacity = entry.item.mode == DanmakuMode.scroll
          ? 1.0
          : (entry.fixedRemaining(position) / 0.25).clamp(0.0, 1.0);

      canvas.save();
      if (opacity < 1) {
        canvas.saveLayer(
          Rect.fromLTWH(
            dx - style.strokeWidth,
            dy - style.strokeWidth,
            painter.width + style.strokeWidth * 2,
            painter.height + style.strokeWidth * 2,
          ),
          Paint()..color = Colors.white.withValues(alpha: opacity),
        );
      }
      final offset = Offset(
        (dx * pixelRatio).round() / pixelRatio,
        (dy * pixelRatio).round() / pixelRatio,
      );
      entry.outline?.paint(canvas, offset);
      painter.paint(canvas, offset);
      if (opacity < 1) canvas.restore();
      canvas.restore();
    }
    // laneCount 只用于诊断：轨道超出可视区时不再分配（在 _allocateLane 里靠 64 上限兜底）。
    canvas.restore();
  }

  /// 文本绘制：先描边再填充（浅色画面下也看得清）。
  static TextPainter textPainter(
    String text,
    DanmakuStyle style, {
    bool stroke = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: (style.fontSize) + 1,
          fontWeight: style.bold ? FontWeight.w600 : FontWeight.w600,
          color: stroke ? null : style.color,
          foreground: stroke
              ? (Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = style.strokeWidth
                  ..strokeJoin = StrokeJoin.round
                  ..color = Colors.black.withValues(alpha: style.color.a * .9))
              : null,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter;
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.entries.length != entries.length ||
      entries.asMap().entries.any(
        (entry) => !identical(entry.value, oldDelegate.entries[entry.key]),
      ) ||
      oldDelegate.settings != settings ||
      oldDelegate.pixelRatio != pixelRatio ||
      oldDelegate.playing != playing;
}
