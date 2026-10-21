import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:pointycastle/export.dart';
import 'package:pointycastle/asn1.dart';

/// Binary inputs/outputs are base64; strings are UTF-8 unless noted.
class SourceTools {
  static Object run(Map<String, dynamic> p) {
    final operation = p['operation'];
    final data = '${p['data'] ?? ''}';
    if (data.length > 12 * 1024 * 1024) throw const FormatException('工具输入过大');
    Uint8List binary(String field) => base64Decode('${p[field] ?? ''}');
    switch (operation) {
      case 'digest':
        final algorithm = <String, hash.Hash>{
          'md5': hash.md5,
          'sha1': hash.sha1,
          'sha224': hash.sha224,
          'sha256': hash.sha256,
          'sha384': hash.sha384,
          'sha512': hash.sha512,
        }['${p['algorithm']}'.toLowerCase()];
        if (algorithm == null) throw const FormatException('摘要算法无效');
        return algorithm
            .convert(
              p['encoding'] == 'base64' ? binary('data') : utf8.encode(data),
            )
            .toString();
      case 'base64Encode':
        return base64Encode(utf8.encode(data));
      case 'base64Decode':
        return utf8.decode(base64Decode(data));
      case 'urlEncode':
        return Uri.encodeComponent(data);
      case 'urlDecode':
        return Uri.decodeComponent(data);
      case 'inflate':
        final sink = _BoundedSink();
        final decoder = ZLibDecoder(raw: p['raw'] == true)
            .startChunkedConversion(sink);
        decoder.add(binary('data'));
        decoder.close();
        return base64Encode(sink.bytes.takeBytes());
      case 'aes':
        final key = binary('key');
        final iv = binary('iv');
        if (![16, 24, 32].contains(key.length))
          throw const FormatException('AES 密钥长度无效');
        final cbc = (p['mode'] ?? 'CBC') == 'CBC';
        if (!cbc && p['mode'] != 'ECB')
          throw const FormatException('AES 工具支持 CBC/ECB');
        if (cbc && iv.length != 16)
          throw const FormatException('AES IV 需要 16 字节');
        final cipher = cbc
            ? CBCBlockCipher(AESEngine())
            : ECBBlockCipher(AESEngine());
        final encrypt = p['encrypt'] == true;
        cipher.init(
          encrypt,
          cbc ? ParametersWithIV(KeyParameter(key), iv) : KeyParameter(key),
        );
        var input = binary('data');
        final padding = p['padding'] != 'none';
        if (encrypt && padding) {
          final count = 16 - input.length % 16;
          input = Uint8List.fromList([...input, ...List.filled(count, count)]);
        }
        if (input.isEmpty || input.length % 16 != 0)
          throw const FormatException('AES 数据块长度无效');
        var output = Uint8List(input.length);
        for (var i = 0; i < input.length; i += 16) {
          cipher.processBlock(input, i, output, i);
        }
        if (!encrypt && padding) {
          final count = output.last;
          if (count < 1 ||
              count > 16 ||
              output.skip(output.length - count).any((n) => n != count)) {
            throw const FormatException('AES PKCS7 填充无效');
          }
          output = Uint8List.sublistView(output, 0, output.length - count);
        }
        return base64Encode(output);
      case 'rsa':
        final pem = '${p['pem'] ?? ''}';
        if (pem.length > 16384) throw const FormatException('RSA 密钥过大');
        var node =
            ASN1Parser(
                  base64Decode(
                    pem.replaceAll(RegExp(r'-----[^-]+-----|\s'), ''),
                  ),
                ).nextObject()
                as ASN1Sequence;
        if (node.elements!.length == 2 && node.elements![1] is ASN1BitString) {
          node =
              ASN1Parser(
                    Uint8List.fromList(
                      (node.elements![1] as ASN1BitString).stringValues!,
                    ),
                  ).nextObject()
                  as ASN1Sequence;
        } else if (node.elements!.length >= 3 &&
            node.elements![2] is ASN1OctetString) {
          node =
              ASN1Parser(
                    Uint8List.fromList(
                      (node.elements![2] as ASN1OctetString).octets!,
                    ),
                  ).nextObject()
                  as ASN1Sequence;
        }
        BigInt number(int i) => (node.elements![i] as ASN1Integer).integer!;
        final private = node.elements!.length > 2;
        final n = number(private ? 1 : 0);
        if (n.bitLength < 1024 || n.bitLength > 4096)
          throw const FormatException('RSA 仅支持 1024–4096 位密钥');
        final encrypt = p['encrypt'] == true;
        final AsymmetricKey key = private
            ? RSAPrivateKey(n, number(3), number(4), number(5))
            : RSAPublicKey(n, number(1));
        final cipher = PKCS1Encoding(RSAEngine());
        final random = FortunaRandom()
          ..seed(
            KeyParameter(
              Uint8List.fromList(
                List.generate(32, (_) => Random.secure().nextInt(256)),
              ),
            ),
          );
        if (private) {
          cipher.init(
            encrypt,
            PrivateKeyParameter<RSAPrivateKey>(key as RSAPrivateKey),
          );
        } else {
          cipher.init(
            encrypt,
            ParametersWithRandom(
              PublicKeyParameter<RSAPublicKey>(key as RSAPublicKey),
              random,
            ),
          );
        }
        final input = binary('data');
        if (input.length > cipher.inputBlockSize)
          throw const FormatException('RSA 输入超过单块上限');
        return base64Encode(cipher.process(input));
      default:
        throw const FormatException('不支持的通用工具操作');
    }
  }
}

class _BoundedSink implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > 8 * 1024 * 1024)
      throw const FormatException('解压结果超过 8MB');
    bytes.add(chunk);
  }

  @override
  void close() {}
}
