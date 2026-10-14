import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../net/lume_http.dart';
import '../net/lume_net.dart';
import '../net/network_queue.dart';
import '../net/network_settings.dart';
import '../net/source_request_log.dart';
import '../net/waf.dart';
import '../session/section.dart';
import '../source/data_source.dart';
import '../util/lume_log.dart';
import 'reading_store.dart';

/// 图片管线：网络 → 板块磁盘缓存 → 解码 → 内存缓存。
///
/// 四段都可释放，且释放是**页面的责任**：每个用到图片的页面各持一个实例，
/// 在 `dispose()` 里调用 [dispose]。释放动作包含三件事：
/// 1. 关闭 HTTP 客户端——在飞请求被就地取消（不计入失败日志）；
/// 2. 清空内存缓存——解码后的 [ui.Image] 逐个 dispose，位图内存立刻归还；
/// 3. 拒绝后续调用——等待中的请求收到空结果，不会悬挂。
///
/// 与板块的关系：磁盘缓存目录由页面从 `ReadingLibrary.imageCacheDir` 取得，
/// 落在本板块的 `sections/<id>/reading_cache/images/` 之内，且落盘文件名由
/// [ReadingStore.cacheKey] 从 URL 推出，不含路径分隔符——写不出板块目录。
/// 内存缓存是实例级的，因此板块之间既不共享内存缓存，也不共享解码位图。
///
/// 内存策略见 [ImageMemoryCache]：按字节预算做 LRU；**正在被展示的图**与
/// **预加载窗口内的图**永不回收——前者会被画到，后者是滑动流畅度的保障。
class SectionImagePipeline {
  SectionImagePipeline({
    required this.cacheDir,
    http.Client? client,
    this.memoryBudgetBytes = defaultMemoryBudgetBytes,
    this.maxConcurrent = 6,
    // 超时 20s → 30s：真机弱网下 20s 偏紧，封面被误判成失败就只剩空占位。
    this.timeout = const Duration(seconds: 30),
    this.diskCache = true,
    int maxRetries = 3,
    this.network = NetworkProfile.none,
    this.sourceLabel = '图片缓存',
    this.requestSender,
  }) : _client = client ?? http.Client(),
       _maxRetries = maxRetries < 0 ? 0 : maxRetries,
       _memory = ImageMemoryCache(memoryBudgetBytes);

  /// 阅读器默认内存预算。漫画长图按屏宽解码，64MB 约对应十余页。
  static const int defaultMemoryBudgetBytes = 64 * 1024 * 1024;

  /// 封面等小图用的预算（书架、探索、详情页）。
  static const int thumbnailBudgetBytes = 24 * 1024 * 1024;

  /// 板块内的图片缓存目录（调用方从 ReadingLibrary.imageCacheDir 取得）。
  final String cacheDir;
  final http.Client _client;
  final NetworkProfile network;
  final String sourceLabel;
  final NetworkSender? requestSender;
  final Map<String, String> _failures = {};
  String? failureFor(String url) =>
      _failures[upgradeToHttps(normalizeTransform(url))];
  bool canRetry(String url) =>
      !{'证书异常', '链接失效', '非图片响应'}.contains(failureFor(url));
  final Map<String, Map<String, String>> _imageHeaders = {};
  Future<String?> Function(String, String)? _refreshImage;
  DataSource? _boundSource;
  void bindSource(DataSource? source) {
    _boundSource = source;
    _refreshImage = source is RefreshingImageCapable
        ? (source as RefreshingImageCapable).refreshImage
        : null;
  }

  /// 图片请求头只能绑定到该源明确给出的 URL，不向其他域名或图片扩散。
  void configureImageHeaders(Map<String, Map<String, String>> headers) {
    for (final entry in headers.entries) {
      _imageHeaders[upgradeToHttps(normalizeTransform(entry.key))] = Map.of(
        entry.value,
      );
    }
  }

  /// 这条管线渲染的是哪个源（[Section] + 源 id），由页面在渲染该源的封面时挂上。
  ///
  /// 用途只有一个：**源站自己的图片要带源站会话**（`cf_clearance` 这类）。脚本
  /// 请求本来就带这份会话（见 `WafSessions`），所以列表 / 详情 HTML 一直取得到；
  /// 图片请求从前一枚 Cookie 都不带，源站一上 Cloudflare 校验，正文能看、封面
  /// 却一批批空白（真机反馈）。会话只发给**脚本自己请求过的域名**，独立图床
  /// （脚本从不请求）一枚都不带——那是把源站凭据泄漏给第三方域名。
  Section? _sessionSection;
  String? _sessionSourceId;

  /// 把「源站会话」挂到这条管线上；下次请求即按 [ownsHost] 判定要不要带。
  void bindSession(Section section, String sourceId) {
    _sessionSection = section;
    _sessionSourceId = sourceId;
  }

  /// 这张图要不要带源站会话：源站自己的域名 → 带上会话 Cookie 与验证时的 UA。
  ///
  /// UA 必须跟着一起换：`cf_clearance` 绑 IP + UA，带着 Cookie 用另一个 UA 发出去
  /// 等于没验（真机反馈过「验完还是被拦」）。没有会话时返回 null，行为与从前一致。
  ({String cookies, String userAgent})? _sessionFor(String url) {
    final id = _sessionSourceId;
    final section = _sessionSection;
    if (id == null || section == null) return null;
    if (!SourceRequestLog.ownsHost(id, url)) return null;
    final cookies = WafSessions.cookiesFor(section, id)?.trim() ?? '';
    if (cookies.isEmpty) return null;
    return (
      cookies: cookies,
      userAgent: WafSessions.userAgentFor(section, id)?.trim() ?? '',
    );
  }

  final Map<String, SectionImagePipeline> _sourcePipelines = {};

  /// 这条管线渲染的是哪个源（[Section] + 源 id），由页面在渲染该源的封面时挂上。
  ///
  /// 用途只有一个：**源站自己的图片要带源站会话**（`cf_clearance` 这类）。脚本
  /// 请求本来就带这份会话（见 `WafSessions`），所以列表 / 详情 HTML 一直取得到；
  /// 图片请求从前一枚 Cookie 都不带，源站一上 Cloudflare 校验，正文能看、封面
  /// 却一批批空白（真机反馈）。会话只发给**脚本自己请求过的域名**，独立图床
  /// （脚本从不请求）一枚都不带——那是把源站凭据泄漏给第三方域名。
  Section? _sessionSection;
  String? _sessionSourceId;

  /// 把「源站会话」挂到这条管线上；下次请求即按 [SourceRequestLog.ownsHost] 判定。
  void bindSession(Section section, String sourceId) {
    _sessionSection = section;
    _sessionSourceId = sourceId;
  }

  /// 这张图要不要带源站会话：源站自己的域名 → 带上会话 Cookie 与验证时的 UA。
  ///
  /// UA 必须跟着一起换：`cf_clearance` 绑 IP + UA，带着 Cookie 用另一个 UA 发出去
  /// 等于没验（真机反馈过「验完还是被拦」）。没有会话时返回 null，行为与从前一致。
  ({String cookies, String userAgent})? _sessionFor(String url) {
    final id = _sessionSourceId;
    final section = _sessionSection;
    if (id == null || section == null) return null;
    if (!SourceRequestLog.ownsHost(id, url)) return null;
    final cookies = WafSessions.cookiesFor(section, id)?.trim() ?? '';
    if (cookies.isEmpty) return null;
    return (
      cookies: cookies,
      userAgent: WafSessions.userAgentFor(section, id)?.trim() ?? '',
    );
  }

  /// 封面沿用该源的 UA、代理与显式证书选项；缓存与客户端按源隔离。
  ///
  /// Cookie 只发给**源站自己的域名**（脚本请求过的域名，见 [SourceRequestLog.ownsHost]）：
  /// 独立图床一枚都不带，避免把源站会话泄漏到第三方域名；源站自己的封面则必须带上
  /// （`cf_clearance` 这类校验凭证不带过去就是一片空白，见 [_fetchOnce]）。
  SectionImagePipeline forSource(
    Section section,
    String sourceId,
    NetworkProfile profile,
  ) {
    final key =
        '${section.id}:$sourceId:${profile.userAgent}:${profile.proxy}:${profile.allowBadCertificate}';
    return _sourcePipelines.putIfAbsent(
      key,
      () => SectionImagePipeline(
        cacheDir: p.join(
          cacheDir,
          ReadingStore.cacheKey('${section.id}:$sourceId'),
        ),
        memoryBudgetBytes: memoryBudgetBytes,
        maxConcurrent: maxConcurrent,
        timeout: timeout,
        diskCache: diskCache,
        maxRetries: maxRetries,
        network: profile,
        sourceLabel: '封面:${section.id}:$sourceId',
        requestSender: requestSender,
      )..bindSession(section, sourceId),
    );
  }

  /// 是否使用**磁盘**缓存（读与写都算）。
  ///
  /// 默认开：封面与漫画页跨会话复用，重开不必重新下载。
  /// [diskCache] 为 false 时图片一律实取网络（内存缓存与管线复用仍在，当次会话
  /// 内滑动 / 翻页照旧命中）——**漫画板块按用户要求这样关掉了**（「把漫画版块的
  /// 图片缓存删了也不要了」）：它的 `sections/comic/reading_cache/images/` 不再
  /// 新增文件，设置 →「缓存管理」里漫画一栏也就不再涨。代价是重开同一话要重新
  /// 下载页面，这是有意的取舍。
  final bool diskCache;

  /// 某板块的图片**是否落盘缓存**（当前策略：只有漫画不落盘）。
  ///
  /// **单一事实来源**：三个漫画管线与设置 →「缓存管理」的说明都读这里，
  /// 不会出现「页面写着已关闭、代码还在落盘」这种两份口径。
  static bool diskCacheFor(Section section) => section != Section.comic;

  /// 解码图内存预算（字节）。
  final int memoryBudgetBytes;

  /// 同时下载的图片数（封面网格用 [coverConcurrency]，阅读器可以更高）。
  ///
  /// 4 → 6 → **4**：真机反馈「首页封面偶发空白、有的能显示有的不显示」——
  /// 一次性并发太多会被图床按 IP 限流（429 / 空响应），反而更慢。
  /// 真正的上限仍在全局网络队列（单域名并发 2~3），这里只是别把 burst 开太大。
  final int maxConcurrent;

  /// 封面 / 缩略图网格的并发：**4**。阅读器（一屏 1–2 张大图）可以照常给 6。
  static const int coverConcurrency = 4;

  /// 单张图片的额外重试次数（不含首次）。
  ///
  /// 只重试「可能自己好」的失败：连接层异常、5xx、空响应体。
  /// 4xx（404/403）是这张图本身的问题，重试只会让翻页更慢。
  int get maxRetries => _maxRetries;
  final int _maxRetries;

  /// 单张图片的请求超时。
  final Duration timeout;

  final ImageMemoryCache _memory;

  /// URL → 在飞字节请求：同一 URL 并发只发一次。
  final Map<String, Future<Uint8List?>> _inFlightBytes =
      <String, Future<Uint8List?>>{};

  /// 缓存键 → 在飞解码：同一 URL + 解码宽度只解一次。
  final Map<String, Future<ui.Image?>> _inFlightImages =
      <String, Future<ui.Image?>>{};

  int _running = 0;
  final Queue<Completer<void>> _slots = Queue<Completer<void>>();
  bool _disposed = false;

  bool get isDisposed => _disposed;

  /// 内存缓存占用（字节）。
  int get memoryBytes => _memory.bytes;

  /// 内存缓存条目数。
  int get memoryCount => _memory.length;

  /// 内存缓存键：同一 URL 的不同解码宽度是两份不同位图。
  static String key(String url, int? targetWidth) =>
      targetWidth == null ? url : '$url@$targetWidth';

  // ------------------------------------------------------------------ 取图

  /// 取一张已解码的图片。失败（网络、解码、已释放）返回 null。
  ///
  /// **引用契约**：成功返回的图**自带一次引用**，调用方展示完必须 [release]
  /// 归还，归还前它不会被内存缓存的 LRU 回收。多个 tile 并发解码时，谁拿到图
  /// 谁先有引用，因此不会出现「刚拿到手就被别的加载挤掉」——画到已释放位图在
  /// 并发下也不可能发生。
  ///
  /// [targetWidth] 用于按显示宽度解码：漫画长图不按屏宽解码会带来几十 MB 的
  /// 位图，这是条漫场景下最容易踩的内存坑。解码不允许放大：原图比目标宽度还
  /// 小就按原尺寸解，不给长图白涨一圈内存。
  Future<ui.Image?> image(String url, {int? targetWidth}) =>
      _resolveImage(url, targetWidth: targetWidth, holdReference: true);

  /// 取图的统一入口。[holdReference] 决定是否把一次引用记在调用方账上：
  /// 展示用（widget）必须持有，预加载用（只进缓存）不持有。
  Future<ui.Image?> _resolveImage(
    String url, {
    int? targetWidth,
    required bool holdReference,
  }) {
    final trimmed = url.trim();
    if (trimmed.isEmpty || _disposed) return Future<ui.Image?>.value();
    final cacheKey = key(trimmed, targetWidth);
    final cached = _memory.get(cacheKey);
    if (cached != null) {
      if (holdReference) _memory.acquire(cacheKey);
      return Future<ui.Image?>.value(cached);
    }
    final existing = _inFlightImages[cacheKey];
    final request = existing ?? _startDecode(trimmed, targetWidth, cacheKey);
    if (!holdReference) return request;
    // 在飞请求是共享的，引用必须各自记账：谁 await，谁的账上多一次引用。
    return request.then((image) {
      if (image != null) _memory.acquire(cacheKey);
      return image;
    });
  }

  /// 发起一次解码并登记在飞表（同一 URL + 解码宽度只解一次）。
  Future<ui.Image?> _startDecode(
    String url,
    int? targetWidth,
    String cacheKey,
  ) {
    final request = _decode(url, targetWidth, cacheKey);
    _inFlightImages[cacheKey] = request;
    return request.whenComplete(() => _inFlightImages.remove(cacheKey));
  }

  /// 取原始字节（保存图片、解码前的缓存写入都走这里）。
  Future<Uint8List?> bytes(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty || _disposed) return Future<Uint8List?>.value();
    final existing = _inFlightBytes[trimmed];
    if (existing != null) return existing;
    final request = _loadBytes(trimmed);
    _inFlightBytes[trimmed] = request;
    return request.whenComplete(() => _inFlightBytes.remove(trimmed));
  }

  /// 取原始字节但**不落缓存**（批量下载用）。
  ///
  /// 批量下载的字节直接写进用户导出目录；如果先经 [bytes] 落一份到图片缓存，
  /// 同一张图就会在缓存与导出目录里各存一份，整部作品下完等于双倍占用。
  /// 除此之外走的仍是同一条下载通路（全局队列 / 并发闸门 / 超时）。
  Future<Uint8List?> fetch(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty || _disposed) return Future<Uint8List?>.value();
    return _download(upgradeToHttps(normalizeTransform(trimmed)));
  }

  /// 预加载一批图片（阅读器前后 N 张）。结果只进缓存，不返回给调用方。
  /// 预加载失败只记日志：它属于「提前准备」，不该打断阅读。
  void preload(Iterable<String> urls, {int? targetWidth}) {
    for (final url in urls) {
      unawaited(_preloadOne(url, targetWidth));
    }
  }

  /// 声明预加载窗口：窗口内的图钉住不回收；窗口外的图在无引用时立刻回收，
  /// 或随预算被 LRU 淘汰。滑动时每次窗口变化调用它即可。
  void retain(Iterable<String> urls, {int? targetWidth}) =>
      _memory.retain(urls.map((url) => key(url.trim(), targetWidth)).toSet());

  /// 登记一次展示引用（widget 挂载时调用）。
  void acquire(String url, {int? targetWidth}) =>
      _memory.acquire(key(url.trim(), targetWidth));

  /// 释放一次展示引用（widget 卸载时调用）。
  void release(String url, {int? targetWidth}) =>
      _memory.release(key(url.trim(), targetWidth));

  // ------------------------------------------------------------------ 释放

  /// 关闭客户端、取消在飞请求、清空内存缓存并拒绝后续调用。可重复调用。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final pipeline in _sourcePipelines.values) {
      pipeline.dispose();
    }
    _sourcePipelines.clear();
    _imageHeaders.clear();
    _failures.clear();
    // 取消在飞请求：关闭客户端是 package:http 提供的取消入口。
    try {
      _client.close();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
    _drainSlots();
    _inFlightBytes.clear();
    _inFlightImages.clear();
    _memory.clear();
  }

  // ------------------------------------------------------------------ 内部

  Future<void> _preloadOne(String url, int? targetWidth) async {
    // 预加载不持有引用：图只进缓存，随时可以被预算回收。
    final loaded = await _resolveImage(
      url,
      targetWidth: targetWidth,
      holdReference: false,
    );
    if (loaded == null && !_disposed) {
      LumeLog.warn('预加载未命中: $url');
    }
  }

  Future<ui.Image?> _decode(
    String url,
    int? targetWidth,
    String cacheKey,
  ) async {
    var data = await bytes(url);
    for (var attempt = 0; attempt < 2; attempt++) {
      if (data == null || _disposed) return null;
      try {
        final codec = await ui.instantiateImageCodec(
          data,
          targetWidth: targetWidth,
          allowUpscaling: false,
        );
        final frame = await codec.getNextFrame();
        final image = frame.image;
        codec.dispose();
        if (_disposed) {
          image.dispose();
          return null;
        }
        if (attempt == 1 && diskCache) {
          try {
            final file = File(
              _diskPath(upgradeToHttps(normalizeTransform(url))),
            );
            file.parent.createSync(recursive: true);
            file.writeAsBytesSync(data);
          } catch (_) {}
        }
        _failures.remove(upgradeToHttps(normalizeTransform(url)));
        _memory.put(cacheKey, image);
        return image;
      } catch (error) {
        final normalized = upgradeToHttps(normalizeTransform(url));
        _failures[normalized] = '图片解码失败';
        LumeLog.warn('[$sourceLabel] 图片解码失败: $url ($error)');
        if (!diskCache || attempt != 0) return null;
        final file = File(_diskPath(normalized));
        if (!file.existsSync()) return null;
        try {
          file.deleteSync();
        } catch (_) {
          return null;
        }
        // Discard poisoned/partial cache once and fetch fresh bytes.
        data = await _download(normalized);
      }
    }
    return null;
  }

  /// 字节来源顺序：磁盘缓存 → 网络。网络结果落盘，跨会话复用。
  ///
  /// [diskCache] 为 false 的板块（当前是漫画）直接走网络：不读盘也不落盘，
  /// 目录里不会因为看漫画而多出文件。
  ///
  /// 缓存判定用**同步** `stat`（`existsSync` / `lengthSync`）：这两个只是元数据
  /// 系统调用（微秒级），而一屏封面也就几十次。**不用异步版**是踩过坑的：
  /// `flutter_test` 的测试体跑在假时钟里，真实文件 IO 的完成回调等不到，
  /// 读缓存这条路径会把整个用例挂死（comic_reader 全套由绿变红）。
  /// 明文 http 的图片地址升级为 https（iOS ATS 默认禁止明文请求，明文图会整批裂掉，
  /// 真机表现就是「只有一部分封面能显示」——凡站点同时提供 https 的都能救回来）。
  ///
  /// 只升级 `http://` 且主机名不是 IP / localhost 的：本地回环与纯 IP 站点通常没有
  /// 证书，升级只会把能用的链接弄坏。
  /// 规整「图片变换型」地址：Cloudflare Image Resizing 那类
  /// `https://host/cdn-cgi/image/<变换参数>/<真实路径>` 在个别边缘/并发下会取不到图
  /// （真机反馈「首页封面很多是空白占位」）。这里统一退回**真实路径**——
  /// 实测原图稳定 200（image/webp），Flutter 直接能解。
  ///
  /// 只动这一种已知形态，其它 URL 原样返回（不猜、不改写）。
  static String normalizeTransform(String url) {
    final text = url.trim();
    if (text.isEmpty) return text;
    const marker = '/cdn-cgi/image/';
    final at = text.indexOf(marker);
    if (at <= 0) return text;
    final rest = text.substring(at + marker.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return text;
    return text.substring(0, at) + rest.substring(slash);
  }

  static String upgradeToHttps(String url) {
    if (!url.startsWith('http://')) return url;
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return url;
    final isIp = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);
    if (isIp || host == 'localhost') return url;
    return 'https://${url.substring('http://'.length)}';
  }

  Future<Uint8List?> _loadBytes(String rawUrl) async {
    // 明文地址在这里一次性升级：内存缓存键、磁盘文件名、实际请求三者保持一致，
    // 不会同一张图存两份。
    final url = upgradeToHttps(normalizeTransform(rawUrl));
    if (!diskCache) return _download(url);
    final file = File(_diskPath(url));
    try {
      if (file.existsSync() && file.lengthSync() > 0) {
        return await file.readAsBytes();
      }
    } catch (error) {
      LumeLog.warn('图片缓存读取失败: $url ($error)');
    }
    final downloaded = await _download(url);
    if (downloaded == null) return null;
    try {
      file.parent.createSync(recursive: true);
      await file.writeAsBytes(downloaded, flush: false);
    } catch (error) {
      // 落盘失败不影响本次显示。
      LumeLog.warn('图片缓存写入失败: $url ($error)');
    }
    return downloaded;
  }

  Future<Uint8List?> _download(String url) async {
    final allowed = await _acquireSlot();
    if (allowed != true || _disposed) return null;
    try {
      // 防盗链 403 的第二次尝试：同一个地址换一种 Referer 再试一遍。
      //
      // 图床的防盗链有两套相反的规矩：一套只认「Referer 是自己域名」，另一套
      // 只放行「完全没有 Referer」（比如某些 CDN 把任何跨站 Referer 一律拒掉）。
      // 两种都试过才认输——只多花一次请求，却能救回整整一批封面（真机反馈
      // 「只能加载一部分封面」，这是除明文地址外最常见的一条）。
      var bareReferer = false;
      var handled403 = false;
      final uri = Uri.tryParse(url);
      final alternate =
          uri != null &&
              uri.host == 'image.tmdb.org' &&
              uri.path.startsWith('/t/p/')
          ? uri.replace(host: 'media.themoviedb.org', userInfo: '').toString()
          : null;
      var requestedUrl = url;
      final originPage = _imageHeaders[url]?['X-Lume-Image-Page'];
      var refreshed = false;
      if (originPage != null &&
          _refreshImage != null &&
          signedUrlExpired(url)) {
        refreshed = true;
        try {
          final fresh = await _refreshImage!(url, originPage);
          final replacement = Uri.tryParse(fresh ?? '');
          if (replacement != null &&
              ['http', 'https'].contains(replacement.scheme)) {
            _imageHeaders[fresh!] = Map.of(_imageHeaders[url] ?? {});
            requestedUrl = fresh;
          }
        } catch (_) {}
      }
      var triedAlternate = false;
      final publicFallback = publicThumbnailFallback(
        url,
        headers: _imageHeaders[url] ?? {},
      );
      var triedPublicFallback = false;
      var retries = 0;
      final budget =
          _maxRetries +
          (originPage == null || _refreshImage == null ? 0 : 1) +
          (alternate == null ? 0 : 1) +
          (publicFallback == null ? 0 : 1);
      for (var attempt = 0; attempt <= budget; attempt++) {
        if (_disposed) return null;
        final outcome = await _fetchOnce(
          requestedUrl,
          withReferer: !bareReferer,
        );
        if (outcome.bytes != null) {
          _failures.remove(url);
          return outcome.bytes;
        }
        if (outcome.forbidden &&
            !refreshed &&
            originPage != null &&
            _refreshImage != null) {
          refreshed = true;
          try {
            final fresh = await _refreshImage!(url, originPage);
            final uri = Uri.tryParse(fresh ?? '');
            if (uri != null &&
                ['http', 'https'].contains(uri.scheme) &&
                fresh != requestedUrl) {
              _imageHeaders[fresh!] = Map.of(_imageHeaders[url] ?? {});
              requestedUrl = fresh;
              bareReferer = false;
              continue;
            }
          } catch (_) {}
        }
        if (alternate != null && !triedAlternate) {
          requestedUrl = alternate;
          triedAlternate = true;
          bareReferer = false;
          continue;
        }
        if (publicFallback != null &&
            !triedPublicFallback &&
            _failures[requestedUrl] == '证书异常') {
          requestedUrl = publicFallback;
          triedPublicFallback = true;
          bareReferer = true;
          LumeLog.info('[$sourceLabel] 公开缩略图启用定向兼容地址：imgcdn01.dycp444.com');
          continue;
        }
        if (outcome.forbidden && !bareReferer) {
          bareReferer = true;
          handled403 = true;
          continue;
        }
        if (!outcome.retryable || attempt == budget || retries >= _maxRetries) {
          break;
        }
        retries++;
        // 退避：300ms、600ms、1200ms。图片是**可见内容**，等太久不如让用户先
        // 看到缺口再自己重试——因此次数仍克制（默认 3 次，弱网多给一次机会）。
        await Future<void>.delayed(
          Duration(milliseconds: 300 * (1 << attempt)),
        );
      }
      if (handled403) LumeLog.info('图片防盗链：两种 Referer 都没放行 $url');
      return null;
    } finally {
      _releaseSlot();
    }
  }

  /// Verified public thumbnails on this CDN remain available over HTTP while
  /// its TLS certificate is expired. Never downgrade authenticated URLs.
  @visibleForTesting
  static bool signedUrlExpired(String url, {DateTime? now}) {
    final query = Uri.tryParse(url)?.queryParameters ?? {};
    final at = DateTime.tryParse(query['X-Amz-Date'] ?? '');
    final seconds = int.tryParse(query['X-Amz-Expires'] ?? '');
    return at != null &&
        seconds != null &&
        seconds >= 0 &&
        !at
            .add(Duration(seconds: seconds))
            .isAfter(
              (now ?? DateTime.now()).toUtc().add(const Duration(seconds: 5)),
            );
  }

  @visibleForTesting
  static String? publicThumbnailFallback(
    String url, {
    Map<String, String> headers = const {},
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'imgcdn01.dycp444.com' ||
        uri.hasQuery ||
        uri.userInfo.isNotEmpty ||
        headers.keys.any(
          (key) => {
            'cookie',
            'authorization',
            'proxy-authorization',
          }.contains(key.toLowerCase()),
        ) ||
        !RegExp(r'^/pic8/[0-9a-f]/[0-9a-f]/[0-9a-f]{32}\.\d+\.\d+\.jpg$')
            .hasMatch(uri.path)) {
      return null;
    }
    return uri.replace(scheme: 'http').toString();
  }

  /// 一次图片请求要带的头（[withReferer] 为假时**不带 Referer**）。
  ///
  /// 抽成静态纯函数是为了能单独钉住这条口径：防盗链的第二次尝试必须真的去掉
  /// Referer——以前这一步是空转（头照算），只认「无 Referer」的图床封面会一批批空白。
  ///
  /// Referer 取图片自己的 origin（与浏览器直接打开图片一致）；图床的防盗链门道：
  /// 不少站点只认「Referer 是自己域名」。`Accept-Language` 也照浏览器补一份：
  /// 个别图床按它做地区 / 防盗判断。
  @visibleForTesting
  static Map<String, String> imageRequestHeaders(
    String url, {
    bool withReferer = true,
  }) {
    final origin = Uri.tryParse(url);
    final referer = origin == null || !origin.hasScheme
        ? null
        : '${origin.scheme}://${origin.host}/';
    return <String, String>{
      'User-Agent': LumeNet.settings.userAgent.trim().isEmpty
          ? LumeHttp.defaultUserAgent
          : LumeNet.settings.userAgent.trim(),
      'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Referer': ?(withReferer ? referer : null),
    };
  }

  /// 取一次图片字节，并回报「重试有没有意义」。
  ///
  /// [withReferer] 为假时**真的不发 Referer**：防盗链的第二种规矩是「只放行没有
  /// Referer 的请求」，[_download] 专门为它安排了第二次尝试。这一步曾经是空转
  /// ——头照算、两次请求字节相同，于是这类图床的封面一批批地空白。
  Future<({Uint8List? bytes, bool retryable, bool forbidden})> _fetchOnce(
    String url, {
    bool withReferer = true,
  }) async {
    try {
      final bound = _boundSource;
      final verifiedUa = bound == null
          ? ''
          : WafSessions.userAgentFor(bound.section, bound.id)?.trim() ?? '';
      // 源站会话（`cf_clearance` 这类）：**只发给源站自己的域名**，见 [_sessionFor]。
      //
      // 为什么图片请求也得带：脚本请求本来就带这份会话（见 `LumeHttp.sessionCookies`），
      // 所以列表 / 详情 HTML 一直取得到；图片请求从前一枚 Cookie 都不带（iOS 原生
      // 图片通道是 ephemeral 会话、不读 Cookie 仓库），源站一上 Cloudflare 校验，
      // 正文能看、封面却一批批空白（真机反馈）。这里补上同一份会话。
      final session = _sessionFor(url);
      final explicitHeaders = _imageHeaders[url] ?? const <String, String>{};
      // 源自己写死的 Cookie（`coverHeaders`）优先：它比会话更懂那张图要什么。
      final hasExplicitCookie = explicitHeaders.keys.any(
        (key) => key.toLowerCase() == 'cookie',
      );
      // 图片同样走全局网络队列：单域名并发（2~3）保护图床，429/503 自动退避。
      // 队列管「什么时候发」，这里只管「拿到字节后怎么用」。
      final response = await (requestSender ?? LumeNet.queue.send)(
        NetworkRequest(
          url: url,
          headers: {
            ...imageRequestHeaders(url, withReferer: withReferer),
            if (network.userAgent.trim().isNotEmpty)
              'User-Agent': network.userAgent.trim(),
            for (final entry in explicitHeaders.entries)
              if (withReferer || entry.key.toLowerCase() != 'referer')
                if (!entry.key.toLowerCase().startsWith('x-lume-image-'))
                  entry.key: entry.value,
            if (session != null && !hasExplicitCookie) 'Cookie': session.cookies,
            // 会话的 UA 压过一切：`cf_clearance` 绑 IP + UA，换 UA 等于没验。
            if (session != null && session.userAgent.isNotEmpty)
              'User-Agent': session.userAgent,
            if (verifiedUa.isNotEmpty) 'User-Agent': verifiedUa,
          },
          source: sourceLabel,
          timeout: timeout,
          reuseVerifiedSession: verifiedUa.isNotEmpty,
          proxy: network.proxy.trim().isEmpty
              ? LumeNet.settings.proxy
              : network.proxy.trim(),
          allowBadCertificate: network.allowBadCertificate,
        ),
      );
      if (_disposed) {
        return (bytes: null, retryable: false, forbidden: false);
      }
      final code = response.statusCode;
      if (code >= 200 && code < 300) {
        final bytes = response.body;
        if (bytes.isEmpty) {
          LumeLog.warn('图片响应为空: $url');
          return (bytes: null, retryable: true, forbidden: false);
        }
        final prefix = String.fromCharCodes(bytes.take(160))
            .trimLeft()
            .toLowerCase();
        if (prefix.startsWith('<!doctype html') || prefix.startsWith('<html')) {
          _failures[url] = '非图片响应';
          LumeLog.warn('[$sourceLabel] 图片返回网页/校验页，不缓存: $url');
          return (bytes: null, retryable: false, forbidden: false);
        }
        _failures.remove(url);
        return (
          bytes: Uint8List.fromList(bytes),
          retryable: false,
          forbidden: false,
        );
      }
      // 4xx 是「这张图本身有问题」（链接失效 / 防盗链），重试不会变好——例外两类：
      // · **429 / 408**：限流与超时，正是「有时能出、有时空白」的典型（真机反馈），
      //   必须重试（退避在下面的重试循环里）；
      // · 403：换一种 Referer 再试一次（见 [_download]）。
      _failures[url] = code == 404 || code == 410
          ? '链接失效'
          : code == 403
          ? '图片被拦截'
          : 'HTTP $code';
      final forbidden = code == 403;
      final retryable = code < 400 || code == 408 || code == 429 || code >= 500;
      LumeLog.warn(
        '[$sourceLabel] 图片请求失败($code${retryable ? '，将重试' : '，不重试'}): $url',
      );
      return (bytes: null, retryable: retryable, forbidden: forbidden);
    } on Object catch (error) {
      // 管线已释放导致的请求中断不算错误，也不值得重试。
      if (_disposed) {
        return (bytes: null, retryable: false, forbidden: false);
      }
      final retryable = !NetworkQueue.isCertificateFailure(error);
      _failures[url] = retryable ? '网络异常' : '证书异常';
      LumeLog.warn(
        '[$sourceLabel] 图片请求异常(${retryable ? '将重试' : '证书错误，不重试'}): $url ($error)',
      );
      return (bytes: null, retryable: retryable, forbidden: false);
    }
  }

  /// 并发闸门：最多 [maxConcurrent] 个网络请求同时在跑。
  Future<bool?> _acquireSlot() async {
    if (_disposed) return null;
    if (_running < maxConcurrent) {
      _running++;
      return true;
    }
    final waiter = Completer<void>();
    _slots.add(waiter);
    await waiter.future;
    if (_disposed) return null;
    // The releasing request transfers its existing slot to this waiter.
    // Incrementing again leaks capacity after the initial batch drains.
    return true;
  }

  void _releaseSlot() {
    if (_slots.isNotEmpty) {
      // 把名额直接转交给下一个等待者。
      _slots.removeFirst().complete();
    } else {
      _running = _running > 0 ? _running - 1 : 0;
    }
  }

  /// 唤醒全部等待者，避免页面退出后仍有请求悬挂。
  void _drainSlots() {
    while (_slots.isNotEmpty) {
      _slots.removeFirst().complete();
    }
    _running = 0;
  }

  /// 落盘路径：板块目录 + 由 URL 推出的十六进制文件名。
  String _diskPath(String url) =>
      p.join(cacheDir, '${ReadingStore.cacheKey(url)}.img');

  /// 某张图的磁盘缓存文件路径（与 [_diskPath] 同一套规则，供测试与排障定位）。
  ///
  /// 与 [_loadBytes] 一样先做明文升级：文件名按升级后的地址算，`http://…` 与
  /// `https://…` 两种写法落到同一个文件，同一张图不会存两份。
  @visibleForTesting
  String cachePathFor(String url) =>
      _diskPath(upgradeToHttps(normalizeTransform(url)));
}

/// 解码图的内存缓存：按字节预算做 LRU，带引用计数与钉住集合。
///
/// 三种状态共同决定一张图能否被回收：
/// - **引用中**（调用方正在展示，[acquire] 未 [release]）永不回收，
///   否则会画到已释放的位图；
/// - **钉住**（落在预加载窗口内）不回收，滑动时才能立刻命中；
/// - 其余按最近使用顺序（[get] 命中即置为最近）淘汰，直到回到预算之内。
///
/// 还有一条硬约束：**刚插入的那一张不会被它自己触发的那次淘汰回收**——
/// 它正要交给调用方，如果被挤掉，调用方拿到的是已释放的位图（并发加载时
/// 曾会真的发生）。保护范围只限这一次淘汰，之后它要么被引用（安全），
/// 要么成为普通的可淘汰项。
///
/// 淘汰时对 [ui.Image] 调用 `dispose()`，位图内存同步归还。
class ImageMemoryCache {
  ImageMemoryCache(this.budgetBytes);

  /// 字节预算。<= 0 表示不限制（测试用）。
  final int budgetBytes;

  final LinkedHashMap<String, _CacheEntry> _entries =
      LinkedHashMap<String, _CacheEntry>();

  int _bytes = 0;
  bool _closed = false;

  int get bytes => _bytes;

  int get length => _entries.length;

  ui.Image? get(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    // 命中即提到队尾（最近使用），LRU 由插入顺序表达。
    _entries
      ..remove(key)
      ..[key] = entry;
    return entry.image;
  }

  void put(String key, ui.Image image) {
    if (_closed) {
      image.dispose();
      return;
    }
    _remove(key);
    final entry = _CacheEntry(image);
    _entries[key] = entry;
    _bytes += entry.bytes;
    // 跳过刚插入的这一张：它马上要交给调用方。
    _trim(protect: key);
  }

  void acquire(String key) => _entries[key]?.refs++;

  void release(String key) {
    final entry = _entries[key];
    if (entry == null) return;
    if (entry.refs > 0) entry.refs--;
    _trim();
  }

  void releaseAll() {
    for (final entry in _entries.values) {
      entry.refs = 0;
    }
    _trim();
  }

  void retain(Set<String> keys) {
    for (final entry in _entries.entries) {
      entry.value.pinned = keys.contains(entry.key);
    }
    _trim();
  }

  /// 清空全部缓存，逐个释放位图。
  void clear() {
    _closed = true;
    for (final entry in _entries.values) {
      entry.dispose();
    }
    _entries.clear();
    _bytes = 0;
  }

  /// 按预算淘汰：[protect] 指定的键在这次淘汰中跳过（用于「刚插入、正要交给
  /// 调用方」的那一张）。
  void _trim({String? protect}) {
    if (budgetBytes <= 0 || _bytes <= budgetBytes) return;
    for (final key in _entries.keys.toList(growable: false)) {
      if (_bytes <= budgetBytes) break;
      if (key == protect) continue;
      final entry = _entries[key]!;
      if (entry.refs > 0 || entry.pinned) continue;
      _entries.remove(key);
      _bytes -= entry.bytes;
      entry.dispose();
    }
  }

  void _remove(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return;
    _bytes -= entry.bytes;
    entry.dispose();
  }
}

class _CacheEntry {
  _CacheEntry(this.image) : bytes = image.width * image.height * 4;

  final ui.Image image;

  /// 位图字节估算：宽 × 高 × 4（RGBA）。
  final int bytes;

  int refs = 0;
  bool pinned = false;

  void dispose() {
    try {
      image.dispose();
    } on Object catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }
}
