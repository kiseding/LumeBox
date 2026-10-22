import '../player/abstract_player.dart';
import 'web_home_bridge.dart';

class WebHomePlayback {
  WebHomePlayback(Map<String, dynamic> args)
    : url = '${args['url'] ?? ''}'.trim(),
      title = '${args['title'] ?? ''}',
      headers = WebHomeBridge.stringHeaders(
        args['options'] is Map ? (args['options'] as Map)['headers'] : null,
      );

  final String url, title;
  final Map<String, String> headers;
  String get shareUrl => url.startsWith('push://') ? url.substring(7) : url;
  bool get isShare {
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    return url.startsWith('push://') ||
        uri?.scheme == 'magnet' ||
        const [
          'pan.quark.cn',
          'pan.baidu.com',
          'www.alipan.com',
          'www.aliyundrive.com',
          '115.com',
          '115cdn.com',
          '123pan.com',
          'www.123pan.com',
          'www.123684.com',
          'cloud.189.cn',
          'caiyun.139.com',
          'pan.xunlei.com',
          'drive.uc.cn',
        ].any((domain) => host == domain || host.endsWith('.$domain'));
  }

  PlayerMedia get media {
    final uri = Uri.tryParse(url);
    if (isShare ||
        uri == null ||
        !{'http', 'https', 'rtmp', 'rtmps', 'rtsp'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('网页没有返回可播放的媒体地址');
    }
    return PlayerMedia(uri: uri, title: title, headers: headers);
  }
}
