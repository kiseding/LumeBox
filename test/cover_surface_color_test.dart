import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/cover_palette.dart';

void main() {
  test('海报下半部的暖色服装优先于大面积低饱和天空', () {
    final rgba = Uint8List.fromList([
      for (var y = 0; y < 12; y++)
        for (var x = 0; x < 12; x++)
          ...y < 8 ? [140, 152, 175, 255] : [160, 40, 45, 255],
    ]);
    final color = immersiveArtworkColor(rgba, width: 12, height: 12)!;
    final hsv = HSVColor.fromColor(color);
    expect(hsv.hue > 340 || hsv.hue < 20, isTrue);
    expect(hsv.saturation, greaterThan(.6));
  });

  test('中性海报不捏造暖色，透明像素不参与取色', () {
    expect(
      immersiveArtworkColor(
        Uint8List.fromList([255, 0, 0, 0]),
        width: 1,
        height: 1,
      ),
      isNull,
    );
    expect(
      immersiveArtworkColor(
        Uint8List.fromList([255, 255, 255, 255]),
        width: 1,
        height: 1,
      ),
      isNull,
    );
  });

  test('沉浸详情底色保留海报色相，红色海报不会统一混成蓝灰色', () {
    for (final input in [Colors.red, Colors.pink, Colors.green, Colors.blue]) {
      final original = HSVColor.fromColor(input);
      final surface = HSVColor.fromColor(immersiveCoverSurface(input));
      expect(surface.hue, closeTo(original.hue, 1));
      expect(surface.saturation, greaterThanOrEqualTo(.21));
      expect(surface.value, inInclusiveRange(.27, .53));
    }
  });
}
