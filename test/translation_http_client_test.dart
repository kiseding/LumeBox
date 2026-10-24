import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/reading/translation_http_client.dart';

void main() {
  test('translation uses source networking, preserves credentials/body and rejects redirects', () async {
    final transport = TranslationHttpClient(
      network: LumeHttp(
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.followRedirects, isFalse);
          expect(
            request.headers['authorization'],
            'Bearer private-example-key',
          );
          expect(request.body, '{"messages":[]}');
          return http.Response(
            '{"choices":[]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
    );
    addTearDown(transport.close);
    final request = http.Request('POST', Uri.parse('https://translation.test'))
      ..headers['Authorization'] = 'Bearer private-example-key'
      ..body = '{"messages":[]}';
    final result = await transport.send(request);
    expect(result.statusCode, 200);
    expect(await result.stream.bytesToString(), '{"choices":[]}');
  });
}
