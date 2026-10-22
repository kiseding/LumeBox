import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/player/player_experience_store.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/web/web_home_sources.dart';
import '../../core/web/web_home_bridge.dart';
import '../../core/web/web_home_playback.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/session/privacy_settings.dart';
import '../../core/cat/cat_service.dart';
import '../../core/cat/cat_data_source.dart';
import '../../core/source/source.dart';
import '../cat/cat_detail_page.dart';
import '../video/video_player_page.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/lume_icon.dart';

/// Opens a user-added web home page inside the app.
///
/// This is intentionally a pushed route, not a fourth home surface: leaving the
/// page (back button / edge swipe) returns to the video tab, and the WebView's
/// own history is kept while the page is open.
class WebHomePage extends StatefulWidget {
  const WebHomePage({super.key, required this.source});

  final WebHomeSource source;

  @override
  State<WebHomePage> createState() => _WebHomePageState();
}

class _WebHomePageState extends State<WebHomePage> {
  final WebViewController _controller = WebViewController();
  int _progress = 0;
  String? _error;
  String _title = '';
  bool _ready = false;
  WebHomeBridge? _bridge;
  Uri? _localHome;
  bool _edge = false;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      _boot().catchError((Object failure) {
        if (mounted) setState(() => _error = '主页加载失败，请重新打开或导入 HTML');
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_bridge?.close());
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_sendViewport()),
    );
  }

  Future<void> _boot() async {
    final ua = PlayerExperienceStore.current.browserUA;
    if (ua.isNotEmpty) await _controller.setUserAgent(ua);
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
        onPageStarted: (_) {
          if (mounted) {
            setState(() {
              _error = null;
              _progress = 0;
            });
          }
        },
        onPageFinished: (_) async {
          final title = await _controller.getTitle();
          if (mounted && title != null && title.trim().isNotEmpty) {
            setState(() => _title = title.trim());
          }
          await _sendViewport();
        },
        onWebResourceError: (failure) {
          if (mounted && failure.isForMainFrame == true) {
            setState(() => _error = '网页加载失败，请检查网络或地址后重试');
          }
        },
        onNavigationRequest: (request) async {
          final uri = Uri.tryParse(request.url);
          if (uri == null) return NavigationDecision.prevent;
          if (_localHome != null &&
              request.isMainFrame &&
              uri.removeFragment() != _localHome) {
            if (mounted &&
                {'http', 'https'}.contains(uri.scheme) &&
                uri.host != '127.0.0.1') {
              unawaited(
                Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => WebHomePage(
                      source: WebHomeSource(
                        id: 'external',
                        name: widget.source.name,
                        url: uri.toString(),
                      ),
                    ),
                  ),
                ),
              );
            } else if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('本地主页中的外部链接请复制后打开')));
            }
            return NavigationDecision.prevent;
          }
          if (const {
            'http',
            'https',
            'about',
            'data',
            'blob',
          }.contains(uri.scheme)) {
            return NavigationDecision.navigate;
          }
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('这个链接需要在其他应用里打开')));
          }
          return NavigationDecision.prevent;
        },
      ),
    );
    Uri? uri;
    if (widget.source.html case final html?) {
      final library = await ReadingLibrary.open(Section.video);
      if (!mounted) return;
      final bridge = WebHomeBridge(
        sourceId: widget.source.id,
        library: library,
        onPlay: _play,
        onPan: _pan,
        onChrome: (args) async {
          if (!mounted) return;
          setState(
            () =>
                _edge = args['mode'] == 'edge' || args['mode'] == 'fullscreen',
          );
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => unawaited(_sendViewport()),
          );
        },
      );
      _bridge = bridge;
      uri = await bridge.start(html);
      if (!mounted) {
        await bridge.close();
        return;
      }
      _localHome = uri;
    } else {
      uri = widget.source.uri;
    }
    if (uri == null) {
      if (mounted) setState(() => _error = '主页地址无效');
      return;
    }
    await _controller.loadRequest(uri);
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _sendViewport() async {
    if (!mounted || _bridge == null) return;
    final padding = MediaQuery.viewPaddingOf(context);
    final value = {
      'chromeMode': _edge ? 'edge' : 'normal',
      'safeTop': _edge ? padding.top : 0,
      'safeBottom': padding.bottom,
      'safeLeft': padding.left,
      'safeRight': padding.right,
    };
    try {
      await _controller.runJavaScript(
        'window.__lumeViewport && window.__lumeViewport(${jsonEncode(value)})',
      );
    } catch (_) {
      /* A page may be reloading or closing. */
    }
  }

  Future<void> _play(Map<String, dynamic> args) async {
    if (!mounted || _opening) return;
    final request = WebHomePlayback(args);
    if (request.isShare) {
      return _pan({'url': request.shareUrl, 'title': request.title});
    }
    final media = request.media;
    _opening = true;
    unawaited(
      Navigator.of(context)
          .push<void>(
            MaterialPageRoute(
              builder: (_) =>
                  VideoPlayerPage(media: media, title: request.title),
            ),
          )
          .whenComplete(() => _opening = false),
    );
  }

  Future<void> _pan(Map<String, dynamic> args) async {
    if (!mounted || _opening) return;
    _opening = true;
    // Return to JavaScript immediately; selecting a source can take arbitrarily
    // long and must not leave an HTTP request waiting for user interaction.
    unawaited(_openPan(args).whenComplete(() => _opening = false));
  }

  Future<void> _openPan(Map<String, dynamic> args) async {
    try {
      final request = WebHomePlayback(args);
      final url = request.shareUrl;
      final uri = Uri.tryParse(url);
      if (uri == null || !{'http', 'https', 'magnet'}.contains(uri.scheme)) {
        throw const FormatException('网盘分享链接无效');
      }
      final service = CatService.instance;
      await service.boot();
      if (!mounted) return;
      final sites = [
        for (final record in service.subscriptions.where((s) => s.enabled))
          ...record.sites.where(
            (s) =>
                s.kind == 'video' &&
                PrivacySettings.instance.allowsSource(s.id, s.name),
          ),
      ];
      if (sites.isEmpty) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('需要网盘解析源'),
            content: const Text(
              '该地址是分享链接。请先在视频源中添加支持网盘分享链接的猫源，并完成该源的网盘登录，再回到这里播放。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
        return;
      }
      final site = await showModalBottomSheet<CatSite>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .6,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('选择支持此分享链接的猫源'),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('由所选猫源解析分享链接；需要在该源中登录网盘。'),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final site in sites)
                        ListTile(
                          title: Text(site.name),
                          onTap: () => Navigator.pop(context, site),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (site == null || !mounted) return;
      final library = await ReadingLibrary.open(Section.video);
      if (!mounted) return;
      final password = '${args['password'] ?? ''}'.trim();
      // Pass the URL exactly as authored; cloud providers differ in how they
      // encode extraction codes, so do not invent a universal query parameter.
      final itemId = password.isEmpty ? url : '$url 提取码: $password';
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => CatDetailPage(
              source: CatDataSource(service, site),
              item: SourceItem(
                id: itemId,
                title: request.title.isEmpty ? '网盘分享' : request.title,
              ),
              library: library,
            ),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('网盘解析源无法打开，请检查猫源配置后重试')));
      }
    }
  }

  Future<void> _back() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    if (_edge) {
      return Scaffold(
        backgroundColor: LumeTheme.base,
        body: Stack(
          children: [
            Positioned.fill(child: _body()),
            Positioned(
              top: MediaQuery.viewPaddingOf(context).top + 8,
              right: 8,
              child: IconButton.filledTonal(
                tooltip: '显示主页工具栏',
                onPressed: () {
                  setState(() => _edge = false);
                  unawaited(_sendViewport());
                },
                icon: const Icon(Icons.more_horiz),
              ),
            ),
          ],
        ),
      );
    }
    return GlassScaffold(
      effectModule: GlassModule.video,
      title: _title.isEmpty ? widget.source.name : _title,
      leading: IconButton(
        tooltip: '返回',
        icon: const LumeIcon(Icons.arrow_back, slot: 'web_home.back'),
        onPressed: _ready ? _back : null,
      ),
      actions: [
        IconButton(
          tooltip: '刷新',
          icon: const LumeIcon(Icons.refresh, slot: 'web_home.refresh'),
          onPressed: _ready ? () => _controller.reload() : null,
        ),
      ],
      child: _body(),
    );
  }

  Widget _body() => Column(
    children: [
      if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(
                _error!,
                style: TextStyle(color: LumeTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _controller.reload(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      Expanded(
        child: _ready
            ? WebViewWidget(controller: _controller)
            : const Center(child: CircularProgressIndicator()),
      ),
    ],
  );
}
