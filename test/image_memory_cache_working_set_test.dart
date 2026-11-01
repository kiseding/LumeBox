import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/image_pipeline.dart';

/// 造一张纯色位图：尺寸决定它在缓存里记多少字节。
Future<ui.Image> _solid(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFF204060), BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

void main() {
  testWidgets('钉住与引用中的图算工作集，不占投机缓存预算', (tester) async {
    await tester.runAsync(() async {
      // 预算 <= 0 表示不限制，避免 put 时按预算淘汰干扰断言。
      final cache = ImageMemoryCache(0);
      addTearDown(cache.clear);
      const perImage = 10 * 10 * 4;

      cache.put('a', await _solid(10, 10));
      expect(cache.bytes, perImage);
      expect(cache.workingSetBytes, 0);
      expect(cache.speculativeBytes, perImage, reason: '没人用也没钉住，全是投机缓存');

      // 正在显示的图（有引用）：这部分是工作集。
      cache.acquire('a');
      expect(cache.workingSetBytes, perImage);
      expect(cache.speculativeBytes, 0);

      cache.put('b', await _solid(10, 10));
      expect(cache.bytes, perImage * 2);
      expect(cache.workingSetBytes, perImage);
      expect(cache.speculativeBytes, perImage, reason: '只有没人用的那张算缓存');

      // 松手后仍然钉在预加载窗口里：还是工作集，但不该计入缓存预算。
      cache.release('a');
      cache.retain(<String>{'a'});
      expect(cache.workingSetBytes, perImage, reason: '钉住等同工作集');
      expect(cache.speculativeBytes, perImage);

      // 窗口移走、解除钉住：重新变成可淘汰的投机缓存。
      cache.retain(const <String>{});
      expect(cache.workingSetBytes, 0);
      expect(cache.speculativeBytes, perImage * 2);
    });
  });
}
