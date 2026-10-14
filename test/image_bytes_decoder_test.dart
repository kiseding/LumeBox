import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/image_bytes_decoder.dart';

void main() {
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
