import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../net/lume_http.dart';
import '../net/lume_net.dart';
import '../reading/reading.dart';
import 'web_home_sdk.dart';

typedef WebHomeAction = Future<void> Function(Map<String, dynamic> args);

/// Per-page loopback server. A random path and origin checks keep the bridge
/// off remote pages; requests never share another source's cookies or secrets.
class WebHomeBridge {
  WebHomeBridge({
    required this.sourceId,
    required this.library,
    required this.onPlay,
    required this.onPan,
    required this.onChrome,
    LumeHttp? http,
  }) : _http = http ?? LumeHttp(settings: LumeNet.settings, source: '网页主页');

  final String sourceId;
  final ReadingLibrary library;
  final WebHomeAction onPlay, onPan, onChrome;
  final LumeHttp _http;
  HttpServer? _server;
  late Uri _home;
  String get _cacheKey => 'video.web.cache.$sourceId';

  Future<Uri> start(String html) async {
    final random = Random.secure();
    final token = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _home = Uri.parse('http://127.0.0.1:${server.port}/$token/index.html');
    server.listen((request) => unawaited(_handle(request, html)));
    return _home;
  }

  String _document(String html) {
    final prefix = _home
        .resolve('.')
        .toString()
        .replaceFirst(RegExp(r'/$'), '');
    final storage = <String, dynamic>{};
    for (final entry in _readCache().entries) {
      try {
        final key = jsonDecode(entry.key);
        if (key is List && key.length == 2 && key.first == 'storage') {
          storage['${key.last}'] = entry.value;
        }
      } catch (_) {
        /* Ignore malformed entries in restored caches. */
      }
    }
    return injectWebHomeSdk(html, prefix, storage: storage);
  }

  Future<void> _handle(HttpRequest request, String html) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Referrer-Policy', 'no-referrer');
    try {
      final path = request.uri.path;
      final prefix = _home.resolve('.').path;
      final origin = request.headers.value('origin');
      if (request.headers.value('host') != _home.authority ||
          !path.startsWith(prefix) ||
          (origin != null && origin != _home.origin)) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (path == _home.path && request.method == 'GET') {
        response.headers.contentType = ContentType.html;
        response.headers.set(
          'Content-Security-Policy',
          "frame-ancestors 'none'",
        );
        response.write(_document(html));
      } else if (path == '${prefix}call' && request.method == 'POST') {
        final bytes = <int>[];
        await for (final chunk in request.timeout(
          const Duration(seconds: 15),
        )) {
          bytes.addAll(chunk);
          if (bytes.length > 1024 * 1024) {
            throw const FormatException('调用数据超过 1 MB');
          }
        }
        final message = jsonDecode(utf8.decode(bytes));
        if (message is! Map) throw const FormatException('无效的兼容接口请求');
        final value = await dispatch(
          '${message['method']}',
          _map(message['args']),
        );
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'ok': true, 'value': value}));
      } else if (path == '${prefix}res' && request.method == 'GET') {
        final args = _map(
          jsonDecode(request.uri.queryParameters['data'] ?? '{}'),
        );
        final upstream = await _request(args);
        response.statusCode = upstream.statusCode;
        final contentType = upstream.headers['content-type'];
        // Only passive images may be loaded through the resource endpoint.
        // Serving arbitrary HTML here would give a remote site the bridge origin.
        if (contentType == null ||
            !contentType.toLowerCase().startsWith('image/')) {
          response.statusCode = HttpStatus.unsupportedMediaType;
          return;
        }
        response.headers.set('Content-Type', contentType);
        response.headers.set(
          'Content-Security-Policy',
          "sandbox; default-src 'none'",
        );
        response.add(upstream.body);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
    } catch (failure) {
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'ok': false,
          'error': failure is FormatException
              ? failure.message
              : '网页请求或播放失败，请检查网络、源配置或重试',
        }),
      );
    } finally {
      try {
        await response.close();
      } catch (_) {
        /* Page already closed. */
      }
    }
  }

  Future<LumeHttpResponse> _request(Map<String, dynamic> args) {
    final url = '${args['url'] ?? ''}';
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('网页请求只支持 HTTP(S)');
    }
    final options = _map(args['options']);
    final seconds = (num.tryParse('${options['timeout']}') ?? 20)
        .clamp(1, 90)
        .toInt();
    return _http.send(
      url: url,
      method: '${options['method'] ?? 'GET'}',
      headers: stringHeaders(options['headers']),
      body: options['body'] == null
          ? null
          : options['body'] is String
          ? options['body'] as String
          : jsonEncode(options['body']),
      timeout: Duration(seconds: seconds),
      maxBytes: 8 * 1024 * 1024,
    );
  }

  Future<Object?> dispatch(String method, Map<String, dynamic> args) async {
    switch (method) {
      case 'req':
        try {
          final response = await _request(args);
          final options = _map(args['options']);
          return {
            'ok': response.statusCode >= 200 && response.statusCode < 300,
            'status': response.statusCode,
            'headers': response.headers,
            'url': response.url ?? args['url'],
            'body': options['responseType'] == 'json'
                ? jsonDecode(response.text)
                : response.text,
          };
        } catch (_) {
          return {
            'ok': false,
            'status': 0,
            'body': '',
            'error': '网页请求失败，请检查网络或站点地址',
          };
        }
      case 'cache.get':
      case 'cache.set':
      case 'cache.remove':
      case 'storage.set':
      case 'storage.remove':
      case 'storage.clear':
        final cache = _readCache();
        final key = jsonEncode(
          method.startsWith('storage.')
              ? ['storage', args['key'] ?? '']
              : ['cache', args['space'] ?? '', args['key'] ?? ''],
        );
        if (method == 'cache.get') return cache[key];
        if (method == 'cache.set' || method == 'storage.set') {
          cache[key] = args['value'];
        } else if (method == 'storage.clear') {
          cache.removeWhere((key, _) => key.startsWith('["storage",'));
        } else {
          cache.remove(key);
        }
        final encoded = jsonEncode(cache);
        if (utf8.encode(encoded).length > 1024 * 1024) {
          throw const FormatException('网页缓存已超过 1 MB');
        }
        library.setSetting(_cacheKey, encoded);
        return true;
      case 'play':
        await onPlay(args);
        return true;
      case 'pan.play':
        await onPan(args);
        return true;
      case 'ui.chrome':
        await onChrome(args);
        return true;
      default:
        throw const FormatException('不支持的网页兼容接口');
    }
  }

  Map<String, dynamic> _readCache() {
    try {
      return _map(jsonDecode(library.setting(_cacheKey) ?? '{}'));
    } catch (_) {
      return {};
    }
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? value.map((k, v) => MapEntry('$k', v)) : {};
  static Map<String, String> stringHeaders(Object? value) =>
      _map(value).map((k, v) => MapEntry(k, '$v'));

  Future<void> close() async {
    _http.dispose();
    await _server?.close(force: true);
    _server = null;
  }
}
