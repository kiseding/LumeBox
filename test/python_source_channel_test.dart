import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/js/python_source_engine.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/source/source_package.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  Future<Map> host(Map<String, Object?> args) async {
    final reply = Completer<ByteData?>();
    // ignore: deprecated_member_use
    await messenger.handlePlatformMessage(
      PythonSourceEngine.channel.name,
      codec.encodeMethodCall(MethodCall('host', args)),
      reply.complete,
    );
    return jsonDecode(codec.decodeEnvelope((await reply.future)!)) as Map;
  }

  tearDown(
    () => messenger.setMockMethodCallHandler(PythonSourceEngine.channel, null),
  );

  test('Python HTTP 失败保留 TLS 分类和系统错误码，不泄露原始异常内容', () async {
    final errors = [
      PlatformException(
        code: 'network',
        message: 'https://private.invalid/?token=private-token',
        details: {
          'domain': 'NSURLErrorDomain',
          'code': -1200,
          'headers': {'Cookie': 'private-cookie'},
        },
      ),
      PlatformException(
        code: 'tls_handshake',
        message: 'private-token',
        details: {'domain': 'NSURLErrorDomain', 'code': -1200},
      ),
      PlatformException(
        code: 'certificate',
        message: 'private-token',
        details: {'domain': 'NSURLErrorDomain', 'code': -1202},
      ),
    ];
    for (var index = 0; index < errors.length; index++) {
      var requests = 0;
      final client = LumeHttp(
        client: MockClient((_) async {
          requests++;
          throw errors[index];
        }),
      );
      final engine = PythonSourceEngine(sourceId: 'tls-$index', http: client);
      final result = await host({
        'sourceId': 'tls-$index',
        'request': jsonEncode({
          'method': 'http',
          'payload': {'url': 'https://fixture.invalid/list', 'body': ''},
        }),
      });
      expect(result['ok'], isFalse);
      final message = result['error'] as String;
      expect(
        message,
        contains(
          index == 2 ? 'CERTIFICATE_VERIFY_FAILED' : 'TLS_HANDSHAKE_FAILED',
        ),
      );
      expect(message, contains(index == 2 ? '-1202' : '-1200'));
      expect(message, isNot(contains('private')));
      expect(message, isNot(contains('headers')));
      expect(requests, 1);
      engine.dispose();
      client.dispose();
    }
  });

  test('Python 网络桥保留二进制、请求头、重定向语义，并拒绝已释放来源', () async {
    late http.Request outgoing;
    final client = LumeHttp(
      client: MockClient((request) async {
        outgoing = request;
        return http.Response.bytes(
          [0, 255, 128],
          302,
          headers: {'Location': '/next'},
        );
      }),
    );
    final engine = PythonSourceEngine(sourceId: 'python-network', http: client);
    final args = <String, Object?>{
      'sourceId': 'python-network',
      'request': jsonEncode({
        'method': 'http',
        'timeout': 3,
        'payload': {
          'url': 'https://fixture.invalid/upload',
          'method': 'POST',
          'headers': {
            'Content-Type': 'application/octet-stream',
            'Referer': 'https://fixture.invalid/',
          },
          'body': base64Encode([0, 255, 1]),
        },
      }),
    };
    final reply = await host(args);
    expect(reply['ok'], isTrue, reason: '$reply');
    expect(outgoing.bodyBytes, [0, 255, 1]);
    expect(outgoing.followRedirects, isFalse);
    expect(outgoing.headers['Referer'], 'https://fixture.invalid/');
    expect(base64Decode(reply['value']['body']), [0, 255, 128]);
    expect(reply['value']['status'], 302);
    engine.dispose();
    expect((await host(args))['ok'], isFalse);
    client.dispose();
  });

  test('原生返回依赖说明能保留，超时后标记运行时需要重建', () async {
    final actions = <String>[];
    messenger.setMockMethodCallHandler(PythonSourceEngine.channel, (
      call,
    ) async {
      final args = call.arguments as Map;
      actions.add(args['action'] as String);
      if (args['action'] == 'load') {
        return jsonEncode({
          'ok': true,
          'value': {
            'methods': ['list', 'content'],
            'warnings': ['Android 专属路径需要外部后端'],
          },
        });
      }
      if (args['action'] == 'call') {
        return jsonEncode({
          'ok': false,
          'error': {'kind': 'timeout', 'message': '执行超时'},
        });
      }
      return '{"ok":true,"value":null}';
    });
    final client = LumeHttp();
    final engine = PythonSourceEngine(
      sourceId: 'python-lifecycle',
      http: client,
    );
    expect(
      await engine.loadScript(
        SourcePackage.prepare('class Spider:\n    pass\n', name: 'fixture.py'),
      ),
      isTrue,
    );
    expect(
      (await engine.metadata())!['compatibilityWarnings'],
      contains('Android 专属路径需要外部后端'),
    );
    expect((await engine.callResult('list')).isOk, isFalse);
    expect(engine.isPoisoned, isTrue);
    engine.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(actions.last, 'dispose');
    client.dispose();
  });
}
