import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Dim the sampled poster tone into a neutral cinematic surface. Bright blue
/// scenery should not turn the entire synopsis and episode area blue.
Color? immersivePosterPageColor(
  List<(Color, int)> swatches, {
  Color? darkMuted,
  Color? dominant,
}) {
  final ranked = [...swatches]..sort((a, b) => b.$2.compareTo(a.$2));
  final chosen = darkMuted ?? dominant ?? ranked.firstOrNull?.$1;
  if (chosen == null) return null;
  final tone = HSLColor.fromColor(chosen);
  final tint = tone
      .withSaturation((tone.saturation * .25).clamp(0, .12))
      .withLightness(.14)
      .withAlpha(1)
      .toColor();
  return Color.alphaBlend(const Color(0xA624222C), tint);
}

/// Preserve the poster's hue in a quiet, readable page surface.
Color compactPosterPageColor(Color poster, {required Brightness brightness}) {
  final tone = HSLColor.fromColor(poster);
  final dark = brightness == Brightness.dark;
  return tone
      .withSaturation(
        (tone.saturation * (dark ? .35 : .42)).clamp(0, dark ? .24 : .30),
      )
      .withLightness(dark ? .14 : .87)
      .withAlpha(1)
      .toColor();
}

/// Fixed, bounded-resolution image layer. Blur the image alone, not the scrolling
/// controls above it; the repaint boundary can reuse it while content scrolls.
class DetailPosterBackground extends StatelessWidget {
  const DetailPosterBackground({
    super.key,
    required this.backdrop,
    required this.fallback,
    required this.tint,
    this.headers = const {},
  });

  final String? backdrop;
  final Widget fallback;
  final Color tint;
  final Map<String, String> headers;

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
                        headers: headers,
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
/// ShaderMask and exposes the page colour underneath the poster.
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
          stops: [0, .5, .78, .98],
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
