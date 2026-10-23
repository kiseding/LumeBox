import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:lume_box/core/cat/cat_web_parse.dart';
import 'package:lume_box/features/video/source_web_player_page.dart';

class _Platform extends WebViewPlatform {
  late _Controller controller;
  int created = 0, views = 0, disposedViews = 0;
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    created++;
    return controller = _Controller(params);
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _Delegate(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _View(params, this);
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();
  final loads = <Uri>[];
  final scripts = <String>[];
  int reloads = 0;
  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loads.add(params.uri);
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}
  @override
  Future<void> setUserAgent(String? userAgent) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}
  @override
  Future<void> runJavaScript(String javaScript) async {
    scripts.add(javaScript);
  }

  @override
  Future<void> reload() async {
    reloads++;
  }
}

class _Delegate extends PlatformNavigationDelegate {
  _Delegate(super.params) : super.implementation();
  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}
  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

class _View extends PlatformWebViewWidget {
  _View(super.params, this.owner) : super.implementation();
  final _Platform owner;
  @override
  Widget build(BuildContext context) => _TrackingView(owner: owner);
}

class _TrackingView extends StatefulWidget {
  const _TrackingView({required this.owner});
  final _Platform owner;
  @override
  State<_TrackingView> createState() => _TrackingViewState();
}

class _TrackingViewState extends State<_TrackingView> {
  @override
  void initState() {
    super.initState();
    widget.owner.views++;
  }

  @override
  void dispose() {
    widget.owner.disposedViews++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  late _Platform platform;
  setUp(() {
    platform = _Platform();
    WebViewPlatform.instance = platform;
  });
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SourceWebPlayerPage(
          request: CatWebParseRequired(
            Uri.parse('https://play.example/watch/1'),
            {},
            webPlayer: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('网页播放全屏切换保留同一页面，刷新不创建第二控制器', (tester) async {
    await open(tester);
    expect(find.text(SourceWebPlayerPage.limitations), findsOneWidget);
    expect(platform.views, 1);
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    expect(platform.views, 1);
    expect(platform.disposedViews, 0);
    await tester.tap(find.byTooltip('退出全屏'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新'));
    expect(platform.controller.reloads, 1);
    expect(platform.created, 1);
    expect(platform.controller.loads.length, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(platform.controller.loads.last.toString(), 'about:blank');
  });
  testWidgets('进入后台暂停媒体，恢复前台不自动播放，退出停止页面', (tester) async {
    await open(tester);
    tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    await tester.pump();
    expect(platform.controller.scripts.last, contains('media.pause()'));
    final scripts = platform.controller.scripts.length;
    tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pump();
    expect(platform.controller.scripts.length, scripts);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(platform.controller.loads.last.toString(), 'about:blank');
    expect(tester.takeException(), isNull);
  });
}
