import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/glass_effects_settings.dart';

/// Manual opt-in for small buttons, toasts and badges ONLY. Never wrap a
/// navigation bar, list item, progress bar or dialog/sheet with this widget.
/// [child] is the complete existing UI, returned unchanged when disabled.
class LiquidGlassWidget extends StatelessWidget {
  const LiquidGlassWidget({
    super.key,
    this.blur = 8,
    this.highlight = .5,
    this.distort = .3,
    this.opacity = .12,
    this.radius = 20,
    required this.child,
  }) : assert(blur >= 0 && blur < double.infinity),
       assert(highlight >= 0 && highlight <= 1),
       assert(distort >= 0 && distort <= 1),
       assert(opacity >= 0 && opacity <= 1),
       assert(radius >= 0 && radius < double.infinity);

  final double blur, highlight, distort, opacity, radius;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: GlassEffectsSettings.instance,
    builder: (context, _) {
      // Do not even allocate a shader/ticker/clip when off. Unsupported
      // renderers also use the exact legacy UI instead of a weaker imitation.
      if (!GlassEffectsSettings.instance.liquidEnabled ||
          !ui.ImageFilter.isShaderFilterSupported) {
        return child;
      }
      return _LiquidSurface(options: this);
    },
  );
}

class _LiquidSurface extends StatefulWidget {
  const _LiquidSurface({required this.options});
  final LiquidGlassWidget options;

  @override
  State<_LiquidSurface> createState() => _LiquidSurfaceState();
}

class _LiquidSurfaceState extends State<_LiquidSurface>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram>? _program;
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program = await (_program ??= ui.FragmentProgram.fromAsset(
        'assets/shaders/liquid_glass.frag',
      ));
      if (mounted) setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // A missing shader is a legacy fallback, never a broken control.
      _program = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.stop();
    } else if (!_animation.isAnimating) {
      _animation.repeat();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    final options = widget.options;
    if (shader == null) return options.child;
    return AnimatedBuilder(
      animation: _animation,
      child: options.child,
      builder: (context, child) {
        shader
          ..setFloat(2, _animation.value * 6.283185307)
          ..setFloat(3, options.distort)
          ..setFloat(4, options.highlight);
        return ClipRRect(
          borderRadius: BorderRadius.circular(options.radius),
          child: BackdropFilter(
            filter: ui.ImageFilter.compose(
              outer: ui.ImageFilter.shader(shader),
              inner: ui.ImageFilter.blur(
                sigmaX: options.blur,
                sigmaY: options.blur,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface
                    .withValues(alpha: options.opacity),
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
