import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/block/modes/ecb.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';

typedef _LegacyImageWork = ({Uint8List bytes, Uint8List key, Uint8List? iv});

Future<Uint8List?> decodeLegacySourceImageInBackground(
  Uint8List bytes,
  Uint8List key, {
  Uint8List? iv,
}) => compute(_decodeLegacyImageWork, (bytes: bytes, key: key, iv: iv));

Uint8List? _decodeLegacyImageWork(_LegacyImageWork work) {
  final iv = work.iv;
  final cipherBytes = iv == null
      ? work.bytes
      : base64Decode(base64.normalize(utf8.decode(work.bytes).trim()));
  final BlockCipher cipher = iv == null
      ? (ECBBlockCipher(AESEngine())..init(false, KeyParameter(work.key)))
      : (CBCBlockCipher(AESEngine())
          ..init(false, ParametersWithIV(KeyParameter(work.key), iv)));
  if (cipherBytes.isEmpty || cipherBytes.length % cipher.blockSize != 0) {
    return null;
  }
  final plain = Uint8List(cipherBytes.length);
  for (
    var offset = 0;
    offset < cipherBytes.length;
    offset += cipher.blockSize
  ) {
    cipher.processBlock(cipherBytes, offset, plain, offset);
  }
  final pad = plain.last;
  final body = pad > 0 && pad <= 16 && pad <= plain.length
      ? Uint8List.sublistView(plain, 0, plain.length - pad)
      : plain;
  final text = utf8.decode(body, allowMalformed: true);
  return decodeImageDataUri(text) ?? body;
}

Uint8List? decodeImageDataUri(String url) {
  final text = url.trim();
  if (!text.startsWith('data:')) return null;
  final comma = text.indexOf(',');
  if (comma <= 0) return null;
  final meta = text.substring(5, comma).toLowerCase();
  if (!meta.startsWith('image/')) return null;
  final payload = text.substring(comma + 1);
  try {
    if (meta.contains('base64')) return base64Decode(payload);
    return Uint8List.fromList(Uri.decodeComponent(payload).codeUnits);
  } catch (_) {
    return null;
  }
}

Uint8List _decodeImageWork(
  ({Uint8List bytes, Map<String, String> headers}) work,
) => decodeSourceImage(work.bytes, work.headers);

/// CPU-heavy image decryption must not hold the scrolling UI isolate.
Future<Uint8List> decodeSourceImageInBackground(
  Uint8List bytes,
  Map<String, String> headers,
) {
  final encoded = headers.entries.any(
    (entry) =>
        entry.key.toLowerCase() == 'x-lume-image-encoding' &&
        entry.value.isNotEmpty,
  );
  if (!encoded || _isPlainImage(bytes)) return Future.value(bytes);
  return compute(_decodeImageWork, (bytes: bytes, headers: headers));
}

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
  if (encoding == 'fernet') {
    if (_isPlainImage(bytes)) return bytes;
    return _decodeFernetImage(bytes, field('x-lume-image-key'));
  }
  final noPadding = encoding == 'aes-cbc-nopadding';
  if (encoding != 'aes-cbc-pkcs7' && !noPadding) {
    throw const FormatException('Unsupported source image encoding');
  }
  // The public reader mixes encrypted business images with plain images.
  if (_isPlainImage(bytes)) return bytes;
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

/// Some public readers encrypt only the data-URI prefix, then append the
/// remaining Base64 after @@@. Authenticate the Fernet part before rebuilding.
Uint8List _decodeFernetImage(Uint8List bytes, String encodedKey) {
  try {
    final text = utf8.decode(bytes).trim();
    final separator = text.indexOf('@@@');
    final token = separator < 0 ? text : text.substring(0, separator);
    final raw = base64Url.decode(base64Url.normalize(token));
    final key = base64Url.decode(base64Url.normalize(encodedKey));
    if (key.length != 32 || raw.length < 73 || raw[0] != 0x80) {
      throw const FormatException('Invalid Fernet image parameters');
    }
    final signedEnd = raw.length - 32;
    final signature = crypto.Hmac(
      crypto.sha256,
      key.sublist(0, 16),
    ).convert(raw.sublist(0, signedEnd)).bytes;
    var difference = 0;
    for (var i = 0; i < 32; i++) {
      difference |= signature[i] ^ raw[signedEnd + i];
    }
    if (difference != 0 || (signedEnd - 25) % 16 != 0) {
      throw const FormatException('Invalid Fernet image signature');
    }
    final cipher =
        PaddedBlockCipherImpl(
          PKCS7Padding(),
          CBCBlockCipher(AESEngine()),
        )..init(
          false,
          PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
            ParametersWithIV(KeyParameter(key.sublist(16)), raw.sublist(9, 25)),
            null,
          ),
        );
    final plain = cipher.process(raw.sublist(25, signedEnd));
    if (separator < 0 && _isPlainImage(plain)) return plain;
    final uri =
        utf8.decode(plain) +
        (separator < 0 ? '' : text.substring(separator + 3));
    final comma = uri.indexOf(',');
    if (!uri.startsWith('data:image/') ||
        comma < 0 ||
        !uri.substring(0, comma).endsWith(';base64')) {
      throw const FormatException('Invalid Fernet image payload');
    }
    final image = base64Decode(uri.substring(comma + 1));
    if (!_isPlainImage(image)) {
      throw const FormatException('Invalid Fernet image');
    }
    return image;
  } on Object {
    throw const FormatException('Invalid encoded Fernet image');
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
