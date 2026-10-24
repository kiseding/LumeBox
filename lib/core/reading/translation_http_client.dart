import 'package:http/http.dart' as http;

import '../net/lume_http.dart';
import '../net/lume_net.dart';

/// Translation follows the same proxy/VPN route and cancellation as sources.
/// iOS requests use URLSession, so the Files/browser and App share one route.
class TranslationHttpClient extends http.BaseClient {
  TranslationHttpClient({
    LumeHttp? network,
    this.timeout = const Duration(seconds: 60),
    this.maxBytes = 2 * 1024 * 1024,
  }) : network =
           network ?? LumeHttp(source: '漫画翻译', settings: LumeNet.settings);
  final LumeHttp network;
  final Duration timeout;
  final int maxBytes;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final response = await network.sendBytes(
      url: request.url.toString(),
      method: request.method,
      headers: request.headers,
      bodyBytes: bytes,
      followRedirects: false,
      timeout: timeout,
      maxBytes: maxBytes,
    );
    return http.StreamedResponse(
      Stream.value(response.body),
      response.statusCode,
      headers: response.headers,
      contentLength: response.body.length,
      request: request,
    );
  }

  @override
  void close() => network.dispose();
}
