import 'dart:convert';

import 'package:flutter/services.dart';

import 'network_queue.dart';

/// Reuses WebKit's real browsing session after the user completed verification.
class IosVerifiedWebView {
  static const channel = MethodChannel('lumebox/webview');
  static Future<NetworkResponse> read(NetworkRequest request) async {
    final raw = await channel.invokeMapMethod<String, dynamic>(
      'readVerifiedPage',
      {'url': request.url, 'userAgent': request.headers['User-Agent']},
    );
    if (raw == null) throw StateError('网页会话没有返回正文');
    final body = utf8.encode(raw['body'] as String);
    if (body.length > (request.maxBytes ?? 10 * 1024 * 1024)) {
      throw StateError('网页正文超过读取上限');
    }
    return NetworkResponse(
      statusCode: raw['status'] as int,
      body: body,
      headers: {
        'content-type': '${raw['contentType'] ?? 'text/html'}; charset=utf-8',
      },
    );
  }
}
