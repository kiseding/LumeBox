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
