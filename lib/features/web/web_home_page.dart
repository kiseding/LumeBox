import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/player/player_experience_store.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/web/web_home_sources.dart';
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

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
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
          if (mounted) setState(() => _error = null);
        },
        onPageFinished: (_) async {
          final title = await _controller.getTitle();
          if (mounted && title != null && title.trim().isNotEmpty) {
            setState(() => _title = title.trim());
          }
        },
        onWebResourceError: (failure) {
          if (mounted && failure.isForMainFrame == true) {
            setState(() => _error = '网页加载失败，请检查网络或地址后重试');
          }
        },
        onNavigationRequest: (request) async {
          final uri = Uri.tryParse(request.url);
          if (uri == null) return NavigationDecision.prevent;
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
    final uri = widget.source.uri;
    if (uri == null) {
      if (mounted) setState(() => _error = '主页地址无效');
      return;
    }
    await _controller.loadRequest(uri);
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _back() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
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
    child: Column(
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
    ),
  );
}
