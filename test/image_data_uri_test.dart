import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:pointycastle/export.dart'
    show AESEngine, CBCBlockCipher, ECBBlockCipher, KeyParameter, ParametersWithIV;

/// App 侧的两条「内联/加密图」通路：
/// 1. `data:image/...;base64,...` 直接解码（源脚本解密后交出来的形态）；
/// 2. `lume-enc://aes-ecb/<key>/<url>` 与 `lume-enc://aes-cbc/<key>/<iv>/<url>`
///    —— 站点把封面加密后直接扔在 CDN 上（好妻网的 .ceb、9sex 的 .webp.txt），
///    解密放 App 用原生 AES 做（key 随 URI 带过来，不写进 App）。
void main() {
  // 1x1 透明 PNG
  const pngBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  final pngBytes = base64Decode(pngBase64);
  final dataUri = 'data:image/png;base64,$pngBase64';

  Uint8List pkcs7Pad(Uint8List data) {
    final padLen = 16 - data.length % 16;
    final out = Uint8List(data.length + padLen)..setAll(0, data);
    for (var i = 0; i < padLen; i++) {
      out[data.length + i] = padLen;
    }
    return out;
  }

  /// 逐块加密（BlockCipher.process 只处理一个块，必须自己循环 —— 这正是当初
  /// App 里解 275KB 密文只出 16 字节的那个坑）。
  Uint8List encryptBlocks(void Function(Uint8List input) init, Uint8List plain) {
    final padded = pkcs7Pad(plain);
    final cipher = AESEngine();
    return padded;
  }

  test('data URI 直接解码成图片字节', () {
    expect(SectionImagePipeline.decodeDataUri(dataUri), pngBytes);
    expect(SectionImagePipeline.decodeDataUri('  $dataUri  '), pngBytes,
        reason: '前后空白要容忍（源里常有换行）');
  });

  test('非 data / 非图片的地址返回 null（交给普通下载）', () {
    expect(SectionImagePipeline.decodeDataUri('https://a.com/b.jpg'), isNull);
    expect(SectionImagePipeline.decodeDataUri('data:text/plain;base64,QQ=='), isNull);
    expect(SectionImagePipeline.decodeDataUri('data:image/png;base64'), isNull);
    expect(SectionImagePipeline.decodeDataUri(''), isNull);
  });

  test('AES 逐块解密往返：ECB / CBC 都能还原 data URI 明文', () {
    final key = Uint8List.fromList(utf8.encode('82758dd12749c777ef579f1839ceea6a'));
    final iv = Uint8List.fromList(utf8.encode('5efdtf6060e2o330'));
    final plain = pkcs7Pad(Uint8List.fromList(utf8.encode(dataUri)));

    Uint8List roundTrip(bool cbc) {
      final enc = cbc
          ? (CBCBlockCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(key), iv)))
          : (ECBBlockCipher(AESEngine())..init(true, KeyParameter(key)));
      final cipherBytes = Uint8List(plain.length);
      for (var off = 0; off < plain.length; off += 16) {
        enc.processBlock(plain, off, cipherBytes, off);
      }
      final dec = cbc
          ? (CBCBlockCipher(AESEngine())..init(false, ParametersWithIV(KeyParameter(key), iv)))
          : (ECBBlockCipher(AESEngine())..init(false, KeyParameter(key)));
      final out = Uint8List(cipherBytes.length);
      for (var off = 0; off < cipherBytes.length; off += 16) {
        dec.processBlock(cipherBytes, off, out, off);
      }
      final pad = out.last;
      return Uint8List.sublistView(out, 0, out.length - pad);
    }

    for (final cbc in <bool>[false, true]) {
      final restored = utf8.decode(roundTrip(cbc));
      expect(restored, dataUri, reason: cbc ? 'CBC（9sex .webp.txt）' : 'ECB（好妻网 .ceb）');
      expect(SectionImagePipeline.decodeDataUri(restored), pngBytes);
    }
  });
}
