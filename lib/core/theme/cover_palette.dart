import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Quantized, saturation-weighted dominant color. White margins, transparent
/// pixels and near-black lettering do not overwhelm colored cover artwork.
Color? dominantCoverColor(Uint8List rgba) {
  final buckets = <int, List<double>>{};
  final count = rgba.length ~/ 4;
  final step = (count / 4096).ceil().clamp(1, 1000000);
  for (var pixel = 0; pixel < count; pixel += step) {
    final i = pixel * 4;
    if (rgba[i + 3] < 180) continue;
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    final color = Color.fromARGB(255, r, g, b);
    final hsv = HSVColor.fromColor(color);
    if (hsv.value < .12 || hsv.saturation < .12) continue;
    final bucket = ((r ~/ 32) << 6) | ((g ~/ 32) << 3) | (b ~/ 32);
    final values = buckets.putIfAbsent(bucket, () => [0, 0, 0, 0]);
    final weight = .5 + hsv.saturation;
    values[0] += weight;
    values[1] += r * weight;
    values[2] += g * weight;
    values[3] += b * weight;
  }
  if (buckets.isEmpty) return null;
  final best = buckets.values.reduce((a, b) => a[0] >= b[0] ? a : b);
  return Color.fromARGB(
    255,
    (best[1] / best[0]).round(),
    (best[2] / best[0]).round(),
    (best[3] / best[0]).round(),
  );
}

/// Pick a colored family from the lower artwork where the surface joins it.
/// Hue buckets combine differently lit clothing instead of letting a large,
/// low-saturation sky/background win a single RGB bucket.
Color? immersiveArtworkColor(
  Uint8List rgba, {
  required int width,
  required int height,
}) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
    return null;
  }
  final buckets = <int, List<double>>{};
  for (var y = 0; y < height; y++) {
    final position = y / height;
    final spatialWeight = .05 + position * position * position;
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      if (rgba[i + 3] < 180) continue;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      final hsv = HSVColor.fromColor(Color.fromARGB(255, r, g, b));
      if (hsv.saturation < .2 || hsv.value < .12) continue;
      final weight = hsv.saturation * hsv.saturation * spatialWeight;
      // Offset bins so reds on either side of zero share a family.
      final key = ((hsv.hue + 7.5) % 360 / 15).floor();
      final bucket = buckets.putIfAbsent(key, () => [0, 0, 0, 0]);
      bucket[0] += weight;
      bucket[1] += r * weight;
      bucket[2] += g * weight;
      bucket[3] += b * weight;
    }
  }
  if (buckets.isEmpty) return dominantCoverColor(rgba);
  final best = buckets.values.reduce((a, b) => a[0] >= b[0] ? a : b);
  return Color.fromARGB(
    255,
    (best[1] / best[0]).round(),
    (best[2] / best[0]).round(),
    (best[3] / best[0]).round(),
  );
}

/// Keep the displayed artwork's hue instead of blending every poster into grey-purple.
Color immersiveCoverSurface(Color artwork) {
  final hsv = HSVColor.fromColor(artwork);
  return hsv
      .withSaturation(hsv.saturation.clamp(.35, .72))
      .withValue((hsv.value * .65).clamp(.28, .38))
      .toColor();
}
