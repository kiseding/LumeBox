import 'dart:ui' as ui;

import 'package:flutter/rendering.dart'
    show ImageFilterConfig, ImageFilterContext;
import 'package:flutter/widgets.dart';

/// A rounded-rectangle optical layer behind the reader controls. Each surface
/// owns its shader; paint-time bounds keep nested sheets and DPR aligned.
class ComicGlassBackdrop extends StatefulWidget {
  const ComicGlassBackdrop({
    super.key,
    required this.radius,
    required this.child,
  });
  final double radius;
  final Widget child;
  @override
  State<ComicGlassBackdrop> createState() => _ComicGlassBackdropState();
}

class _ComicGlassBackdropState extends State<ComicGlassBackdrop> {
  static ui.FragmentProgram? _program;
  ui.FragmentShader? _shader;
  @override
  void initState() {
    super.initState();
    if (ui.ImageFilter.isShaderFilterSupported) _load();
  }

  Future<void> _load() async {
    try {
      final program = _program ??= await ui.FragmentProgram.fromAsset(
        'assets/shaders/comic_glass.frag',
      );
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // Older renderers and resource pressure retain the readable blur surface.
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    return BackdropFilter(
      key: const Key('comic.glass.backdrop'),
      filterConfig: shader != null && ui.ImageFilter.isShaderFilterSupported
          ? _GlassFilter(
              shader,
              widget.radius,
              MediaQuery.devicePixelRatioOf(context),
            )
          : ImageFilterConfig.blur(sigmaX: 12, sigmaY: 12),
      child: widget.child,
    );
  }
}

class _GlassFilter implements ImageFilterConfig {
  const _GlassFilter(this.shader, this.radius, this.pixelRatio);
  final ui.FragmentShader shader;
  final double radius, pixelRatio;
  @override
  String get debugShortDescription => 'comicGlassShader';
  @override
  ui.ImageFilter get filter => ui.ImageFilter.compose(
    outer: ui.ImageFilter.shader(shader),
    inner: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
  );
  @override
  ui.ImageFilter resolve(ImageFilterContext context) {
    final bounds = context.bounds;
    shader
      ..setFloat(2, bounds.left * pixelRatio)
      ..setFloat(3, bounds.top * pixelRatio)
      ..setFloat(4, bounds.width * pixelRatio)
      ..setFloat(5, bounds.height * pixelRatio)
      ..setFloat(6, radius * pixelRatio)
      ..setFloat(7, .10);
    return filter;
  }
}
