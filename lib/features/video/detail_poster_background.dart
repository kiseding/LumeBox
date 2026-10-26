import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Keep the bottom poster's natural tone instead of forcing every image dark.
Color? immersivePosterPageColor(
  List<(Color, int)> swatches, {
  Color? darkMuted,
  Color? dominant,
}) {
  final colored = swatches.where((entry) {
    final tone = HSLColor.fromColor(entry.$1);
    return tone.saturation >= .32 &&
        tone.lightness >= .19 &&
        tone.lightness <= .6;
  }).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  final dominantTone = dominant == null ? null : HSLColor.fromColor(dominant);
  final chosen = dominantTone != null && dominantTone.lightness >= .24
      ? dominant
      : colored.firstOrNull?.$1 ?? darkMuted ?? dominant;
  if (chosen == null) return null;
  final tone = HSLColor.fromColor(chosen);
  var surface = tone
      .withSaturation(tone.saturation.clamp(0, .45))
      .withLightness(tone.lightness.clamp(.24, .48))
      .withAlpha(1);
  // White detail labels still need contrast on bright yellow/green posters.
  while (surface.toColor().computeLuminance() > .18) {
    surface = surface.withLightness(surface.lightness - .005);
  }
  return surface.toColor();
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
