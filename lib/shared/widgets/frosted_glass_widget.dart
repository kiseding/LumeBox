import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Explicit opt-in static glass; independent of floating module settings.
class FrostedGlassWidget extends StatelessWidget {
  const FrostedGlassWidget({
    super.key,
    this.blur = 18,
    this.opacity = .72,
    this.radius = 20,
    this.border = true,
    required this.child,
  }) : assert(blur >= 0 && blur < double.infinity),
       assert(opacity >= 0 && opacity <= 1),
       assert(radius >= 0 && radius < double.infinity);

  final double blur, opacity, radius;
  final bool border;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface
              .withValues(alpha: opacity),
          borderRadius: BorderRadius.circular(radius),
          border: border
              ? Border.all(color: Colors.white.withValues(alpha: .24))
              : null,
        ),
        child: child,
      ),
    ),
  );
}
