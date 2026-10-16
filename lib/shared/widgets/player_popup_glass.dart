import 'package:flutter/material.dart';

import '../../core/theme/glass_effects_settings.dart';
import 'frosted_glass_widget.dart';

/// Explicit integration point for a full player popup only, never the dock.
/// The original background stays in [legacy]; [child] must be popup content
/// without an opaque background so the new backdrop remains visible.
class PlayerPopupGlass extends StatelessWidget {
  const PlayerPopupGlass({
    super.key,
    required this.legacy,
    required this.child,
    this.area = GlassArea.fullPlayerPopup,
    this.blur = 18,
    this.opacity = .72,
    this.radius = 20,
  });

  final Widget legacy, child;
  final GlassArea area;
  final double blur, opacity, radius;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: GlassEffectsSettings.instance,
    builder: (context, _) {
      if (!GlassEffectsSettings.instance.active(area)) return legacy;
      final tune = GlassEffectsSettings.instance.tuning(area);
      return FrostedGlassWidget(
        blur: area == GlassArea.fullPlayerPopup ? blur : tune.blur,
        opacity: area == GlassArea.fullPlayerPopup ? opacity : tune.opacity,
        radius: area == GlassArea.fullPlayerPopup ? radius : tune.radius,
        border: tune.border,
        child: child,
      );
    },
  );
}
