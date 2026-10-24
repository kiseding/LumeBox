import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'frosted_glass_widget.dart';

import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../../core/theme/lume_theme.dart';

/// Dock 收起后的左下角悬浮球：三种样式共用同一套位置/手势，只换外观。
///
/// 背景统一走 [BackdropFilter] 毛玻璃：
/// - 灵动箭头：主题渐变 + 白色箭头；
/// - 精致网格：半透明白玻璃 + 主题紫九点；
/// - 极简线条：更透的白玻璃 + 主题紫三横线。
class DockHandleButton extends StatelessWidget {
  const DockHandleButton({
    super.key,
    required this.style,
    this.size = 52,
    this.opacity = 1,
    this.onPressed,
    this.tooltip = '展开导航',
    this.sectionIcon = Icons.auto_stories_rounded,
    this.sectionId = 'comic',
    this.materialOpacity = .6,
  });

  final DockHandleStyle style;
  final double size;

  /// 空闲态整体透明度（用户口径：不用的时候可以半透明）。
  final double opacity;
  final VoidCallback? onPressed;
  final String tooltip;
  final IconData sectionIcon;
  final String sectionId;
  final double materialOpacity;

  @override
  Widget build(BuildContext context) {
    final currentSection = style == DockHandleStyle.currentSection;
    final accent = LumeTheme.accent;
    final border = Border.all(
      color: Colors.white.withValues(alpha: .28 * materialOpacity),
    );
    final content = switch (style) {
      DockHandleStyle.currentSection => LumeIcon(
        sectionIcon,
        slot: 'dock.$sectionId.selected',
        size: size * .52,
        color: accent,
      ),
      DockHandleStyle.arrow => LumeIcon(
        Icons.chevron_right_rounded,
        slot: 'dock_handle_button.1',
        size: size * .58,
        color: accent,
      ),
      DockHandleStyle.grid => LumeIcon(
        Icons.grid_view,
        slot: 'dock.handle.grid',
        label: '收起后的导航把手 · 网格',
        group: '底部导航',
        color: accent,
        size: size * .58,
        fallback: _DotGrid(color: accent),
      ),
      DockHandleStyle.lines => LumeIcon(
        Icons.menu,
        slot: 'dock.handle.lines',
        label: '收起后的导航把手 · 横线',
        group: '底部导航',
        color: accent,
        size: size * .58,
        fallback: _RoundedLines(color: accent),
      ),
    };
    const fill = BoxDecoration(shape: BoxShape.circle);

    return Opacity(
      opacity: opacity,
      child: Tooltip(
        message: tooltip,
        child: SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: border,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .08 * materialOpacity),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipOval(
              child: FrostedGlassWidget(
                nativeGlass: true,
                neutralTint: true,
                materialOpacity: materialOpacity,
                nativeStyle: currentSection ? DockNativeGlassStyle.thin : null,
                opacity: currentSection ? .18 : .72,
                border: !currentSection,
                radius: size / 2,
                child: DecoratedBox(
                  decoration: fill,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onPressed,
                      child: Center(child: content),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DotGrid extends StatelessWidget {
  const _DotGrid({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var row = 0; row < 3; row++)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var column = 0; column < 3; column++)
              Padding(
                padding: const EdgeInsets.all(2.4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox(width: 4.6, height: 4.6),
                ),
              ),
          ],
        ),
    ],
  );
}

class _RoundedLines extends StatelessWidget {
  const _RoundedLines({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < 3; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.2),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
            child: const SizedBox(width: 20, height: 3.4),
          ),
        ),
    ],
  );
}
