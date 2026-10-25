import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Fixed, bounded-resolution image layer. Blur the image alone, not the scrolling
/// controls above it; the repaint boundary can reuse it while content scrolls.
class DetailPosterBackground extends StatelessWidget {
  const DetailPosterBackground({
    super.key,
    required this.backdrop,
    required this.fallback,
    required this.tint,
  });

  final String? backdrop;
  final Widget fallback;
  final Color tint;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Transform.scale(
                scale: 1.12,
                child: backdrop == null
                    ? fallback
                    : Image.network(
                        backdrop!,
                        cacheWidth: 384,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.low,
                        errorBuilder: (_, _, _) => fallback,
                      ),
              ),
            ),
            // Preserve image colour and texture instead of an opaque dark fill.
            ColoredBox(color: tint.withValues(alpha: .38)),
          ],
        ),
      ),
    ),
  );
}

/// Fade only the poster's alpha. A bounded saveLayer with dstIn avoids using
/// ShaderMask and exposes the actual blurred image underneath the poster.
class DetailPosterFade extends SingleChildRenderObjectWidget {
  const DetailPosterFade({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _PosterFadeRender();
}

class _PosterFadeRender extends RenderProxyBox {
  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || size.isEmpty) return;
    final rect = offset & size;
    final canvas = context.canvas;
    canvas.saveLayer(rect, Paint());
    super.paint(context, offset);
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0, .53, .76, 1],
          colors: [
            Colors.white,
            Colors.white,
            Color(0x9affffff),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
    canvas.restore();
  }
}
