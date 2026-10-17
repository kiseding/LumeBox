import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

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

/// 底部悬浮 Dock：真实毛玻璃胶囊 + 会滑动的选中胶囊。
///
/// 结构分三层：
/// 1. [ClipRRect] + [BackdropFilter]：把**背后的页面内容**真正模糊掉，
///    白度（[FloatingStyle.opacity]）与磨砂强度（[FloatingStyle.blur]）都来自
///    「设置 → 底部导航栏管理」，滑块拖动时立刻重绘；
/// 2. 独立的选中胶囊层：用 [AnimatedPositioned] 在页签槽位之间滑动，而不是每个
///    页签各自原地缩放——这是「水滴从上一个 Tab 滑到下一个 Tab」的来源；
/// 3. 页签内容层：图标 + 文案，颜色随选中态过渡。
///
/// 选中胶囊单独占一层（而不是画在每个页签里），所以切换时只有**一块**底色在
/// 移动；旧实现每项各有一个底座，视觉上像几块色斑各自闪，没有连贯的水滴感。
class ShellDockBar extends StatelessWidget {
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

  /// 选中胶囊的定位键（测试与截图预览按它量滑动位置）。
  static const Key selectionPillKey = Key('shell.dock.selectionPill');

  /// 胶囊内左右留白：首尾页签离圆角留一档，五项之间的净间距也跟着收紧。
  static const double innerPadding = 6;

  /// 选中胶囊的最大宽度：页签很少时（用户隐藏到只剩 1–2 个）不会摊成一整条。
  static const double maxPillWidth = 104;

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
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FloatingModules.instance,
      builder: (context, _) {
        final style = FloatingModules.instance.style(FloatingModule.dock);
        final dark = LumeTheme.palette.brightness == Brightness.dark;
        final radius = BorderRadius.circular(capsuleHeight / 2);
        final borderAlpha = _borderAlpha(dark);
        final fill = (dark ? LumeTheme.glass : Colors.white).withValues(
          alpha: style.opacity,
        );

        // 上下内边距跟着高度走：48pt 时收到 3，64pt 时放到 10；图标槽 22 +
        // 间距 4 + 文字 14.4 这一组内容高度不变，因此任何档位都不会挤爆。
        final verticalPadding = ((appearance.height - 42) / 2).clamp(2.0, 10.0);

        return Transform.translate(
          offset: Offset(style.x, style.y),
          child: IgnorePointer(
            ignoring: !visible,
            child: ExcludeSemantics(
              excluding: !visible,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final safe = applyViewPadding
                      ? MediaQuery.viewPaddingOf(context)
                      : EdgeInsets.zero;
                  return AnimatedSlide(
                    offset: visible ? Offset.zero : const Offset(0, 1.2),
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        appearance.horizontalMargin + safe.left,
                        0,
                        appearance.horizontalMargin + safe.right,
                        bottomMargin,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: appearance.shadowOpacity,
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
                            // 设置（默认 45% / 15）。少了这一层，下面那层白色
                            // 半透明只会是一块塑料板。
                            filter: ImageFilter.blur(
                              sigmaX: style.blur,
                              sigmaY: style.blur,
                              tileMode: TileMode.mirror,
                            ),
                            child: SizedBox(
                              height: capsuleHeight,
                              child: Stack(
                                fit: StackFit.expand,
                                children: <Widget>[
                                  // ① 半透明白底（不是实心白）。
                                  ColoredBox(color: fill),
                                  // ② 玻璃上沿的一道光：上亮下暗，像有厚度的玻璃
                                  // 反光；只加很轻的白色，不压掉背后的颜色。
                                  IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        borderRadius: radius,
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: <Color>[
                                            Colors.white.withValues(
                                              alpha: dark ? .10 : .20,
                                            ),
                                            Colors.white.withValues(alpha: 0),
                                            Colors.white.withValues(
                                              alpha: dark ? .02 : .05,
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
                                  // ③ 内容：选中胶囊层 + 页签层。
                                  Padding(
                                    padding: EdgeInsets.only(
                                      bottom: contentInset,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: innerPadding,
                                      ),
                                      child: _buildContent(
                                        dark: dark,
                                        verticalPadding: verticalPadding,
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
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildContent({required bool dark, required double verticalPadding}) {
    final activeIndex = entries.indexWhere((entry) => entry.id == activeId);
    final index = activeIndex < 0 ? 0 : activeIndex;
    final duration = appearance.animateSelection
        ? Duration(milliseconds: appearance.animationMs)
        : Duration.zero;

    return LayoutBuilder(
      builder: (context, constraints) {
        final slot = entries.isEmpty
            ? constraints.maxWidth
            : constraints.maxWidth / entries.length;
        final pillWidth = (slot - 12).clamp(0.0, maxPillWidth).toDouble();
        final pillLeft = index * slot + (slot - pillWidth) / 2;

        return Stack(
          children: <Widget>[
            // 独立背景层：只它在动。Curves.easeOutBack 带来轻微过冲再回弹，
            // 就是「水滴被甩过去、又被表面张力拉回来」的手感。
            AnimatedPositioned(
              left: pillLeft,
              top: 4,
              width: pillWidth,
              bottom: 4,
              duration: duration,
              curve: Curves.easeOutBack,
              child: IgnorePointer(
                child: _SelectionPill(
                  key: selectionPillKey,
                  dark: dark,
                  radius: BorderRadius.circular(capsuleHeight / 2),
                ),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final entry in entries)
                  Expanded(
                    child: _DockItem(
                      entry: entry,
                      selected: entry.id == activeId,
                      onTap: () => onSelect(entry.id),
                      verticalPadding: verticalPadding,
                      animateSelection: appearance.animateSelection,
                      animationDuration: duration,
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// 深色主题下把边框强度按比例柔化：白色 1px 在暗底上比亮底醒目得多。
  double _borderAlpha(bool dark) {
    return dark ? appearance.borderOpacity * 0.44 : appearance.borderOpacity;
  }
}

/// 选中胶囊：磨砂玻璃上的一颗「水滴」。
///
/// 它叠在 Dock 的玻璃层之上，不再做第二次模糊（那会让胶囊里外糊成一片），
/// 只用一层很淡的白色渐变 + 白色描边 + 主色辉光交代体积。
class _SelectionPill extends StatelessWidget {
  const _SelectionPill({super.key, required this.dark, required this.radius});

  final bool dark;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Colors.white.withValues(alpha: dark ? .24 : .46),
            Colors.white.withValues(alpha: dark ? .08 : .16),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: dark ? .34 : .62),
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: LumeTheme.accent.withValues(alpha: dark ? .22 : .14),
            blurRadius: 14,
            spreadRadius: -3,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: const SizedBox.expand(),
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

  /// 上下内边距：由 Dock 高度反推（48–64 档位里保持内容高度不变）。
  final double verticalPadding;

  /// 设置页的「点击弹跳动效」开关；关闭时所有过渡时长归零（立即切换）。
  final bool animateSelection;

  /// 选中胶囊 / 图标 / 文字过渡时长（设置页可调，150–400ms）。
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
                  // 给滑动胶囊一个落点反馈（背景层负责位移，图标只负责「弹」）。
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
            TweenAnimationBuilder<Color?>(
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
          ],
        ),
      ),
    );
  }
}
