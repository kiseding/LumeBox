import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../core/shell/shell_settings.dart';
import '../../core/theme/floating_modules.dart';
import '../../core/theme/lume_theme.dart';

/// 底部 Dock 里的一条页签（只有展示数据，不含页面构造）。
///
/// 壳层与设置页的真实预览共用这一份数据形状：设置页里看到的就是壳层里跑的
/// 同一个 [ShellDockBar]，不存在「预览一套、线上另一套」。
class ShellDockEntry {
  const ShellDockEntry({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  /// 稳定标识（与 [ShellTab.id] 同源）。
  final String id;

  final String label;

  /// 未选中 / 选中图标。
  final IconData icon;
  final IconData selectedIcon;
}

/// 底部悬浮 Dock：真实毛玻璃胶囊 + 可拖拽、会拉伸、松手弹簧吸附的水滴。
///
/// 结构分三层：
/// 1. [ClipRRect] + [BackdropFilter]：把**背后的页面内容**真正模糊掉，
///    白度（[FloatingStyle.opacity]）与磨砂强度（[FloatingStyle.blur]）都来自
///    「设置 → 底部导航栏管理」，滑块拖动时立刻重绘；
/// 2. 水滴层：单独一颗 [Positioned] 的水滴，位置与宽度由两个
///    [AnimationController] 驱动。拖动时直接写值跟手，松手后分别用
///    [SpringSimulation] 把「中心所在页签」和「宽度」弹回目标；
/// 3. 页签内容层：图标 + 文案，颜色随选中态过渡。内容画在水滴之后，保证
///    选中的图标 / 文字始终清晰——水滴是玻璃上的装饰层，不是遮罩。
///
/// 手势全部落在包裹内容的 [GestureDetector] 上：水平拖动由它赢过页签的
/// [InkWell] 点击；点击则走 [InkWell] 与 [GestureDetector.onTapUp] 两条路，
/// 都汇到同一个 [_selectIndex]，不会出现「拖一套、点另一套」。
class ShellDockBar extends StatefulWidget {
  const ShellDockBar({
    super.key,
    required this.entries,
    required this.activeId,
    required this.onSelect,
    required this.appearance,
    this.contentInset = 0,
    this.bottomMargin = 0,
    this.visible = true,
    this.applyViewPadding = true,
  });

  /// 水滴（选中底座）的定位键（测试与截图预览按它量位置 / 宽度）。
  static const Key selectionPillKey = Key('shell.dock.selectionPill');

  /// 胶囊内左右留白：首尾页签离圆角留一档，五项之间的净间距也跟着收紧。
  static const double innerPadding = 6;

  /// 水滴的最大宽度：页签很少时（用户隐藏到只剩 1–2 个）不会摊成一整条。
  static const double maxPillWidth = 104;

  /// 水滴在内容区上下各留的距离。
  static const double _dropInset = 4;

  final List<ShellDockEntry> entries;
  final String activeId;
  final ValueChanged<String> onSelect;

  /// 尺寸 / 玻璃边缘 / 投影 / 动效（设置页实时改）。
  final DockAppearance appearance;

  /// 胶囊**内部**给系统手势条让出的高度：外框照样画到底，只是里面的
  /// 图标与文字往上缩这一段。
  final double contentInset;

  /// 胶囊外框离屏幕底边的距离：0 = 外框直接画到屏幕底边。
  final double bottomMargin;

  /// 显隐：隐藏时整块（含内边距）平移到屏幕下沿之外，不占视觉、不响应点击。
  final bool visible;

  /// 是否叠加系统安全区左右留白。壳层里为 true；设置页里的内嵌预览为 false
  /// （否则横屏刘海会把预览条挤偏）。
  final bool applyViewPadding;

  /// 胶囊总高（外框）= 内容条 + 手势条避让。
  double get capsuleHeight => appearance.height + contentInset;

  @override
  State<ShellDockBar> createState() => _ShellDockBarState();
}

class _ShellDockBarState extends State<ShellDockBar>
    with TickerProviderStateMixin {
  /// 水滴中心所在的「连续页签坐标」：0 = 第一项中心，1 = 第二项中心……
  ///
  /// 用页签坐标而不是像素：横竖屏切换、隐藏页签、改左右留白时槽宽会变，
  /// 但「水滴在哪两个页签之间」不需要重算，重建时会自然落到新槽位。
  late final AnimationController _indexController;

  /// 水滴宽度相对基准宽度的倍率（拖动时 > 1，松手后弹簧回 1）。
  late final AnimationController _widthController;

  /// 拖动期间用来让速度自然衰减：手指停住时水滴不会一直保持被拉长的样子。
  late final Ticker _dragTicker;

  late final Listenable _dropAnimation;

  /// 当前「已经落定」的页签下标（页面实际停在哪一项）。
  int _resolvedIndex = 0;

  /// 最近一次吸附目标（弹簧完成时用来消掉亚像素残差）。
  int _targetIndex = 0;

  bool _dragging = false;

  /// 平滑后的水平速度（px/s），用于把水滴拉成橡皮筋。
  double _dragVelocity = 0;

  /// 上一次拖动采样的时间戳；为空或时间倒退时退化到「按 60fps 估计」。
  Duration? _lastDragStamp;

  @override
  void initState() {
    super.initState();
    _resolvedIndex = _indexOf(widget.activeId);
    _targetIndex = _resolvedIndex;
    _indexController = AnimationController.unbounded(
      vsync: this,
      value: _resolvedIndex.toDouble(),
    );
    _widthController = AnimationController.unbounded(vsync: this, value: 1);
    _dragTicker = createTicker(_onDragTick);
    _dropAnimation = Listenable.merge(<Listenable>[
      _indexController,
      _widthController,
    ]);
    // 弹簧的 isDone 有容差，落定时把值钉死在目标上，避免留下半个像素。
    _indexController.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_dragging) {
        _indexController.value = _targetIndex.toDouble();
      }
    });
    _widthController.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_dragging) {
        _widthController.value = 1;
      }
    });
  }

  @override
  void didUpdateWidget(ShellDockBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = _indexOf(widget.activeId);
    if (index != _resolvedIndex) {
      _resolvedIndex = index;
      // 拖动中不改落点：手指还没松开，松手时自然会按当前位置重新吸附。
      if (!_dragging) _animateToIndex(index);
    }
  }

  @override
  void dispose() {
    _dragTicker.dispose();
    _indexController.dispose();
    _widthController.dispose();
    super.dispose();
  }

  /// 标识 → 下标；标识失效时退回上一个落点，绝不让下标越界。
  int _indexOf(String id) {
    if (widget.entries.isEmpty) return 0;
    final found = widget.entries.indexWhere((entry) => entry.id == id);
    if (found >= 0) return found;
    return _resolvedIndex.clamp(0, widget.entries.length - 1);
  }

  /// 上一次生成的水滴磨砂滤镜。AnimatedBuilder 每帧都会重建水滴，
  /// 按 sigma 缓存一份，避免每帧新建 [ImageFilter]。
  double? _cachedBlurSigma;
  ImageFilter? _cachedBlur;

  ImageFilter _blurFilter(double sigma) {
    if (_cachedBlur == null || _cachedBlurSigma != sigma) {
      _cachedBlurSigma = sigma;
      _cachedBlur = ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.mirror,
      );
    }
    return _cachedBlur!;
  }

  // ------------------------------------------------------------------ 手势

  void _onDragStart(DragStartDetails details, double slot) {
    if (widget.entries.isEmpty) return;
    _dragTicker.stop();
    _indexController.stop();
    _widthController.stop();
    _lastDragStamp = null;
    _dragVelocity = 0;
    // 手指按下的位置就是水滴的新中心：像真的水珠被按过去一样跟手。
    _indexController.value = _indexForX(details.localPosition.dx, slot);
    _widthController.value = 1;
    setState(() => _dragging = true);
    if (!_dragTicker.isActive) _dragTicker.start();
  }

  void _onDragUpdate(DragUpdateDetails details, double slot) {
    if (widget.entries.isEmpty) return;
    _updateDragVelocity(details);
    // 核心跟手逻辑：localPosition.dx → 连续页签坐标，水滴中心贴着手指。
    _indexController.value = _indexForX(details.localPosition.dx, slot);
    _widthController.value = _widthScaleFor(_dragVelocity);
  }

  void _onDragEnd(DragEndDetails details, double slot) {
    _finishDrag(velocityPx: details.velocity.pixelsPerSecond.dx, slot: slot);
  }

  void _onDragCancel(double slot) => _finishDrag(velocityPx: 0, slot: slot);

  void _finishDrag({required double velocityPx, required double slot}) {
    _dragTicker.stop();
    _dragVelocity = 0;
    if (widget.entries.isEmpty) {
      setState(() => _dragging = false);
      return;
    }
    // 离手指最近的页签：用连续坐标四舍五入，而不是按拖动起点算。
    final nearest = _indexController.value.round().clamp(
      0,
      widget.entries.length - 1,
    );
    // 把松手速度换算成「页签/秒」，作为弹簧初速度：甩得越快，回弹越过
    // 目标越多，视觉上更像水被甩出去再被表面张力拉回来。
    final velocityIndex = slot <= 0
        ? 0.0
        : (velocityPx / slot).clamp(-10.0, 10.0);
    _selectIndex(nearest, velocity: velocityIndex);
  }

  /// 点击：页签自己的 [InkWell] 与底层 [GestureDetector.onTapUp] 都走这里。
  void _onTapUp(TapUpDetails details, double slot) {
    if (widget.entries.isEmpty || slot <= 0) return;
    // 点按不是拖动，按触点最近项吸附即可；不要求先落在水滴上。
    final nearest = ((details.localPosition.dx - slot / 2) / slot)
        .round()
        .clamp(0, widget.entries.length - 1);
    _selectIndex(nearest);
  }

  /// 页签自身的点按路径（保留 InkWell 的水波、语义与测试可点性）。
  void _onItemTap(int index) => _selectIndex(index);

  void _selectIndex(int index, {double velocity = 0}) {
    if (widget.entries.isEmpty) return;
    final target = index.clamp(0, widget.entries.length - 1);
    setState(() {
      _dragging = false;
      _resolvedIndex = target;
    });
    _animateToIndex(target, velocity: velocity);
    widget.onSelect(widget.entries[target].id);
  }

  /// 手指位置 → 连续页签坐标。两端做夹取：水滴不会滑出内容区。
  double _indexForX(double x, double slot) {
    if (slot <= 0 || widget.entries.length <= 1) return 0;
    return (x - slot / 2) / slot;
  }

  /// 速度 → 宽度倍率：越快拉得越长，但有上限，避免变成一条横线。
  double _widthScaleFor(double velocityPx) {
    final normalized = (velocityPx.abs() / 1800).clamp(0.0, 1.0);
    return 1 + normalized * .65;
  }

  void _updateDragVelocity(DragUpdateDetails details) {
    final stamp = details.sourceTimeStamp;
    final previous = _lastDragStamp;
    if (stamp != null && previous != null && stamp > previous) {
      final seconds =
          (stamp - previous).inMicroseconds / Duration.microsecondsPerSecond;
      if (seconds > 0) {
        final instant = details.delta.dx / seconds;
        // 指数平滑：单帧抖动不会让水滴突然抽搐。
        _dragVelocity = _dragVelocity == 0
            ? instant
            : _dragVelocity * .65 + instant * .35;
        _lastDragStamp = stamp;
        return;
      }
    }
    // 无时间戳（或被合并成一帧）：按 60fps 估计，保证仍然有拉伸反馈。
    final estimated = details.delta.dx * 60;
    _dragVelocity = _dragVelocity == 0
        ? estimated
        : _dragVelocity * .65 + estimated * .35;
    _lastDragStamp = stamp;
  }

  /// 手指停住时速度衰减，水滴慢慢缩回基准宽度；仍保留一点点余量等下一帧。
  void _onDragTick(Duration _) {
    if (!_dragging) {
      _dragTicker.stop();
      return;
    }
    _dragVelocity *= .86;
    if (_dragVelocity.abs() < 24) {
      _dragVelocity = 0;
      _dragTicker.stop();
      _widthController.value = 1;
      return;
    }
    _widthController.value = _widthScaleFor(_dragVelocity);
  }

  // ------------------------------------------------------------------ 弹簧

  /// 设置里的 [DockAppearance.animationMs] 是「吸附过程大概多久」：
  /// 用它换算弹簧刚度（周期与 1/√k 成正比），时长越长弹簧越软；阻尼按固定
  /// 阻尼比换算成显式的 damping 值，水珠才会过冲一点点再回来。
  SpringDescription _springDescription() {
    final ms = widget.appearance.animationMs.clamp(100, 2000);
    final period = (ms / 1000) * .56;
    final stiffness = math.pow((2 * math.pi) / period, 2).toDouble();
    final damping = 2 * .62 * math.sqrt(stiffness);
    return SpringDescription(mass: 1, stiffness: stiffness, damping: damping);
  }

  /// 把水滴弹到第 [index] 个页签中心。
  ///
  /// 两个独立弹簧：
  /// - [_indexController]：连续坐标 → 目标下标，带松手速度；
  /// - [_widthController]：被拉长的宽度 → 1，回到基准宽度。
  ///
  /// 分开弹而不是套一个 Tween：宽度和位移的初始速度不同，合成一个补间会
  /// 让「水滴先缩回再走」或「先走到再缩回」，两种都不像水。
  void _animateToIndex(int index, {double velocity = 0}) {
    _targetIndex = index;
    final target = index.toDouble();
    final from = _indexController.value;
    final widthFrom = _widthController.value;
    final animate = widget.appearance.animateSelection;

    if (!animate) {
      _indexController.stop();
      _widthController.stop();
      _indexController.value = target;
      _widthController.value = 1;
      return;
    }

    // 已经停在目标而且没有被拉长：不需要再起一次弹簧。
    if ((from - target).abs() < .001 &&
        (widthFrom - 1).abs() < .001 &&
        velocity.abs() < 1) {
      _indexController.value = target;
      _widthController.value = 1;
      return;
    }

    final spring = _springDescription();
    _indexController.animateWith(
      SpringSimulation(spring, from, target, velocity),
    );
    _widthController.animateWith(SpringSimulation(spring, widthFrom, 1, 0));
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FloatingModules.instance,
      builder: (context, _) {
        final style = FloatingModules.instance.style(FloatingModule.dock);
        final dark = LumeTheme.palette.brightness == Brightness.dark;
        final radius = BorderRadius.circular(widget.capsuleHeight / 2);
        final borderAlpha = _borderAlpha(dark);
        final fill = (dark ? LumeTheme.glass : Colors.white).withValues(
          alpha: style.opacity,
        );
        // 水滴与外层玻璃共用同一份材质设置：白度、磨砂、边缘高光全部来自
        // FloatingModules / DockAppearance，不在组件里另写一套固定颜色。
        // 水滴是叠在玻璃上的第二层，白度取同一变量的 1.35 倍：默认 45% 时约
        // 61%，水珠才浮得出来；两端仍严格跟随设置（0% 全透、100% 全白）。
        final dropFill = (dark ? LumeTheme.glass : Colors.white).withValues(
          alpha: (style.opacity * 1.35).clamp(0.0, 1.0),
        );
        final dropFilter = _blurFilter(style.blur);
        final whiteGlow = (style.opacity * .40).clamp(0.0, .50);
        final accentGlow = (style.opacity * .26).clamp(0.0, .35);
        // 玻璃上沿高光也跟随白度：白度 0 时整块玻璃没有反光，100% 时最亮。
        final sheenTop = (style.opacity * (dark ? .22 : .44)).clamp(0.0, .32);
        final sheenBottom = (style.opacity * (dark ? .04 : .10)).clamp(
          0.0,
          .12,
        );
        // 正的离底距离用 Padding 抬高（参与布局）；负值不能塞进 Padding
        // （EdgeInsets 不允许负的 bottom），改用 Transform 向下平移，既保留
        // 「压进安全区」的语义，也不会触发 RenderPadding 的断言。
        final layoutBottom = widget.bottomMargin > 0
            ? widget.bottomMargin
            : 0.0;
        final sink = widget.bottomMargin < 0 ? -widget.bottomMargin : 0.0;

        // 上下内边距跟着高度走：40pt 时收到 2，54pt 时 6，150pt 时封顶 10。
        // 文案用 Flexible + FittedBox 兜底，40pt 的极限高度也不会 RenderFlex
        // overflow；默认档位的图标 20 / 文字 14.4 尺寸完全不变。
        final verticalPadding = ((widget.appearance.height - 42) / 2).clamp(
          2.0,
          10.0,
        );

        return Transform.translate(
          offset: Offset(style.x, style.y),
          child: IgnorePointer(
            ignoring: !widget.visible,
            child: ExcludeSemantics(
              excluding: !widget.visible,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final safe = widget.applyViewPadding
                      ? MediaQuery.viewPaddingOf(context)
                      : EdgeInsets.zero;
                  return AnimatedSlide(
                    offset: widget.visible ? Offset.zero : const Offset(0, 1.2),
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        widget.appearance.horizontalMargin + safe.left,
                        0,
                        widget.appearance.horizontalMargin + safe.right,
                        layoutBottom,
                      ),
                      child: Transform.translate(
                        offset: Offset(0, sink),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: radius,
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: widget.appearance.shadowOpacity,
                                ),
                                blurRadius: 20,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: radius,
                            child: BackdropFilter(
                              // 真正吃背后页面内容的一层：白度与 sigma 全部来自
                              // 设置（FloatingModules 的 dock 样式）。少了这一层，
                              // 下面那层白色半透明只会是一块塑料板。
                              filter: dropFilter,
                              child: SizedBox(
                                height: widget.capsuleHeight,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: <Widget>[
                                    // ① 半透明白底（不是实心白）。
                                    ColoredBox(color: fill),
                                    // ② 玻璃上沿的一道光：上亮下暗，像有厚度的玻璃
                                    // 反光；强度跟随白度设置，白度 0 时完全消失。
                                    IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          borderRadius: radius,
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: <Color>[
                                              Colors.white.withValues(
                                                alpha: sheenTop,
                                              ),
                                              Colors.white.withValues(alpha: 0),
                                              Colors.white.withValues(
                                                alpha: sheenBottom,
                                              ),
                                            ],
                                            stops: const <double>[0, .55, 1],
                                          ),
                                          // 极细的白色描边：模拟玻璃边缘反光。
                                          border: Border.all(
                                            color: Colors.white.withValues(
                                              alpha: borderAlpha,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    // ③ 内容：水滴层 + 页签层。
                                    Padding(
                                      padding: EdgeInsets.only(
                                        bottom: widget.contentInset,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: ShellDockBar.innerPadding,
                                        ),
                                        child: _buildContent(
                                          verticalPadding: verticalPadding,
                                          dropFill: dropFill,
                                          dropFilter: dropFilter,
                                          dropBorder: Colors.white.withValues(
                                            alpha: borderAlpha,
                                          ),
                                          whiteGlow: whiteGlow,
                                          accentGlow: accentGlow,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildContent({
    required double verticalPadding,
    required Color dropFill,
    required ImageFilter dropFilter,
    required Color dropBorder,
    required double whiteGlow,
    required double accentGlow,
  }) {
    final entries = widget.entries;

    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth;
        if (entries.isEmpty) return const SizedBox.expand();

        final slot = contentWidth / entries.length;
        final baseWidth = (slot - 12).clamp(0.0, ShellDockBar.maxPillWidth);
        final dropHeight = (constraints.maxHeight - ShellDockBar._dropInset * 2)
            .clamp(0.0, double.infinity);
        final dropRadius = BorderRadius.circular(dropHeight / 2);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 拖动过程中每一步都用 localPosition.dx 重算水滴中心；
          // 速度只影响宽度，不改变「水滴贴着手指」这条主逻辑。
          onHorizontalDragStart: (details) => _onDragStart(details, slot),
          onHorizontalDragUpdate: (details) => _onDragUpdate(details, slot),
          onHorizontalDragEnd: (details) => _onDragEnd(details, slot),
          onHorizontalDragCancel: () => _onDragCancel(slot),
          // 覆盖页签之间的空隙；页签自身的 InkWell 仍保留点击语义。
          onTapUp: (details) => _onTapUp(details, slot),
          child: AnimatedBuilder(
            animation: _dropAnimation,
            builder: (context, _) {
              // 水滴中心始终取连续坐标：拖动时它等于手指位置，松手后由弹簧
              // 一帧帧推到目标中心，不能在松手瞬间直接换成整数下标。
              final focus = _indexController.value.clamp(
                0.0,
                (entries.length - 1).toDouble(),
              );
              final activeIndex = (_dragging ? focus.round() : _resolvedIndex)
                  .clamp(0, entries.length - 1);
              // 水珠宽度 = 基准宽度 × 速度倍率；夹取只防极端值。
              final dropWidth = (baseWidth * _widthController.value).clamp(
                baseWidth * .75,
                contentWidth,
              );
              // 中心跟着连续坐标走，left 永远 = 中心 - 半宽（橡皮筋拉伸时
              // 向两侧同时长，而不是只向右长）。
              final center = focus * slot + slot / 2;
              final maxLeft = (contentWidth - dropWidth).clamp(
                0.0,
                double.infinity,
              );
              final left = (center - dropWidth / 2).clamp(0.0, maxLeft);

              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  // 水滴先画：它是玻璃上的装饰层；页签内容后画，选中项的
                  // 图标与文字不会被水滴的磨砂白底糊掉。
                  Positioned(
                    left: left,
                    top: ShellDockBar._dropInset,
                    width: dropWidth,
                    height: dropHeight,
                    child: IgnorePointer(
                      child: _WaterDrop(
                        key: ShellDockBar.selectionPillKey,
                        radius: dropRadius,
                        fill: dropFill,
                        filter: dropFilter,
                        border: dropBorder,
                        whiteGlow: whiteGlow,
                        accentGlow: accentGlow,
                      ),
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (var index = 0; index < entries.length; index++)
                        Expanded(
                          child: _DockItem(
                            entry: entries[index],
                            selected: index == activeIndex,
                            onTap: () => _onItemTap(index),
                            verticalPadding: verticalPadding,
                            animateSelection:
                                widget.appearance.animateSelection,
                            animationDuration: Duration(
                              milliseconds: widget.appearance.animationMs,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// 深色主题下把边框强度按比例柔化：白色 1px 在暗底上比亮底醒目得多。
  double _borderAlpha(bool dark) {
    return dark
        ? widget.appearance.borderOpacity * 0.44
        : widget.appearance.borderOpacity;
  }
}

/// 毛玻璃水滴：拖动时是橡皮筋，静止时是一颗贴在玻璃上的水珠。
///
/// 材质不是写死的：填充色与磨砂强度来自 [FloatingStyle] 的 dock 样式（玻璃
/// 白度 / 磨砂强度），边框来自 [DockAppearance.borderOpacity]（边缘高光）。
/// 它叠在外层 Dock 玻璃之上，所以背后的颜色会先被外层磨砂一次、再被水滴轻磨
/// 一次——选中底座才有「一滴水」的体积感，而不是一块纯色圆角矩形。
class _WaterDrop extends StatelessWidget {
  const _WaterDrop({
    super.key,
    required this.radius,
    required this.fill,
    required this.filter,
    required this.border,
    required this.whiteGlow,
    required this.accentGlow,
  });

  final BorderRadius radius;

  /// 与 Dock 相同的半透明白底（白度设置）。
  final Color fill;

  /// 与 Dock 相同的磨砂强度（磨砂设置）。
  final ImageFilter filter;

  /// 1px 白边（边缘高光设置）。
  final Color border;

  /// 白色 / 主题色外发光，强度跟随白度，白度 0 时一起消失。
  final double whiteGlow;
  final double accentGlow;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      // 外发光模拟水珠边缘的折射：不额外加底色，纯光晕。
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: <BoxShadow>[
          if (whiteGlow > 0)
            BoxShadow(
              color: Colors.white.withValues(alpha: whiteGlow),
              blurRadius: 12,
              spreadRadius: -4,
              offset: const Offset(0, 1),
            ),
          if (accentGlow > 0)
            BoxShadow(
              color: LumeTheme.accent.withValues(alpha: accentGlow),
              blurRadius: 18,
              spreadRadius: -6,
              offset: const Offset(0, 5),
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: filter,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: radius,
              border: Border.all(color: border, width: 1),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

/// 单个页签：图标 + 文案，颜色随选中态平滑过渡。
class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.verticalPadding,
    required this.animateSelection,
    required this.animationDuration,
  });

  final ShellDockEntry entry;
  final bool selected;
  final VoidCallback onTap;

  /// 上下内边距：由 Dock 高度反推（40–150 档位里保持内容居中）。
  final double verticalPadding;

  /// 设置页的「点击弹跳动效」开关；关闭时所有过渡时长归零（立即切换）。
  final bool animateSelection;

  /// 选中水滴 / 图标 / 文字过渡时长（设置页可调，100–2000ms）。
  final Duration animationDuration;

  /// 实际生效的时长：关掉动效时直接跳到终态。
  Duration get _selectionDuration =>
      animateSelection ? animationDuration : Duration.zero;

  /// 图标槽固定高度（选中图标 20 + 上下各 1 = 22）。
  static const double _iconSlot = 22;

  @override
  Widget build(BuildContext context) {
    final color = selected ? LumeTheme.accent : LumeTheme.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: verticalPadding),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            SizedBox(
              height: _iconSlot,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  // 图标：颜色平滑过渡，实心 / 线框之间交叉淡入；选中时轻微放大，
                  // 给滑动水滴一个落点反馈（水滴负责位移，图标只负责「弹」）。
                  TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: color),
                    duration: _selectionDuration,
                    curve: Curves.easeInOut,
                    builder: (context, animatedColor, _) => AnimatedScale(
                      scale: selected ? 1.06 : 1,
                      duration: _selectionDuration,
                      curve: selected ? Curves.easeOutBack : Curves.easeIn,
                      child: AnimatedSwitcher(
                        duration: _selectionDuration,
                        switchInCurve: Curves.easeOutBack,
                        switchOutCurve: Curves.easeIn,
                        transitionBuilder: (child, animation) =>
                            ScaleTransition(
                              scale: Tween<double>(
                                begin: .8,
                                end: 1,
                              ).animate(animation),
                              child: FadeTransition(
                                opacity: animation,
                                child: child,
                              ),
                            ),
                        child: Icon(
                          selected ? entry.selectedIcon : entry.icon,
                          key: ValueKey<bool>(selected),
                          size: 20,
                          color: animatedColor,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // 高度收到 40pt 时剩余空间不足以放下整行文字：Flexible 先让出
            // 可用高度，FittedBox 再等比缩小，杜绝 RenderFlex overflow。
            // 默认 54pt 档位空间足够，字号仍是 captionSize，不会被缩放。
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: color),
                  duration: _selectionDuration,
                  curve: Curves.easeInOut,
                  builder: (context, animatedColor, _) => Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: LumeTypography.captionSize,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: animatedColor,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
