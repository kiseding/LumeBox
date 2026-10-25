import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/cover_palette.dart';

void main() {
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
