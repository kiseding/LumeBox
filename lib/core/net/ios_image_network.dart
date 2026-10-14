import 'package:flutter/services.dart';

import 'network_queue.dart';
import 'ios_verified_webview.dart';
import 'waf.dart';

class IosImageNetwork {
  static const channel = MethodChannel('lumebox/image_network');
  static Future<NetworkResponse> send(NetworkRequest request) async {
    final raw = await channel.invokeMapMethod<String, dynamic>('get', {
      'url': request.url,
      'headers': request.headers,
      'method': request.method,
      if (request.body != null) 'body': request.body,
      if (request.reuseVerifiedSession) 'reuseVerification': true,
      'timeoutSeconds':
          (request.timeout ?? const Duration(seconds: 15)).inMilliseconds /
          1000,
    });
    if (raw == null) throw StateError('图片网络未返回响应');
    final response = NetworkResponse(
      statusCode: raw['status'] as int,
      body: (raw['body'] as List).cast<int>(),
      headers: (raw['headers'] as Map).map(
        (key, value) => MapEntry('$key', '$value'),
      ),
    );
    if (request.reuseVerifiedSession &&
        (request.source.startsWith('封面:') ||
            request.source == '图片缓存' ||
            request.method == 'POST') &&
        WafDetector.isChallenge(
          statusCode: response.statusCode,
          headers: response.headers,
          body: String.fromCharCodes(response.body.take(16000)),
        )) {
      try {
        return await IosVerifiedWebView.readResource(request)
            .timeout(const Duration(seconds: 20));
      } catch (_) {
        // A still-blocked image remains a challenge; offer manual verification.
      }
    }
    return response;
  }
}
