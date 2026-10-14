import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/source_playback.dart';

/// 「条目 / 章节内容 → 可播放地址」的判定（视频板块首页起播的前置规则）。
///
/// 关键约束：**纯 id 不能被当成本地文件**——否则脚本缺方法会被误报成
/// 「文件不存在」，用户就更不知道自己该改哪里了。
void main() {
  group('条目地址判定', () {
    test('网络与流媒体协议按原样收下（http 升 https，见 ATS 那条）', () {
      for (final url in <String>[
        'https://example.com/demo.mp4',
        'rtmp://example.com/live/stream',
        'rtsp://example.com/cam',
      ]) {
        expect(SourcePlayback.directAddress(url)?.toString(), url);
      }
      // iOS 的 ATS 拦明文加载：域名地址统一升到 https；IP / localhost 不动。
      expect(
        SourcePlayback.directAddress('http://example.com/live.m3u8')?.toString(),
        'https://example.com/live.m3u8',
      );
      expect(
        SourcePlayback.directAddress('http://192.168.1.9/live.m3u8')?.toString(),
        'http://192.168.1.9/live.m3u8',
      );
      expect(
        SourcePlayback.directAddress('http://localhost:8080/a.mp4')?.toString(),
        'http://localhost:8080/a.mp4',
      );
    });

    test('纯 id / 关键词不是地址', () {
      for (final value in <String>[
        '12345',
        'movie-1',
        '',
        '  ',
        'javascript:alert(1)',
        'magnet:?xt=urn:btih:abc',
      ]) {
        expect(
          SourcePlayback.directAddress(value),
          isNull,
          reason: '「$value」不该被当成本地文件或播放地址',
        );
      }
      expect(SourcePlayback.directAddress(null), isNull);
    });

    test('绝对路径按本地文件处理（POSIX 与 Windows 两种写法）', () {
      expect(
        SourcePlayback.directAddress('/var/mobile/Media/a.mp4')?.scheme,
        'file',
      );
      expect(
        SourcePlayback.directAddress(r'D:\media\a.mp4')?.scheme,
        'file',
      );
      expect(SourcePlayback.directAddress('a.mp4'), isNull, reason: '相对路径不认');
    });
  });

  group('章节内容地址判定', () {
    test('只有视频载荷可播放', () {
      expect(
        SourcePlayback.contentAddress(
          VideoContent(url: Uri.parse('https://example.com/e1.mp4')),
        )?.toString(),
        'https://example.com/e1.mp4',
      );
      expect(
        SourcePlayback.contentAddress(
          VideoContent(url: Uri.parse('http://cdn.example/e1.mp4')),
        )?.toString(),
        'https://cdn.example/e1.mp4',
        reason: '媒体地址同样升级到 https（iOS ATS 会拦明文）',
      );
      expect(SourcePlayback.contentAddress(const TextContent('正文')), isNull);
      expect(
        SourcePlayback.contentAddress(
          const ImageContent(<String>['https://example.com/1.jpg']),
        ),
        isNull,
      );
      expect(SourcePlayback.contentAddress(null), isNull);
    });
  });

  group('站内路径不能被当成本地文件（真机 -17913 的根因）', () {
    test('图源条目 id 的形状：/watch?v=、/9434719.html、/album/1、/book/1248', () {
      // 这些 id 全是「以 / 开头」的站内路径，早先一律被 Uri.file 吃掉，
      // 起播变成打开不存在的 file://（H動漫網 -17913 + 报错里没有域名）。
      for (final id in <String>[
        '/watch?v=123',
        '/9434719.html',
        '/album/1',
        '/book/1248',
        '/comic-lists/all/ob/time/st/all',
      ]) {
        expect(
          SourcePlayback.directAddress(id),
          isNull,
          reason: '「$id」是站内路径：交给 chapters/content 链路取地址',
        );
      }
    });

    test('真本地媒体路径照旧认（带媒体后缀才认）', () {
      expect(
        SourcePlayback.directAddress('/var/mobile/Media/a.mp4')?.scheme,
        'file',
      );
      expect(SourcePlayback.directAddress('/tmp/剧集01.mkv')?.scheme, 'file');
      expect(SourcePlayback.directAddress('/tmp/a.m3u8')?.scheme, 'file');
      expect(SourcePlayback.directAddress(r'D:\media.mp4')?.scheme, 'file');
      // file:// 走 scheme 白名单，与后缀无关。
      expect(
        SourcePlayback.directAddress('file:///var/mobile/a.bin')?.scheme,
        'file',
      );
    });
  });

  group('播放请求头：线路没写就继承主 headers（Hanime1 裸奔回归）', () {
    test('qualities 只有 label+url 时，Referer / UA 不能丢', () {
      final content = VideoContent(
        url: Uri.parse('https://cdn.example/e1.mp4'),
        headers: const <String, String>{
          'User-Agent': 'site-ua',
          'Referer': 'https://site.example/watch?v=1',
        },
        qualities: <VideoQuality>[
          VideoQuality(label: '原画', url: Uri.parse('https://cdn.example/e1.mp4')),
          VideoQuality(label: '720p', url: Uri.parse('https://cdn.example/720.mp4')),
        ],
      );
      final headers = SourcePlayback.contentHeaders(content);
      expect(headers['Referer'], 'https://site.example/watch?v=1');
      expect(headers['User-Agent'], 'site-ua');
      // 逐线路同样继承（切线路不该把请求头切没）。
      for (final quality in SourcePlayback.contentQualities(content)) {
        expect(quality.headers['Referer'], 'https://site.example/watch?v=1');
      }
    });

    test('线路自己写了 headers 时用它自己的', () {
      final content = VideoContent(
        url: Uri.parse('https://cdn.example/e1.mp4'),
        headers: const <String, String>{'Referer': 'https://site.example/'},
        qualities: <VideoQuality>[
          VideoQuality(
            label: '1080p',
            url: Uri.parse('https://cdn.example/1080.mp4'),
            headers: const <String, String>{'Referer': 'https://cdn2.example/'},
          ),
        ],
      );
      expect(
        SourcePlayback.contentHeaders(content)['Referer'],
        'https://cdn2.example/',
      );
    });
  });
}
