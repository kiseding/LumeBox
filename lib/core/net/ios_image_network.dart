import 'package:flutter/services.dart';

import 'network_queue.dart';

class IosImageNetwork {
  static const channel = MethodChannel('lumebox/image_network');
  static Future<NetworkResponse> send(NetworkRequest request) async {
    final raw = await channel.invokeMapMethod<String, dynamic>('get', {
      'url': request.url,
      'headers': request.headers,
      if (request.reuseVerifiedSession) 'reuseVerification': true,
      'timeoutSeconds':
          (request.timeout ?? const Duration(seconds: 15)).inMilliseconds /
          1000,
    });
    if (raw == null) throw StateError('图片网络未返回响应');
    return NetworkResponse(
      statusCode: raw['status'] as int,
      body: (raw['body'] as List).cast<int>(),
      headers: (raw['headers'] as Map).map(
        (key, value) => MapEntry('$key', '$value'),
      ),
    );
  }
}
