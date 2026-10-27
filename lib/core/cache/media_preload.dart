import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Shared speculative-work policy. Visible images/current playback are never
/// blocked by these switches. Video/audio buffers remain owned by their kernels.
class MediaPreload extends ChangeNotifier {
  static final instance = MediaPreload();
  bool video = true, images = true, audio = true;
  int triggerSeconds = 30, bufferSeconds = 5, capacityMb = 64;
  int generation = 0;
  bool clearing = false;
  Directory? _root;
  File? _settings;
  int? _knownBytes;
  final _clearers = <FutureOr<void> Function()>{};
  int get imageBudgetBytes => capacityMb * 1024 * 1024 ~/ 2;
  int get mediaBudgetBytes => capacityMb * 1024 * 1024 ~/ 4;

  Future<void> boot({Directory? directory}) async {
    final base = directory ?? await getApplicationSupportDirectory();
    _root = Directory('${base.path}/media-preload-v1');
    _knownBytes = null;
    _settings = File('${base.path}/media_preload.json');
    try {
      if (_settings!.existsSync()) {
        final data = jsonDecode(_settings!.readAsStringSync()) as Map;
        video = data['video'] != false;
        images = data['images'] != false;
        audio = data['audio'] != false;
        triggerSeconds = _integer(data['triggerSeconds'], 30, 10, 120);
        bufferSeconds = _integer(data['bufferSeconds'], 5, 3, 60);
        capacityMb = _integer(data['capacityMb'], 64, 16, 256);
      }
    } catch (_) {
      /* Invalid settings retain bounded defaults. */
    }
    _prune();
  }

  static int _integer(Object? value, int fallback, int min, int max) =>
      value is num && value.isFinite ? value.toInt().clamp(min, max) : fallback;

  void update({
    bool? video,
    bool? images,
    bool? audio,
    int? triggerSeconds,
    int? bufferSeconds,
    int? capacityMb,
  }) {
    this.video = video ?? this.video;
    this.images = images ?? this.images;
    this.audio = audio ?? this.audio;
    this.triggerSeconds = (triggerSeconds ?? this.triggerSeconds).clamp(
      10,
      120,
    );
    this.bufferSeconds = (bufferSeconds ?? this.bufferSeconds).clamp(3, 60);
    this.capacityMb = (capacityMb ?? this.capacityMb).clamp(16, 256);
    generation++;
    final file = _settings;
    if (file != null) {
      file.parent.createSync(recursive: true);
      final temp = File('${file.path}.tmp');
      temp.writeAsStringSync(
        jsonEncode({
          'video': this.video,
          'images': this.images,
          'audio': this.audio,
          'triggerSeconds': this.triggerSeconds,
          'bufferSeconds': this.bufferSeconds,
          'capacityMb': this.capacityMb,
        }),
      );
      temp.renameSync(file.path);
    }
    _prune();
    notifyListeners();
  }

  VoidCallback onClear(FutureOr<void> Function() callback) {
    _clearers.add(callback);
    return () => _clearers.remove(callback);
  }

  File? _file(String key) => _root == null
      ? null
      : File('${_root!.path}/${sha256.convert(utf8.encode(key))}.image');
  Uint8List? image(String key) {
    final file = _file(key);
    try {
      if (file?.existsSync() != true) return null;
      final bytes = file!.readAsBytesSync();
      file.setLastModifiedSync(DateTime.now());
      return bytes;
    } catch (_) {
      return null;
    }
  }

  void cacheImage(String key, Uint8List bytes, int expectedGeneration) {
    if (!images ||
        clearing ||
        generation != expectedGeneration ||
        bytes.length > imageBudgetBytes) {
      return;
    }
    final file = _file(key);
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      final previous = file.existsSync() ? file.lengthSync() : 0;
      final before = diskBytes;
      file.writeAsBytesSync(bytes);
      _knownBytes = before + bytes.length - previous;
      _prune();
    } catch (_) {
      /* Speculative caching must not interrupt display. */
    }
  }

  List<File> _files() => _root?.existsSync() == true
      ? _root!
            .listSync(followLinks: false)
            .whereType<File>()
            .where(
              (file) =>
                  RegExp(r'[/\\][0-9a-f]{64}\.image$').hasMatch(file.path),
            )
            .toList()
      : [];
  int get diskBytes {
    final known = _knownBytes;
    if (known != null) return known;
    final total = _files().fold<int>(0, (sum, file) => sum + file.lengthSync());
    _knownBytes = total;
    return total;
  }
  void _prune() {
    if (diskBytes <= imageBudgetBytes) return;
    final files = _files()
      ..sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    var bytes = files.fold(0, (sum, file) => sum + file.lengthSync());
    for (final file in files) {
      if (bytes <= imageBudgetBytes) break;
      bytes -= file.lengthSync();
      file.deleteSync();
      _knownBytes = bytes;
    }
  }

  Future<int> clear() async {
    if (clearing) throw StateError('正在清理预载');
    clearing = true;
    try {
      generation++;
      final callbacks = _clearers.toList();
      // Clear every registered owner even when one kernel cannot release a buffer.
      final errors = <Object>[];
      for (final callback in callbacks) {
        try {
          await callback();
        } catch (error) {
          errors.add(error);
        }
      }
      var freed = 0;
      for (final file in _files()) {
        freed += file.lengthSync();
        file.deleteSync();
      }
      _knownBytes = 0;
      if (errors.isNotEmpty) throw StateError('部分播放内核未能释放预载，请退出播放后重试');
      notifyListeners();
      return freed;
    } finally {
      clearing = false;
    }
  }
}
