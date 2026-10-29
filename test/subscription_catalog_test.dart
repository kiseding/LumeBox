import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source_subscription_catalog.dart';

void main() {
  test('旧官方清单迁移，CDN 线路不会重新指回原站子清单', () {
    expect(
      SubscriptionCatalog.migrateUrl('${SubscriptionCatalog.base}all'),
      SubscriptionCatalog.totalUrl,
    );
    expect(
      SubscriptionCatalog.migrateUrl('${SubscriptionCatalog.cdnBase}all'),
      SubscriptionCatalog.totalCdnUrl,
    );
    expect(
      SubscriptionCatalog.canonical(
        '${SubscriptionCatalog.base}movies',
        Section.video,
      ),
      SubscriptionCatalog.sectionUrl(Section.video),
    );
    expect(
      SubscriptionCatalog.migrateUrl('${SubscriptionCatalog.cdnBase}videos'),
      SubscriptionCatalog.sectionUrl(Section.video, cdn: true),
    );
    expect(
      SubscriptionCatalog.migrateUrl('${SubscriptionCatalog.cdnBase}videos-hd'),
      '${SubscriptionCatalog.cdnBase}subscriptions/legacy/videos-hd-cdn.txt',
    );
    expect(
      SubscriptionCatalog.migrateUrl('${SubscriptionCatalog.base}video/播剧网.js'),
      '${SubscriptionCatalog.base}movie/播剧网.js',
    );
  });
  test('不改写自定义仓库、查询参数或无关的订阅', () {
    for (final url in [
      'https://private.test/all',
      'https://raw.githubusercontent.com/other/repo/main/all',
      '${SubscriptionCatalog.base}all?token=test',
      '${SubscriptionCatalog.base}subscriptions/photo.txt',
    ]) {
      expect(SubscriptionCatalog.migrateUrl(url), url);
    }
  });
  test('官方 CDN 旧清单地址转到 CDN 专用清单，不受旧 raw 清单缓存影响', () {
    for (final name in ['all.json', 'video.txt', 'movie.txt', 'photo.txt']) {
      expect(
        SubscriptionCatalog.migrateUrl(
          '${SubscriptionCatalog.cdnBase}subscriptions/$name',
        ),
        '${SubscriptionCatalog.cdnBase}subscriptions/cdn/$name',
      );
    }
    for (final suffix in ['?token=test', '#private']) {
      final url =
          '${SubscriptionCatalog.cdnBase}subscriptions/video.txt$suffix';
      expect(SubscriptionCatalog.migrateUrl(url), url);
    }
  });
}
