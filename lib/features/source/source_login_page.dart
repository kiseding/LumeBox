import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/net/ios_verified_webview.dart';
import '../../core/net/lume_http.dart';
import '../../core/net/site_session_pool.dart';
import '../../core/net/web_session_lifecycle.dart';
import '../../core/net/waf.dart';
import '../../core/session/section.dart';
import '../../core/cache/section_memory_cache.dart';

/// Login happens on the site's own page; saving credentials is not a login.
class SourceLoginPage extends StatefulWidget {
  const SourceLoginPage({
    super.key,
    required this.section,
    required this.sourceId,
    required this.name,
    required this.url,
    this.userAgent,
    this.loginMode = true,
  });
  final Section section;
  final String sourceId, name, url;
  final String? userAgent;
  final bool loginMode;
  static String status(Map evidence, Map<String, String> cookies) {
    if (evidence['blocked'] == true) return '站点拒绝访问或等待验证，请先在网页中处理';
    if (evidence['loggedIn'] == true) {
      return '已检测到站点登录，会话已同步；章节购买权限仍由站点决定';
    }
    if (evidence['loginForm'] == true) return '尚未登录，请在下方站点页面登录';
    if (cookies.keys.any((k) => k.startsWith('wordpress_logged_in_'))) {
      return '已同步登录凭据；请在站点个人中心核实会话是否有效';
    }
    return '会话已同步；本站未提供可识别的登录标志，请在个人中心核对';
  }

  @override
  State<SourceLoginPage> createState() => _SourceLoginPageState();
}

class _SourceLoginPageState extends State<SourceLoginPage> {
  late final controller = WebViewController();
  String status = '正在打开站点…';
  bool checking = false;
  late final ua =
      SiteSessionPool.shared.userAgentFor(widget.url) ??
      (widget.userAgent?.trim().isNotEmpty == true
          ? widget.userAgent!
          : WafSessions.userAgentFor(widget.section, widget.sourceId) ??
                LumeHttp.defaultUserAgent);
  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setUserAgent(ua);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (request.isMainFrame &&
                uri?.host == Uri.parse(widget.url).host &&
                RegExp(
                  r'logout|log-out|signout|customer-logout',
                  caseSensitive: false,
                ).hasMatch('${uri?.path}?${uri?.query}')) {
              WebSessionLifecycle.invalidate(
                hosts: {Uri.parse(widget.url).host},
              );
              WafSessions.storeOf(widget.section)?.clear(widget.sourceId);
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (_) => unawaited(_check()),
          onWebResourceError: (e) {
            if (mounted && e.isForMainFrame == true) {
              setState(() => status = '网页加载失败，可刷新重试');
            }
          },
        ),
      );
      final uri = Uri.parse(widget.url);
      if (!['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException();
      }
      await controller.loadRequest(uri);
    } catch (_) {
      if (mounted) setState(() => status = '站点网页无法打开，请检查地址与网络');
    }
  }

  Future<void> _check() async {
    if (checking || !mounted) return;
    setState(() => checking = true);
    try {
      final current = Uri.tryParse(await controller.currentUrl() ?? '');
      if (current?.host != Uri.parse(widget.url).host) {
        if (mounted) setState(() => status = '请完成授权并返回原站点后检查登录');
        return;
      }
      final raw = await controller.runJavaScriptReturningResult(
        '''JSON.stringify({
        loggedIn:document.body.classList.contains('logged-in') || !!document.querySelector('a[href*="action=logout"],a[href*="customer-logout"]'),
        loginForm:!!document.querySelector('input[type="password"]'),
        blocked:/Sorry, you have been blocked|Just a moment|Attention Required/i.test(document.title+' '+document.body.innerText.slice(0,500))
      })''',
      );
      var parsed = jsonDecode('$raw');
      if (parsed is String) parsed = jsonDecode(parsed);
      final native = await IosVerifiedWebView.channel
          .invokeMethod<List<Object?>>('allCookies', {'url': widget.url});
      final cookies = webViewCookiesForUrl(native ?? [], widget.url);
      await SiteSessionPool.shared.synchronize(widget.url, {'User-Agent': ua});
      WafSessions.save(widget.section, widget.sourceId, cookies);
      WafSessions.saveUserAgent(widget.section, widget.sourceId, ua);
      SectionMemoryCache.instance.removeSource(widget.section, widget.sourceId);
      if (mounted) {
        setState(
          () => status = SourceLoginPage.status(
            parsed is Map ? parsed : {},
            cookies,
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => status = '未能核实登录状态，请在站点个人中心确认后重试检查');
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${widget.name} · ${widget.loginMode ? '登录' : '作品网页'}'),
      actions: [
        IconButton(
          tooltip: '刷新网页',
          onPressed: controller.reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(child: Text(status)),
              TextButton(
                onPressed: checking ? null : _check,
                child: Text(checking ? '检查中…' : '检查登录'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            widget.loginMode
                ? '在站点网页中登录后点击检查。完成后返回原章节点重试。'
                : '可在本站网页中选择章节阅读；若仍显示拒绝访问，说明站点也拦截了当前网页连接。',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        Expanded(child: WebViewWidget(controller: controller)),
      ],
    ),
  );
}
