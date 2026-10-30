import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../net/lume_net.dart';

/// 模型文件取用口径：**随包优先，没有就下载**。
///
/// 离线朗读与片头识别的权重已经在 build 期重打包过（见
/// `docs/2026-10-29_离线资源精简与网页整剧.md`），剩下仍然整块占包体的
/// 是 waifu2x（8 份共 17 MB）与 YAMNet（15 MB）——它们服务的都是可选功能，
/// 却对每个用户都占着安装包。这里改成首次使用再取，落盘位置与原来
/// 「安装内置模型」完全一致。
///
/// SHA-256 钉在代码里（与仓库 `ORIGIN.json`／`checksums.json` 同源）：校验
/// 不过就删掉临时文件并报错，绝不把半个模型交给原生层。开发期如果 assets
/// 里还有这些文件，直接读随包资产，不发网络请求。
class ModelDownloadException implements Exception {
  const ModelDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ModelSource {
  ModelSource._();

  /// 单测注入：直接给出模型字节，测试里不必真的走网络。
  ///
  /// 仓库里仍然躺着这些权重（它们就是下载源），所以用
  /// `(path) async => File(path).readAsBytes()` 就能覆盖到真实数据。
  @visibleForTesting
  static Future<Uint8List> Function(String assetPath)? debugReader;

  static const String _repo = 'kiseding/LumeBox';
  static const String _ref = 'main';

  /// 下载来源。按顺序尝试，直到拿到 200。
  ///
  /// jsDelivr 的镜像在国内比 api.github.com 稳定得多，单文件上限 20 MB；
  /// 接自己的对象存储时用构建参数整体覆盖（目录结构与仓库一致）：
  ///
  /// ```
  /// flutter build ipa --dart-define=LUME_MODEL_BASE=https://your.host/lumebox/
  /// ```
  static List<Uri> _sources(String path) {
    const override = String.fromEnvironment('LUME_MODEL_BASE');
    if (override.isNotEmpty) {
      final base = override.endsWith('/') ? override : '$override/';
      return [Uri.parse('$base$path')];
    }
    return [
      Uri.parse('https://cdn.jsdelivr.net/gh/$_repo@$_ref/$path'),
      Uri.parse('https://fastly.jsdelivr.net/gh/$_repo@$_ref/$path'),
      Uri.parse('https://api.github.com/repos/$_repo/contents/$path'),
    ];
  }

  /// 取 [assetPath] 到 [target]。
  ///
  /// [remotePath] 用于「包里是 A、下载源是 B」的情况（例如片头识别的紧凑包
  /// 由 build 期生成，仓库里只有原始包）。不给就与 [assetPath] 相同。
  ///
  /// [digest] 为小写十六进制 SHA-256；给了就必须匹配。
  static Future<void> fetch(
    String assetPath,
    File target, {
    String? remotePath,
    String? digest,
    void Function(int received, int? total)? onProgress,
  }) async {
    final injected = debugReader;
    if (injected != null) {
      await target.parent.create(recursive: true);
      await target.writeAsBytes(await injected(assetPath), flush: true);
      return;
    }
    if (await _copyBundled(assetPath, target)) return;
    await _download(
      remotePath ?? assetPath,
      target,
      digest: digest,
      onProgress: onProgress,
    );
  }

  /// 取一份小文件的字节，给必须整块交给原生层的场景用。
  static Future<Uint8List> bytes(String assetPath, {String? digest}) async {
    final injected = debugReader;
    if (injected != null) return injected(assetPath);
    try {
      final data = await rootBundle.load(assetPath);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      // 未随包提供：下载到临时文件再整块读回。
    }
    final target = File(
      '${Directory.systemTemp.path}/lumebox-model-'
      '${DateTime.now().microsecondsSinceEpoch}-${_basename(assetPath)}',
    );
    try {
      await _download(assetPath, target, digest: digest);
      return await target.readAsBytes();
    } finally {
      if (await target.exists()) await target.delete();
    }
  }

  static Future<bool> _copyBundled(String assetPath, File target) async {
    try {
      final data = await rootBundle.load(assetPath);
      await target.parent.create(recursive: true);
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _download(
    String path,
    File target, {
    String? digest,
    void Function(int received, int? total)? onProgress,
  }) async {
    Object? lastError;
    for (final uri in _sources(path)) {
      try {
        await _downloadFrom(
          uri,
          target,
          digest: digest,
          onProgress: onProgress,
        );
        return;
      } on ModelDownloadException catch (error) {
        lastError = error;
        // 一个源失败就换下一个；全部失败时最后一条信息才是要报给用户的。
      }
    }
    throw ModelDownloadException(
      lastError?.toString().replaceFirst('下载失败：', '') ?? '下载失败',
    );
  }

  static Future<void> _downloadFrom(
    Uri uri,
    File target, {
    String? digest,
    void Function(int received, int? total)? onProgress,
  }) async {
    final client = _client();
    final partial = File('${target.path}.part');
    IOSink? sink;
    try {
      final request = http.Request('GET', uri)
        // GitHub 的 contents API 需要它才回原始字节；jsDelivr 忽略此头。
        ..headers['Accept'] = 'application/vnd.github.raw';
      // 只给「拿到响应头」设超时；正文可能下几十分钟，不能整体设限。
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw ModelDownloadException('下载失败：HTTP ${response.statusCode}');
      }
      await target.parent.create(recursive: true);
      sink = partial.openWrite();
      var received = 0;
      final total = response.contentLength;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total != null && received != total) {
        throw ModelDownloadException('下载不完整（$received/$total 字节），请重试');
      }
      if (digest != null) {
        final actual = (await sha256.bind(partial.openRead()).first).toString();
        if (actual != digest) {
          throw const ModelDownloadException('模型文件校验失败，请重试');
        }
      }
      await partial.rename(target.path);
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // 关流失败不影响结论：临时文件下面会删掉。
      }
      if (await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {
          // 删不掉就留着，下次覆盖写。
        }
      }
      client.close();
    }
  }

  /// 与全局网络设置同一口径的客户端：配了 HTTP 代理就走代理。
  static http.Client _client() {
    final inner = HttpClient();
    final uri = Uri.tryParse(LumeNet.settings.proxy.trim());
    if (uri != null &&
        uri.host.isNotEmpty &&
        uri.scheme.toLowerCase().startsWith('http')) {
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
      inner.findProxy = (target) => 'PROXY ${uri.host}:$port';
    }
    return IOClient(inner);
  }

  static String _basename(String path) => path.split('/').last;
}
