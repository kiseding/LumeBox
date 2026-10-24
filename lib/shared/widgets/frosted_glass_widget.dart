import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import '../../core/theme/frosted_settings.dart';
import '../../features/shell/dock_liquid_lens.dart';
import '../../features/shell/dock_native_glass.dart';
import '../../core/shell/dock_liquid_settings.dart';
import 'module_glass_scope.dart';

/// Shared material for cards, navigation and overlays; media content stays intact.
class FrostedGlassWidget extends StatefulWidget {
  const FrostedGlassWidget({
    super.key,
    this.blur = 18,
    this.opacity = .72,
    this.radius = 20,
    this.border = true,
    this.color,
    this.part,
    this.interactive = false,
    this.nativeGlass = false,
    this.nativeStyle,
    required this.child,
  });
  final double blur, opacity, radius;
  final bool border, interactive;

  /// Opt in only for a small number of overlay surfaces, never list cards.
  final bool nativeGlass;
  final DockNativeGlassStyle? nativeStyle;
  final Color? color;
  final GlassPart? part;
  final Widget child;
  @override
  State<FrostedGlassWidget> createState() => _FrostedGlassWidgetState();
}

class _FrostedGlassWidgetState extends State<FrostedGlassWidget> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: FrostedSettings.instance,
    builder: (context, _) {
      final settings = FrostedSettings.instance;
      final style = settings.style(
        ModuleGlassScope.moduleOf(context),
        widget.part ?? ModuleGlassScope.partOf(context),
      );
      final enabled =
          settings.frostedEnabled &&
          style.enabled &&
          !settings.reduceTransparency &&
          !MediaQuery.highContrastOf(context);
      final motion =
          enabled &&
          style.motion &&
          !MediaQuery.disableAnimationsOf(context) &&
          widget.interactive;
      final radius =
          widget.radius *
          (DockNativeGlass.supported && widget.nativeGlass
              ? settings.native.radiusScale
              : style.value(GlassParameter.radius));
      final corners = BorderRadius.circular(radius);
      if (DockNativeGlass.supported && !widget.nativeGlass) {
        // Ordinary scrolling content stays in Flutter's single render tree.
        // Do not create a platform view, blur pass or optical animation per card.
        return Material(
          color: widget.color ?? LumeTheme.surface,
          borderRadius: corners,
          clipBehavior: Clip.antiAlias,
          child: widget.child,
        );
      }
      if (DockNativeGlass.supported && widget.nativeGlass) {
        return ClipRRect(
          borderRadius: corners,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(
                child: DockNativeGlass(
                  borderRadius: corners,
                  cornerRadius: radius,
                  style:
                      widget.nativeStyle ??
                      (settings.native.clear
                          ? DockNativeGlassStyle.thin
                          : DockNativeGlassStyle.regular),
                  tintColor: Color(settings.native.tint),
                  tintOpacity: settings.native.tintOpacity,
                  reduceTransparency: MediaQuery.highContrastOf(context),
                ),
              ),
              Material(type: MaterialType.transparency, child: widget.child),
            ],
          ),
        );
      }
      final base = widget.color ?? LumeTheme.surface;
      final tint = Color.lerp(
        base,
        LumeTheme.accent,
        style.value(GlassParameter.tint),
      )!;
      final alpha = (widget.opacity * style.value(GlassParameter.opacity) / .68)
          .clamp(.08, 1.0);
      final fill = enabled
          ? tint.withValues(alpha: alpha)
          : base.withValues(alpha: 1);
      final saturation = style.value(GlassParameter.saturation);
      final inv = 1 - saturation;
      final filter = ui.ImageFilter.compose(
        outer: ui.ColorFilter.matrix([
          .213 * inv + saturation,
          .715 * inv,
          .072 * inv,
          0,
          0,
          .213 * inv,
          .715 * inv + saturation,
          .072 * inv,
          0,
          0,
          .213 * inv,
          .715 * inv,
          .072 * inv + saturation,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]),
        inner: ui.ImageFilter.blur(
          sigmaX: style.value(GlassParameter.blur),
          sigmaY: style.value(GlassParameter.blur),
        ),
      );
      Widget background = ColoredBox(color: fill);
      if (enabled && widget.blur > 0) {
        background = BackdropFilter(filter: filter, child: background);
      }
      return Listener(
        onPointerDown: motion ? (_) => setState(() => _pressed = true) : null,
        onPointerUp: motion ? (_) => setState(() => _pressed = false) : null,
        onPointerCancel: motion
            ? (_) => setState(() => _pressed = false)
            : null,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: motion && _pressed ? 1 : 0),
          duration: Duration(
            milliseconds: motion
                ? style.value(GlassParameter.duration).round()
                : 0,
          ),
          curve: Curves.easeOutCubic,
          builder: (context, press, _) => Transform.scale(
            scale: 1 - press * style.value(GlassParameter.pressScale),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: corners,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: enabled
                          ? style.value(GlassParameter.shadow)
                          : .035,
                    ),
                    blurRadius: style.value(GlassParameter.shadowBlur),
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: corners,
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    Positioned.fill(child: background),
                    if (enabled)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: corners,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.white.withValues(
                                    alpha: style.value(
                                      GlassParameter.highlight,
                                    ),
                                  ),
                                  Colors.white.withValues(alpha: 0),
                                ],
                              ),
                              border:
                                  widget.border &&
                                      style.value(GlassParameter.borderWidth) >
                                          0
                                  ? Border.all(
                                      color: Colors.white.withValues(
                                        alpha: style.value(
                                          GlassParameter.border,
                                        ),
                                      ),
                                      width: style.value(
                                        GlassParameter.borderWidth,
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    if (enabled &&
                        press > .001 &&
                        style.value(GlassParameter.refraction) > 0)
                      Positioned.fill(
                        child: LayoutBuilder(
                          builder: (context, c) => DockLiquidLens(
                            path: Path()
                              ..addRRect(
                                RRect.fromRectAndRadius(
                                  Offset.zero & c.biggest,
                                  Radius.circular(radius),
                                ),
                              ),
                            press: press,
                            stretch: 0,
                            highlight: style.value(GlassParameter.highlight),
                            refraction: style.value(GlassParameter.refraction),
                            dispersion: style.value(GlassParameter.dispersion),
                          ),
                        ),
                      ),
                    Material(
                      type: MaterialType.transparency,
                      child: widget.child,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
