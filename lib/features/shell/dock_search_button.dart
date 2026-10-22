import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../../core/theme/floating_modules.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/lume_icon.dart';
import 'dock_liquid_lens.dart';
import 'dock_liquid_surface.dart';
import 'dock_native_glass.dart';

class DockSearchButton extends StatefulWidget {
  const DockSearchButton({
    super.key,
    this.press,
    this.onPressChanged,
    required this.size,
    required this.appearance,
    required this.onPressed,
    required this.beside,
  });
  final double? press;
  final ValueChanged<bool>? onPressChanged;
  final double size;
  final DockAppearance appearance;
  final VoidCallback? onPressed;
  final bool beside;
  @override
  State<DockSearchButton> createState() => _DockSearchButtonState();
}

class _DockSearchButtonState extends State<DockSearchButton> {
  bool _pressed = false;
  final _surfaceKey = GlobalKey();
  Offset _origin() {
    final box = _surfaceKey.currentContext?.findRenderObject();
    return box is RenderBox ? box.localToGlobal(Offset.zero) : Offset.zero;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: FloatingModules.instance,
    builder: (context, _) => _surface(context),
  );

  void _pressChanged(bool value) {
    widget.onPressChanged?.call(value);
    setState(() => _pressed = value);
  }

  Widget _surface(BuildContext context) {
    final liquid = widget.appearance.liquid;
    final baseStyle = FloatingModules.instance.style(FloatingModule.dock);
    final style = baseStyle.copyWith(
      opacity: (baseStyle.opacity * widget.appearance.searchOpacity).clamp(
        0.0,
        1.0,
      ),
      blur: (baseStyle.blur * widget.appearance.searchBlur).clamp(0.0, 60.0),
    );
    final dark = Theme.of(context).brightness == Brightness.dark;
    final glassColor = dark ? LumeTheme.glass : Colors.white;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final animate =
        widget.appearance.animateSelection &&
        !reduced &&
        widget.appearance.searchLiquid;
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
        final press = (animate ? widget.press ?? value : 0.0).clamp(0.0, 1.0);
        final size = widget.size;
        return Transform.scale(
          scale: widget.press != null
              ? 1
              : 1 + press * liquid.value(DockLiquidParameter.pressScale),
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              key: _surfaceKey,
              fit: StackFit.expand,
              children: [
                if (native)
                  DockNativeGlass(
                    borderRadius: BorderRadius.circular(size / 2),
                    cornerRadius: size / 2,
                    style: liquid.nativeGlassStyle,
                    reduceTransparency: MediaQuery.highContrastOf(context),
                    tintColor: glassColor,
                    tintOpacity:
                        (liquid.value(DockLiquidParameter.nativeTint) *
                                widget.appearance.searchOpacity)
                            .clamp(0.0, .75),
                  ),
                if (!native)
                  DockLiquidSurface(
                    filterKey: const ValueKey('browse-search-surface'),
                    borderRadius: BorderRadius.circular(size / 2),
                    blurSigma: style.blur,
                    fallbackSigma:
                        style.blur *
                        (1 -
                            press *
                                liquid.value(
                                  DockLiquidParameter.blurReduction,
                                )),
                    fallbackChild: DecoratedBox(
                      decoration: BoxDecoration(
                        color: glassColor.withValues(alpha: style.opacity),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: (dark ? Colors.white : const Color(0xFF6E6E73))
                              .withValues(
                                alpha:
                                    widget.appearance.borderOpacity *
                                    (dark ? 1 : .28),
                              ),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(alpha: style.opacity * .35),
                            glassColor.withValues(alpha: style.opacity * .1),
                          ],
                        ),
                      ),
                    ),
                    lensRect: Rect.fromLTWH(0, 0, size, size),
                    lensRadius: size / 2,
                    lensScale:
                        1 +
                        press * liquid.value(DockLiquidParameter.pressScale),
                    feather:
                        size * liquid.value(DockLiquidParameter.clarityFeather),
                    clarity: liquid.enabled(DockLiquidEffect.clarity)
                        ? press *
                              liquid.value(DockLiquidParameter.blurReduction)
                        : 0,
                    coreAlpha: liquid.value(DockLiquidParameter.coreAlpha),
                    backgroundAdapt: liquid.value(
                      DockLiquidParameter.backgroundAdapt,
                    ),
                    tintColor: glassColor,
                    tintOpacity: style.opacity,
                    pixelRatio: MediaQuery.devicePixelRatioOf(context),
                    stageOrigin: _origin,
                  ),
                Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  child: Listener(
                    onPointerDown: widget.onPressed == null
                        ? null
                        : (_) => _pressChanged(true),
                    onPointerUp: (_) => _pressChanged(false),
                    onPointerCancel: (_) => _pressChanged(false),
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
                        size: (size * widget.appearance.searchIconScale).clamp(
                          16,
                          64,
                        ),
                      ),
                    ),
                  ),
                ),
                if (!native &&
                    widget.appearance.searchLiquid &&
                    liquid.enabled(DockLiquidEffect.optics))
                  DockLiquidLens(
                    path: Path()..addOval(Rect.fromLTWH(0, 0, size, size)),
                    press: press,
                    stretch: 0,
                    highlight: press,
                    refraction: liquid.value(DockLiquidParameter.refraction),
                    dispersion: liquid.value(DockLiquidParameter.dispersion),
                    glow: liquid.value(DockLiquidParameter.lensGlow),
                    desaturate: liquid.value(
                      DockLiquidParameter.lensDesaturate,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
