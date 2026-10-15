import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/image_bytes_decoder.dart';

void main() {
  const mh18Headers = {
    'X-Lume-Image-Encoding': 'aes-cbc-nopadding',
    'X-Lume-Image-Key': 'f5d965df75336270',
    'X-Lume-Image-IV': '97b60394abc2fbe1',
  };
  test('十八漫画公开阅读器 NoPadding 算法与独立 Node 密文一致', () {
    final bytes = base64Decode(
      '3eKMR0wnLS34vbK+a7RYO+Sg59cqbQxbd0uXTdOuo7uplj/lyzZAx8EnxO6OKvGXULd5QgLsvtunIt77KVDrX6XtBWyLMVxPoiTjER+LZ+I=',
    );
    final decoded = decodeSourceImage(bytes, mh18Headers);
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1sAAAAASUVORK5CYII=',
    );
    expect(decoded.take(png.length), png);
    expect(decoded.skip(png.length), everyElement(0));
  });
  test('十八漫画混合明文图片原样保留，不重复解密', () {
    for (final signature in [
      [0xff, 0xd8, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0, 0, 0, 0, 0],
      [0x47, 0x49, 0x46, 0x38, 0, 0, 0, 0, 0, 0, 0, 0],
      [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50],
    ]) {
      final bytes = Uint8List.fromList(signature);
      expect(identical(decodeSourceImage(bytes, mh18Headers), bytes), isTrue);
    }
  });
  test('NoPadding 不完整分组和错误解密内容明确失败', () {
    expect(
      () => decodeSourceImage(Uint8List(15), mh18Headers),
      throwsFormatException,
    );
    expect(
      () => decodeSourceImage(Uint8List(16), mh18Headers),
      throwsFormatException,
    );
  });
  test('corrupt encoded image bytes report a format failure', () {
    final bytes = base64Decode('2PYbUWttRSwkvhc43GjR7b0ZD9UVipvpW1dructvID0=');
    bytes[bytes.length - 1] ^= 1;
    expect(
      () => decodeSourceImage(bytes, const {
        'X-Lume-Image-Encoding': 'aes-cbc-pkcs7',
        'X-Lume-Image-Key': 'my2ecret782ecret',
        'X-Lume-Image-IV': 'my2ecret782ecret',
      }),
      throwsFormatException,
    );
  });
  test(
    'public reader AES-CBC bytes match an independent Node crypto fixture',
    () {
      final result = decodeSourceImage(
        base64Decode('2PYbUWttRSwkvhc43GjR7b0ZD9UVipvpW1dructvID0='),
        const {
          'X-Lume-Image-Encoding': 'aes-cbc-pkcs7',
          'X-Lume-Image-Key': 'my2ecret782ecret',
          'X-Lume-Image-IV': 'my2ecret782ecret',
        },
      );
      expect(utf8.decode(result), 'reader-image-fixture');
    },
  );
  test(
    'ordinary images pass through and invalid encrypted images are rejected',
    () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(identical(decodeSourceImage(bytes, const {}), bytes), isTrue);
      expect(
        () => decodeSourceImage(bytes, const {
          'X-Lume-Image-Encoding': 'aes-cbc-pkcs7',
          'X-Lume-Image-Key': 'short',
        }),
        throwsFormatException,
      );
    },
  );
}
