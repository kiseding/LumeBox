import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/features/video/player_speed_meter.dart';

void main() {
  for (final status in [403, 404, 500]) {
    test('HTTP $status 的大响应不能显示测速成功', () async {
      final meter = PlaybackSpeedMeter(
        http: LumeHttp(client: MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return http.Response('x' * 16384, status);
        })),
      );
      addTearDown(meter.dispose);
      await meter.measure(Uri.parse('https://example.com/video'));
      expect(meter.failed.value, isTrue);
      expect(meter.kbps.value, isNull);
      expect(meter.busy.value, isFalse);
    });
  }

  test('200 HTML 验证页不能显示测速成功', () async {
    final meter = PlaybackSpeedMeter(
      http: LumeHttp(client: MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return http.Response('x' * 16384, 200,
            headers: {'Content-Type': 'text/html; charset=utf-8'});
      })),
    );
    addTearDown(meter.dispose);
    await meter.measure(Uri.parse('https://example.com/video'));
    expect(meter.failed.value, isTrue);
    expect(meter.kbps.value, isNull);
  });

  test('覆盖源的小写 Range，206 媒体响应仍显示真实读数', () async {
    final meter = PlaybackSpeedMeter(
      http: LumeHttp(client: MockClient((request) async {
        expect(request.headers['range'], 'bytes=0-262143');
        expect(request.headers['referer'], 'https://example.com/');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return http.Response('x' * 16384, 206,
            headers: {'Content-Type': 'video/mp4'});
      })),
    );
    addTearDown(meter.dispose);
    await meter.measure(Uri.parse('https://example.com/video'), headers: {
      'range': 'bytes=1000000-',
      'Referer': 'https://example.com/',
    });
    expect(meter.failed.value, isFalse);
    expect(meter.kbps.value, greaterThan(0));
  });
}
