import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../net/lume_net.dart';

/// 模型文件取用口径：**随包优先，没有就下载**。
///
/// 可选功能的权重不占安装包：waifu2x（8 份共 17 MB）、YAMNet（15 MB）、
/// 离线音色包（约 124 MB）都在首次使用时才取，落盘位置与原来「安装内置
/// 模型」完全一致。SHA-256 钉在清单里：校验不过就删掉临时文件并报错，
/// 绝不把半个模型交给原生层。
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
      for (final file in [target, File('${target.path}.part')]) {
        if (await file.exists()) await file.delete();
      }
    }
  }

  /// 按给定的地址依次尝试，取到 [target] 为止。
  ///
  /// 半途失败会留下 `目标.part`，下一个地址（或用户重试）从断点续传——
  /// 121 MB 的音色包模型不能因为掉了 5% 就从头再来。各地址提供的是同一份
  /// 字节（[digest] 与 [bytes] 就是对它的约束），因此可以跨源续传。
  static Future<void> fetchFrom(
    List<Uri> uris,
    File target, {
    String? digest,
    int? bytes,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (uris.isEmpty) {
      throw const ModelDownloadException('没有配置下载地址');
    }
    Object? lastError;
    for (final uri in uris) {
      try {
        await _downloadFrom(
          uri,
          target,
          digest: digest,
          expected: bytes,
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
  }) => fetchFrom(_sources(path), target, digest: digest, onProgress: onProgress);

  /// 收尾：尺寸与摘要都对得上才把 `.part` 改名成正式文件。
  ///
  /// 对不上就删掉——走到这里说明「内容已经完整但字节不对」，续传没有意义。
  static Future<bool> _accept(
    File partial,
    File target, {
    String? digest,
    int? expected,
  }) async {
    if (!await partial.exists()) return false;
    if (expected != null && await partial.length() != expected) {
      await partial.delete();
      return false;
    }
    if (digest != null &&
        (await sha256.bind(partial.openRead()).first).toString() != digest) {
      await partial.delete();
      return false;
    }
    await partial.rename(target.path);
    return true;
  }

  static Future<void> _downloadFrom(
    Uri uri,
    File target, {
    String? digest,
    int? expected,
    void Function(int received, int? total)? onProgress,
  }) async {
    final partial = File('${target.path}.part');
    await target.parent.create(recursive: true);
    var offset = await partial.exists() ? await partial.length() : 0;
    if (expected != null && offset > expected) {
      await partial.delete();
      offset = 0;
    }
    if (offset > 0 && offset == expected) {
      // 上次其实已经下完（只差改名）：验证通过就直接收工。
      if (await _accept(partial, target, digest: digest, expected: expected)) {
        onProgress?.call(offset, expected);
        return;
      }
      offset = 0;
    }
    final client = _client();
    IOSink? sink;
    try {
      final request = http.Request('GET', uri)
        // GitHub 的 contents API 需要它才回原始字节；其余源忽略此头。
        ..headers['Accept'] = 'application/vnd.github.raw';
      if (offset > 0) request.headers['Range'] = 'bytes=$offset-';
      // 只给「拿到响应头」设超时；正文可能下几十分钟，不能整体设限。
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 416 && offset > 0) {
        // 服务端认为已经给完了：交给摘要判断，确实不完整就从头来。
        if (await _accept(
          partial,
          target,
          digest: digest,
          expected: expected,
        )) {
          return;
        }
        throw const ModelDownloadException('下载失败：HTTP 416');
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw ModelDownloadException('下载失败：HTTP ${response.statusCode}');
      }
      // 200 说明服务端不支持 Range（或我们没要过），只能重写整个文件。
      final resumed = offset > 0 && response.statusCode == 206;
      if (!resumed) offset = 0;
      sink = partial.openWrite(
        mode: resumed ? FileMode.append : FileMode.write,
      );
      var received = offset;
      final length = response.contentLength;
      final total = expected ?? (length == null ? null : received + length);
      onProgress?.call(received, total);
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (expected != null && received != expected) {
        // 连接提前结束：留着 .part，下次从断点续。
        throw ModelDownloadException('下载不完整（$received/$expected 字节），请重试');
      }
      if (digest != null &&
          (await sha256.bind(partial.openRead()).first).toString() != digest) {
        await partial.delete();
        throw const ModelDownloadException('模型文件校验失败，请重试');
      }
      await partial.rename(target.path);
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // 关流失败不影响结论：半截文件上面已经处理过了。
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
