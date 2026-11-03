import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/comic/comic_reader_page.dart';

void main() {
  group('前方预取按屏幕封顶', () {
    test('条漫：单张超过 1.5 屏时只取 1 张', () {
      // 视口 880，1.5 屏 = 1320；第一张 1400 跨过上限即停止。
      expect(
        comicPreloadAheadCount(const [1400, 1400, 1400, 1400, 1400], 880),
        1,
      );
    });

    test('单页漫画：仍按 1.5 屏限制预取范围', () {
      expect(
        comicPreloadAheadCount(const [400, 400, 400, 400, 400], 880),
        4,
      );
    });

    test('后面不足 5 张时按实际张数封顶', () {
      expect(comicPreloadAheadCount(const [400, 400], 880), 2);
    });

    test('视口高度未知时退回上限，而不是一张都不取', () {
      expect(comicPreloadAheadCount(const [400, 400, 400], 0), 3);
      expect(comicPreloadAheadCount(const [400, 400, 400], -1), 3);
    });

    test('已经是最后一张时返回 0', () {
      expect(comicPreloadAheadCount(const [], 880), 0);
    });

    test('单张超高图也至少取 1 张', () {
      expect(comicPreloadAheadCount(const [3000, 3000], 880), 1);
    });
  });
}
