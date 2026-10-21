import 'package:flutter/material.dart';

import '../shell/dock_liquid_lens.dart';
import '../shell/dock_native_glass.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/shell/shell_settings.dart';
import '../../core/theme/floating_modules.dart';
import '../../shared/widgets/drawer_geometry.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/lume_icon.dart';
import '../shell/shell_dock.dart';
import 'browse_layout_button.dart';

/// One row for source selection and the two collection shortcuts.
class CompactBrowseHeader extends StatelessWidget {
  const CompactBrowseHeader({
    super.key,
    required this.source,
    required this.actions,
    required this.mode,
    required this.onLayoutChanged,
  });
  final Widget source;
  final List<Widget> actions;
  final BrowseLayoutMode mode;
  final ValueChanged<BrowseLayoutMode> onLayoutChanged;

  @override
  Widget build(BuildContext context) => DrawerSearchAnchor(
    child: Row(
      children: [
        Expanded(child: source),
        const SizedBox(width: 4),
        TextButtonTheme(
          data: TextButtonThemeData(
            style: TextButton.styleFrom(
              fixedSize: const Size(56, 44),
              minimumSize: const Size(56, 44),
              maximumSize: const Size(56, 44),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              foregroundColor: Theme.of(context).colorScheme.onSurface,
              textStyle: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: actions),
        ),
        BrowseLayoutButton(
          mode: mode,
          onChanged: onLayoutChanged,
          quickSwitch: true,
        ),
      ],
    ),
  );
}

class BrowseSearchButton extends StatelessWidget {
  const BrowseSearchButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scope = ShellDockScope.maybeScopeOf(context);
    final beside = scope?.searchBesideDock == true;
    if (beside &&
        (scope?.notifier?.visible != true ||
            MediaQuery.viewInsetsOf(context).bottom > 0)) {
      return const SizedBox.shrink();
    }
    final appearance = ShellSettingsController.instance.appearance;
    final collapsed = beside && scope?.collapsed == true;
    final size = beside
        ? (collapsed
              ? (appearance.height * .82).clamp(40.0, 150.0)
              : appearance.height)
        : 52.0;
    final safe = scope?.safePadding ?? MediaQuery.viewPaddingOf(context);
    final margin = appearance.marginFor(
      MediaQuery.sizeOf(context).width - safe.horizontal,
      trailingWidth: size + 10,
    );
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      right: beside ? (collapsed ? 8 : margin) + safe.right : 16,
      bottom: beside
          ? scope?.dockBottom ?? safe.bottom + appearance.safeGap
          : safe.bottom + 12,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: size),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => _SearchGlassButton(
          size: value,
          appearance: appearance,
          onPressed: onPressed,
          beside: beside,
        ),
      ),
    );
  }
}

class _SearchGlassButton extends StatefulWidget {
  const _SearchGlassButton({
    required this.size,
    required this.appearance,
    required this.onPressed,
    required this.beside,
  });
  final double size;
  final DockAppearance appearance;
  final VoidCallback? onPressed;
  final bool beside;
  @override
  State<_SearchGlassButton> createState() => _SearchGlassButtonState();
}

class _SearchGlassButtonState extends State<_SearchGlassButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final liquid = widget.appearance.liquid;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final animate = widget.appearance.animateSelection && !reduced;
    final native =
        widget.beside &&
        DockNativeGlass.supported &&
        liquid.glassRenderer == DockGlassRenderer.nativeIos;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _pressed && animate ? 1 : 0),
      duration: Duration(
        milliseconds: animate ? widget.appearance.animationMs : 0,
      ),
      curve: Curves.easeOutBack,
      builder: (context, value, _) {
        final press = value.clamp(0.0, 1.0);
        final size = widget.size;
        return Transform.scale(
          scale: 1 + press * liquid.value(DockLiquidParameter.pressScale),
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (native)
                  DockNativeGlass(
                    borderRadius: BorderRadius.circular(size / 2),
                    cornerRadius: size / 2,
                    style: liquid.nativeGlassStyle,
                    reduceTransparency: MediaQuery.highContrastOf(context),
                  ),
                GlassPanel(
                  key: const ValueKey('browse-search-surface'),
                  module: widget.beside && !native ? FloatingModule.dock : null,
                  radius: size / 2,
                  color: native ? Colors.transparent : null,
                  blur: native ? 0 : 6,
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: widget.appearance.borderOpacity,
                    ),
                  ),
                  child: Listener(
                    onPointerDown: widget.onPressed == null
                        ? null
                        : (_) => setState(() => _pressed = true),
                    onPointerUp: (_) => setState(() => _pressed = false),
                    onPointerCancel: (_) => setState(() => _pressed = false),
                    child: IconButton(
                      tooltip: '搜索',
                      onPressed: widget.onPressed,
                      constraints: BoxConstraints.tightFor(
                        width: size,
                        height: size,
                      ),
                      icon: LumeIcon(
                        Icons.search,
                        slot: 'browse.floating.search',
                        size: (size * .45).clamp(20, 40),
                      ),
                    ),
                  ),
                ),
                if (!native && liquid.enabled(DockLiquidEffect.optics))
                  DockLiquidLens(
                    path: Path()..addOval(Rect.fromLTWH(0, 0, size, size)),
                    press: press,
                    stretch: 0,
                    highlight: press,
                    refraction: liquid.value(DockLiquidParameter.refraction),
                    dispersion: liquid.value(DockLiquidParameter.dispersion),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
