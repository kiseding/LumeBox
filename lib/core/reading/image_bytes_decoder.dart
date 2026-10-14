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
  if (encoding != 'aes-cbc-pkcs7') {
    throw const FormatException('Unsupported source image encoding');
  }
  final key = Uint8List.fromList(utf8.encode(field('x-lume-image-key')));
  final iv = Uint8List.fromList(utf8.encode(field('x-lume-image-iv')));
  if (!{16, 24, 32}.contains(key.length) ||
      iv.length != 16 ||
      bytes.isEmpty ||
      bytes.length % 16 != 0) {
    throw const FormatException('Invalid source image encoding parameters');
  }
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
        false,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV(KeyParameter(key), iv),
          null,
        ),
      );
  return cipher.process(bytes);
}
