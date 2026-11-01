import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/comic/comic_reader_page.dart';

void main() {
  group('前方预取按屏幕封顶', () {
    test('条漫：一张一屏半时只取 2 张', () {
      // 视口 880，2.5 屏 = 2200：第一张 1300 没到线，第二张 2600 到线即停。
      expect(
        comicPreloadAheadCount(const [1300, 1300, 1300, 1300, 1300], 880),
        2,
      );
    });

    test('单页漫画：一张半屏时仍按上限取 5 张', () {
      expect(
        comicPreloadAheadCount(const [400, 400, 400, 400, 400], 880),
        5,
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
