import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/video/detail_poster_background.dart';

void main() {
  testWidgets('海报底部真正淡出到底图，而不是叠黑色蒙层', (tester) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: boundary,
            child: const SizedBox(
              width: 100,
              height: 100,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: Colors.blue),
                  DetailPosterFade(child: ColoredBox(color: Colors.red)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    late ui.Image image;
    ByteData? pixels;
    await tester.runAsync(() async {
      image = await render.toImage(pixelRatio: 1);
      pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    });
    final top = (10 * 100 + 50) * 4;
    final bottom = (99 * 100 + 50) * 4;
    expect(pixels!.getUint8(top), greaterThan(240));
    expect(pixels!.getUint8(bottom + 2), greaterThan(240));
    expect(pixels!.getUint8(bottom + 3), 255);
    image.dispose();
  });

  testWidgets('无 TMDB 背景图时展示源封面，模糊层隔离滚动重绘', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DetailPosterBackground(
          backdrop: null,
          fallback: ColoredBox(key: Key('source-cover'), color: Colors.red),
          tint: Color(0xff542424),
        ),
      ),
    );
    expect(find.byKey(const Key('source-cover')), findsOneWidget);
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
    final filter = find.byType(ImageFiltered);
    expect(
      find.ancestor(of: filter, matching: find.byType(RepaintBoundary)),
      findsWidgets,
    );
  });
}
