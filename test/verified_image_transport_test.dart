
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/ios_image_network.dart';
import 'package:lume_box/core/net/network_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('已验证图片CF转入WebKit，保持二进制响应且不复制请求Cookie', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('lumebox/image_network'),
      (_) async => {
        'status': 403,
        'body': Uint8List.fromList('<title>Just a moment</title>'.codeUnits),
        'headers': <String, String>{},
      },
    );
    late MethodCall browserCall;
    messenger.setMockMethodCallHandler(const MethodChannel('lumebox/webview'), (
      call,
    ) async {
      browserCall = call;
      return {
        'status': 200,
        'body': Uint8List.fromList([0, 255, 128, 1]),
        'contentType': 'image/webp',
      };
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel('lumebox/image_network'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('lumebox/webview'),
        null,
      );
    });
    final response = await IosImageNetwork.send(
      const NetworkRequest(
        url: 'https://images.example/a.webp',
        source: '封面:comic:test',
        reuseVerifiedSession: true,
        headers: {'User-Agent': 'verified-UA', 'Cookie': 'source-private=1'},
      ),
    );
    expect(response.body, [0, 255, 128, 1]);
    expect(browserCall.method, 'readVerifiedImage');
    expect(browserCall.arguments, {
      'url': 'https://images.example/a.webp',
      'userAgent': 'verified-UA',
    });
  });
}
