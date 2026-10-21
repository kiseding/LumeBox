import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../net/site_session_pool.dart';
import '../net/source_request_log.dart';

class SourceWebVerificationException implements Exception {
  @override
  String toString() => 'NEED_WEBVIEW_VERIFY：网页需要人工验证，请在网页视图完成后重试';
}

class SourceWebFailure extends StateError {
  SourceWebFailure(this.code, String message) : super('$code：$message');
  final String code;
}

/// Shared by JS and embedded Python. Native WebKit and SwiftSoup run on-device.
class SourceWebRuntime {
  SourceWebRuntime(this.scope);
  final String scope;
  static const channel = MethodChannel('lumebox/source_web');
  bool _disposed = false;
  final Set<String> _pending = {};
  static int _sequence = 0;
  static final Map<String, String> _retained = {};
  static Future<Map<String, dynamic>?> verifyRetained(String url) async {
    final id = _retained.remove(Uri.parse(url).host);
    if (id == null) return null;
    final reply = await channel
        .invokeMapMethod<String, dynamic>('verify', {'requestId': id})
        .timeout(const Duration(seconds: 185));
    if (reply?['verified'] == true) {
      SiteSessionPool.shared.rememberPage(
        url,
        userAgent: reply?['userAgent'] as String?,
      );
      await SiteSessionPool.shared.synchronize(url, {});
    }
    return reply;
  }

  Future<Object?> invoke(String method, Map<String, dynamic> payload) async {
    if (_disposed) throw StateError('源已释放');
    final id = '$scope:${_sequence++}';
    final args = Map<String, dynamic>.of(payload);
    if (method == 'render') {
      final url = Uri.tryParse('${args['url'] ?? ''}');
      if (url == null ||
          !['http', 'https'].contains(url.scheme) ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty) {
        throw const FormatException('网页地址必须是完整的 http(s) 地址');
      }
      final method = '${args['method'] ?? 'GET'}'.toUpperCase();
      if (!['GET', 'POST'].contains(method)) {
        throw const FormatException('网页导航只支持 GET／POST');
      }
      args['method'] = method;
      if (args['body'] != null &&
          (args['body'] is! String ||
              utf8.encode(args['body'] as String).length > 128 * 1024)) {
        throw const FormatException('网页表单正文无效或超过 128KB');
      }
      final timeout = args['timeoutMs'] ?? 6000;
      if (timeout is! num || !timeout.isFinite) {
        throw const FormatException('网页超时参数无效');
      }
      args['timeoutMs'] = timeout.round().clamp(100, 8000);
      for (final key in ['pageTimeoutMs', 'elementTimeoutMs', 'apiTimeoutMs']) {
        final value = args[key] ?? args['timeoutMs'];
        if (value is! num || !value.isFinite) throw FormatException('$key 无效');
        args[key] = value.round().clamp(100, args['timeoutMs'] as int);
      }
      final steps = args['steps'] ?? const [];
      if (steps is! List || steps.length > 16) {
        throw const FormatException('网页交互最多 16 步');
      }
      for (final step in steps) {
        if (step is! Map ||
            !['wait', 'click', 'fill', 'evaluate'].contains(step['type'])) {
          throw const FormatException('网页交互步骤类型无效');
        }
        if (step['type'] != 'evaluate' &&
            (step['selector'] is! String ||
                (step['selector'] as String).trim().isEmpty)) {
          throw const FormatException('网页交互步骤缺少 selector');
        }
      }
      args['steps'] = steps;
    } else if (method == 'extract') {
      if (args['html'] is! String ||
          utf8.encode(args['html'] as String).length > 2 * 1024 * 1024) {
        throw const FormatException('HTML 正文为空或超过 2MB');
      }
      final fields = args['fields'];
      if (fields is! Map || fields.isEmpty || fields.length > 32) {
        throw const FormatException('HTML 提取需要 1–32 个字段');
      }
      for (final field in fields.values) {
        if (field is! Map) throw const FormatException('HTML 字段规则必须是对象');
      }
    } else {
      throw const FormatException('不支持的网页宿主接口');
    }
    _pending.add(id);
    try {
      if (method == 'render') {
        final url = args['url'] as String;
        SourceRequestLog.record(scope, url);
        final headers = (args['headers'] as Map? ?? {}).map(
          (k, v) => MapEntry('$k', '$v'),
        );
        args['headers'] = await SiteSessionPool.shared.synchronize(
          url,
          headers,
        );
        args['userAgent'] =
            SiteSessionPool.shared.userAgentFor(url) ?? args['userAgent'];
        args['inspectable'] = SiteSessionPool.shared.inspectable;
      }
      final result = await channel
          .invokeMethod<Object?>(method, {...args, 'requestId': id})
          .timeout(
            Duration(
              milliseconds: method == 'render'
                  ? (args['timeoutMs'] as int) + 500
                  : 5000,
            ),
          );
      if (_disposed) throw StateError('源已释放');
      if (method == 'render' && result is Map) {
        if (result['requiresVerification'] == true) {
          throw SourceWebVerificationException();
        }
        if (result['status'] == 429) {
          throw SourceWebFailure('rate_limited', '网站请求过于频繁（HTTP 429），请稍后重试');
        }
        if (result['status'] == 401 || result['status'] == 403) {
          final blocked = RegExp(
            r'(error.?1020|ip (?:address )?(?:has been )?(?:banned|blocked))',
            caseSensitive: false,
          ).hasMatch('${result['html']}');
          throw SourceWebFailure(
            blocked ? 'ip_blocked' : 'http_${result['status']}',
            blocked ? '站点明确提示 IP 访问受限' : '网页拒绝访问，请检查登录或防盗链设置',
          );
        }
      }
      if ((method == 'render' &&
              (result is! Map || result['html'] is! String)) ||
          (method == 'extract' &&
              (result is! List || result.any((row) => row is! Map)))) {
        throw const FormatException('网页宿主返回格式无效');
      }
      if (method == 'render' && result is Map) {
        final url = '${result['url'] ?? args['url']}';
        SiteSessionPool.shared.rememberPage(
          url,
          userAgent: args['userAgent'] as String?,
        );
        await SiteSessionPool.shared.synchronize(url, {});
      }
      return result;
    } on PlatformException catch (error) {
      if (error.code == 'verification') {
        _retained.clear();
        _retained[Uri.parse(args['url'] as String).host] = id;
        throw SourceWebVerificationException();
      }
      rethrow;
    } on MissingPluginException {
      throw UnsupportedError('此能力需要包含 WebKit／SwiftSoup 的 iOS 安装包');
    } on TimeoutException {
      unawaited(_cancel(id));
      throw TimeoutException('网页操作超时');
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _cancel(String id) async {
    try {
      await channel.invokeMethod<void>('cancel', {'requestId': id});
    } catch (_) {}
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final id in _pending.toList()) {
      unawaited(_cancel(id));
    }
    _pending.clear();
  }
}
