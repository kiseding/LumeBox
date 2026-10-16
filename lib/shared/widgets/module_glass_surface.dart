import 'package:flutter/material.dart';

import '../../core/theme/glass_effects_settings.dart';
import 'frosted_glass_widget.dart';
import 'liquid_glass_widget.dart';
import 'module_glass_scope.dart';
export 'module_glass_scope.dart';
export '../../core/theme/glass_modules.dart';

/// Explicit opt-in adapter. Legacy subtree is returned verbatim while disabled.
class ModuleGlassSurface extends StatelessWidget {
  const ModuleGlassSurface({
    super.key,
    required this.legacy,
    required this.child,
    this.module,
    required this.part,
  });
  final Widget legacy, child;
  final GlassModule? module;
  final GlassPart part;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: GlassEffectsSettings.instance,
    builder: (context, _) {
      final settings = GlassEffectsSettings.instance;
      final tune = settings.moduleTuning(
        module ?? ModuleGlassScope.moduleOf(context),
        part,
      );
      if (!tune.enabled) return legacy;
      if (tune.liquid) {
        if (!settings.liquidEnabled || !part.allowsLiquid) return legacy;
        return LiquidGlassWidget(
          blur: tune.blur,
          opacity: tune.opacity,
          radius: tune.radius,
          highlight: tune.highlight,
          distort: tune.distort,
          speed: tune.speed,
          border: tune.border,
          child: child,
        );
      }
      if (!settings.frostedEnabled) return legacy;
      return FrostedGlassWidget(
        blur: tune.blur,
        opacity: tune.opacity,
        radius: tune.radius,
        border: tune.border,
        child: child,
      );
    },
  );
}
