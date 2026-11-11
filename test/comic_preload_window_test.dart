import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/comic/comic_settings.dart';

/// 阅读器的前方预取现在由用户设置的「预加载半径」驱动（见
/// `ComicReaderPage._primeWindow`：窗口 page ± radius，预取 page ± 2 × radius）。
/// 这里锁住半径的取值范围，避免出现把整章排进解码队列的配置。
void main() {
  group('预加载半径范围', () {
    test('默认半径能覆盖一屏之后的翻页', () {
      expect(ComicReaderSettings.defaultPreloadRadius, 2);
    });

    test('半径上限受控，不会把整章排进预约队列', () {
      expect(ComicReaderSettings.maxPreloadRadius, lessThanOrEqualTo(5));
    });

    test('越界半径被夹回合法范围', () {
      const base = ComicReaderSettings();
      expect(base.copyWith(preloadRadius: 0).preloadRadius, 1);
      expect(
        base.copyWith(preloadRadius: 99).preloadRadius,
        ComicReaderSettings.maxPreloadRadius,
      );
    });
  });
}
