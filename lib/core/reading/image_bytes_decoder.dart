import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';

/// A source may describe its public reader's image encoding using local headers.
/// These fields are consumed locally and never sent to the image server.
Uint8List decodeSourceImage(Uint8List bytes, Map<String, String> headers) {
  String field(String name) =>
      headers.entries
          .where((entry) => entry.key.toLowerCase() == name)
          .map((entry) => entry.value)
          .firstOrNull ??
      '';
  final encoding = field('x-lume-image-encoding');
  if (encoding.isEmpty) return bytes;
  final noPadding = encoding == 'aes-cbc-nopadding';
  if (encoding != 'aes-cbc-pkcs7' && !noPadding) {
    throw const FormatException('Unsupported source image encoding');
  }
  // The public reader mixes encrypted business images with plain images.
  if (noPadding && _isPlainImage(bytes)) return bytes;
  final key = Uint8List.fromList(utf8.encode(field('x-lume-image-key')));
  final iv = Uint8List.fromList(utf8.encode(field('x-lume-image-iv')));
  if (!{16, 24, 32}.contains(key.length) ||
      iv.length != 16 ||
      bytes.isEmpty ||
      bytes.length % 16 != 0) {
    throw const FormatException('Invalid source image encoding parameters');
  }
  if (noPadding) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    final output = Uint8List(bytes.length);
    for (var offset = 0; offset < bytes.length; offset += cipher.blockSize) {
      cipher.processBlock(bytes, offset, output, offset);
    }
    if (!_isPlainImage(output)) {
      throw const FormatException('Invalid encoded source image');
    }
    return output;
  }
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
        false,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV(KeyParameter(key), iv),
          null,
        ),
      );
  try {
    return cipher.process(bytes);
  } on Object {
    throw const FormatException('Invalid encoded source image');
  }
}

bool _isPlainImage(Uint8List bytes) {
  if (bytes.length < 12) return false;
  bool starts(List<int> signature, [int offset = 0]) {
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) return false;
    }
    return true;
  }

  return starts([0xff, 0xd8, 0xff]) ||
      starts([0x89, 0x50, 0x4e, 0x47]) ||
      starts([0x47, 0x49, 0x46, 0x38]) ||
      (starts([0x52, 0x49, 0x46, 0x46]) &&
          starts([0x57, 0x45, 0x42, 0x50], 8)) ||
      starts([0x00, 0x00, 0x01, 0x00]);
}
