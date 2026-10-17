import '../../shared/widgets/module_glass_scope.dart';

import 'package:flutter/rendering.dart' show ScrollDirection;

import '../../core/theme/floating_modules.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';

import '../../core/session/app_preferences.dart';
import '../../core/session/configuration_backup.dart';

import '../../core/net/waf.dart';
import '../../core/net/waf_auto_verify.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/shell/shell_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../cat/cat_page.dart';
import '../cat/cat_preloader.dart';
import '../../core/cat/cat_service.dart';
import '../comic/comic_page.dart';
import '../novel/novel_page.dart';
import '../settings/settings_page.dart';
import '../source/waf_webview_page.dart';
import '../video/video_page.dart';
import 'section_preloader.dart';
import 'shell_dock.dart';
import '../../core/source/source_subscription_sync.dart';
import '../../shared/widgets/dock_handle_button.dart';

/// 主导航：五个页签（小说 / 漫画 / 视频 / 猫源 / 设置）。
///
/// 移动端是底部悬浮 Dock（毛玻璃胶囊）；桌面端（Windows / macOS / Linux）
/// 自动换成左侧 NavigationRail —— 同一套页签，两种排布，页签内容不变。
///
/// **页签的身份是标识（[ShellTab.id]）而不是下标**：用户可以在设置里隐藏页签、
/// 拖拽排序（见 [ShellSettings]），下标会随着这两件事漂移。当前选中、可见性、
/// 顺序全部按标识走，因此「把当前页签拖到别处」不会导致跳到别的板块。
///
/// 资源纪律：**只把当前页签的页面挂在树上**，切走即销毁、切回重建。因此
/// 板块的阅读库、图源运行时、sqlite 句柄都沿用「进板块打开、退出板块释放」
/// 的既有口径，四个板块的资源不会同时驻留（这不是 IndexedStack 那种全挂载）。
///
/// 全屏页（阅读器 / 播放器）压栈时 Dock 由 [ShellDockObserver] 自动隐藏，
/// 出栈后恢复；视频页在播放中隐藏 Dock 走 [ShellDockScope] 的令牌。
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.controller,
    this.desktopRail,
    this.pageBuilder,
  });

  /// 底部 Dock 的定位键（测试按它确认 Dock 存在与隐藏）。
  static const Key dockKey = Key('shell.dock');

  /// 左侧栏的定位键。
  static const Key railKey = Key('shell.rail');

  /// 「设置页被隐藏」时的恢复入口定位键。
  ///
  /// 见 [ShellSettings] 的硬约束 2：设置页是导航栏管理的入口，把它藏起来之后
  /// 用户再也进不去管理页——因此隐藏时壳层一定留一个小的设置入口。
  static const Key settingsEntryKey = Key('shell.settingsEntry');

  /// Dock 显隐控制器；为空时自建（独立测试用；正式入口由 [MaterialApp] 传入
  /// 同一个实例，与导航观察者共享）。
  final ShellDockController? controller;

  /// 是否用左侧栏；为空时按平台判断（桌面端 → NavigationRail）。
  final bool? desktopRail;

  /// 仅测试 / 截图预览用：替换页签页面（为空时用正式页面）。
  ///
  /// 材质预览需要「真实壳层 + 真实 Dock」压在一块彩色内容上，才能看出
  /// 毛玻璃透出的效果；正式入口永远不传这个参数。
  @visibleForTesting
  final Widget Function(String id)? pageBuilder;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final ShellDockController _controller =
      widget.controller ?? ShellDockController();

  /// 底部导航栏配置（逐项开关 + 顺序）。壳层监听它：改完立刻生效，
  /// 不必等用户切页签或重启。
  final ShellSettingsController _shellSettings =
      ShellSettingsController.instance;

  /// 自建的控制器要自己释放；外部传进来的由外部负责。
  late final bool _ownsController = widget.controller == null;

  /// 当前页签的**标识**（不是下标：顺序会变、页签会隐藏）。
  String _activeId = _pageCatalog.first.id;
  bool _scrollCollapsed = false;

  /// 收起悬浮球上的水平拖动累计距离：向右滑超过阈值就展开 Dock。
  double _handleDrag = 0;
  Timer? _backgroundWarmTimer;
  Timer? _subscriptionTimer;
  int _seenSubscriptionChanges = 0;
  bool _foreground = true;
  final _backgroundWarmed = <String>{};
  bool _backgroundWarming = false;

  // 手机导航条使用完整安全区避让；玻璃胶囊内只摆图标与文字。

  /// Dock 外观（尺寸 / 边框 / 阴影 / 动效）：由「设置 → 底部导航栏管理」实时改。
  ///
  /// 默认值就是上一轮精修后的取值（左右 24、高度 54、安全区上方 4）；
  /// 每个字段都在 [DockAppearance.fromJson] 里收敛过范围，壳层直接读即可。
  static DockAppearance get _dockAppearance =>
      ShellSettingsController.instance.settings.appearance;

  static double get _dockHeight => _dockAppearance.height;
  static double get _dockMargin => _dockAppearance.horizontalMargin;
  static double get _dockSafeGap => _dockAppearance.safeGap;
  static const double _dockInnerPadding = 6;
  static const double _dockBottomMargin = 0;
  static const double _dockSpacing = 8;

  static double dockMarginFor(double availableWidth) => _dockMargin;
  static double dockContentInset(BuildContext context) => 0;
  static double dockBottomOffset(BuildContext context) =>
      (MediaQuery.viewPaddingOf(context).bottom + _dockSafeGap)
          .clamp(0, 128)
          .toDouble() +
      _dockBottomMargin;

  /// 页签目录：标识 + 展示文案 + 两个图标 + 页面构造。
  ///
  /// 文案用 [Section.label]（展示口径：视频 = Section.video），板块的库、缓存、
  /// 图源归属仍走 Section.id，与展示文案无关。
  static final List<_ShellTab> _pageCatalog = <_ShellTab>[
    _ShellTab(
      id: ShellTab.all[0].id,
      label: Section.novel.label,
      icon: Icons.menu_book_outlined,
      selectedIcon: Icons.menu_book_rounded,
      builder: () => const NovelPage(),
    ),
    _ShellTab(
      id: ShellTab.all[1].id,
      label: Section.comic.label,
      icon: Icons.auto_stories_outlined,
      selectedIcon: Icons.auto_stories_rounded,
      builder: () => const ComicPage(),
    ),
    _ShellTab(
      id: ShellTab.all[2].id,
      label: Section.video.label,
      icon: Icons.play_circle_outline_rounded,
      selectedIcon: Icons.play_circle_fill_rounded,
      builder: () => const VideoPage(),
    ),
    _ShellTab(
      id: ShellTab.all[3].id,
      label: Section.cat.label,
      icon: Icons.pets_outlined,
      selectedIcon: Icons.pets_rounded,
      builder: () => const CatPage(),
    ),
    _ShellTab(
      id: ShellTab.all[4].id,
      label: '设置',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      builder: () => const SettingsPage(),
    ),
  ];

  static _ShellTab _pageOf(String id) => _pageCatalog.firstWhere(
    (tab) => tab.id == id,
    // 配置里出现目录之外的标识理论上不会发生（fromJson 会过滤），
    // 兜底回第一个页签，绝不让壳层因为一份坏配置打不开。
    orElse: () => _pageCatalog.first,
  );

  /// 可见页签（按用户配置的顺序）——移动端 Dock 用。
  List<_ShellTab> get _visibleTabs => <_ShellTab>[
    for (final config in _shellSettings.settings.visibleTabs)
      _pageOf(config.id),
  ];

  /// 全部页签（按用户配置的顺序）——桌面端左侧栏用。
  ///
  /// 桌面端**不跟随「隐藏」**，只跟随顺序：左侧栏是桌面端的标准布局，页签少一个
  /// 会让工具栏看起来像坏了。更要紧的是，Rail 上没有移动端那个左下角恢复入口，
  /// 若这里也按可见性过滤，「隐藏设置」就会把桌面用户彻底锁死——设置页是导航栏
  /// 管理自己的入口，藏起来之后再也进不去（见 [ShellSettings] 硬约束 2）。
  List<_ShellTab> get _orderedTabs => <_ShellTab>[
    for (final config in _shellSettings.tabs) _pageOf(config.id),
  ];

  /// 当前布局**实际渲染 / 实际可达**的页签集合。
  ///
  /// 「当前页签被隐藏后落到哪里」要以它为基准：桌面端隐藏的页签仍在 Rail 上、
  /// 仍点得到，就不该把用户从当前页面赶走；移动端则会从 Dock 上消失，必须落回
  /// 一个还看得见的页签，否则用户会停在「底部找不到自己位置」的页面上。
  ///
  /// 移动端的**设置页恒为可达**：它在 Dock 上时点得到，被隐藏时左下角还有恢复
  /// 入口（见 [_buildSettingsEntry]）。这一点必须体现在这里，否则会踩一个很难
  /// 发现的坑——用户隐藏设置 → 点左下角入口进设置 → 在管理页里改任意一个页签，
  /// 就会被当成「停在一个不可达的页签上」而被弹回小说板块，于是**永远改不完配置**。
  List<_ShellTab> get _reachableTabs {
    final rail = widget.desktopRail ?? _isDesktopPlatform;
    if (rail) return _orderedTabs;
    final tabs = _visibleTabs;
    if (tabs.any((tab) => tab.id == ShellTab.settingsId)) return tabs;
    return <_ShellTab>[...tabs, _pageOf(ShellTab.settingsId)];
  }

  /// 桌面端：Windows / macOS / Linux 自动用侧边栏（移动端保持底部 Dock）。
  static bool get _isDesktopPlatform {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    for (final section in Section.values) {
      _seenSubscriptionChanges += SourceSubscriptionSync.changeCount(section)
          .value;
      SourceSubscriptionSync.changeCount(section)
          .addListener(_onSubscriptionChanges);
    }
    _startSubscriptionMonitor();
    _syncSubscriptions();
    _scheduleBackgroundWarm();
    _shellSettings.addListener(_onShellSettingsChanged);
    // 装上「自动过 WAF 校验」的钩子（用户口径 2 / 3 / 4）：脚本抛
    // NEED_WEBVIEW_VERIFY 时，引擎层（没有 BuildContext）回调到这里，由壳层弹那个
    // 小悬浮窗；拿到 Cookie 后引擎自动重试刚才那次调用，用户基本无感。
    WafAutoVerify.install(({
      required Section section,
      required String sourceId,
      required String sourceName,
      required String url,
    }) {
      // 引擎层已经走过四层兜底链；这里再兜一次，是为了那些「只把脚本原文递上来」
      // 的调用点（老脚本的标记文案里没有 URL）：没有地址就弹不出窗口，
      // 而「弹不出来」正是用户反馈的「点/报错之后什么也没发生」。
      final target = url.trim().isEmpty
          ? resolveWebViewOrigin(sourceId: sourceId)
          : url.trim();
      if (target == null || target.isEmpty) {
        LumeLog.warn('[waf] $sourceId 自动校验拿不到站址，交给页面上的手动出口');
        return Future<bool>.value(false);
      }
      // 验证窗与 API 请求用同一个 UA：`cf_clearance` 绑 IP + UA；而且 WKWebView
      // 默认 UA 不带 `Safari/…`，CF 会给一张渲染不出勾选框的白页。
      return LumeSources.userAgentFor(section, sourceId).then((userAgent) {
        if (!mounted) return false;
        return showWafAutoVerify(
          context: context,
          section: section,
          sourceId: sourceId,
          sourceName: sourceName,
          url: target,
          userAgentOverride: userAgent,
        );
      });
    });
  }

  @override
  void dispose() {
    _subscriptionTimer?.cancel();
    for (final section in Section.values) {
      SourceSubscriptionSync.changeCount(section)
          .removeListener(_onSubscriptionChanges);
    }
    _backgroundWarmTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _shellSettings.removeListener(_onShellSettingsChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _syncSubscriptions({bool force = false}) {
    for (final section in Section.values) {
      if (section != Section.cat && LumeSources.runtimeAvailableFor(section)) {
        unawaited(SourceSubscriptionSync.refresh(section, force: force));
      }
    }
  }

  void _startSubscriptionMonitor() {
    _subscriptionTimer?.cancel();
    if (kIsWeb || !(Platform.isIOS || Platform.isAndroid)) return;
    _subscriptionTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_foreground) {
        _syncSubscriptions(force: true);
        if (AppPreferences.instance.autoBackup) {
          unawaited(() async {
            try {
              await ConfigurationBackup().automatic();
            } catch (error) {
              LumeLog.warn('自动备份失败：$error');
            }
          }());
        }
      }
    });
  }

  void _onSubscriptionChanges() {
    final total = Section.values.fold<int>(
      0,
      (sum, section) => sum + SourceSubscriptionSync.changeCount(section).value,
    );
    final difference = total - _seenSubscriptionChanges;
    _seenSubscriptionChanges = total;
    if (difference <= 0) return;
    // Update badges and source-row notices provide persistent feedback.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _syncSubscriptions();
      _startSubscriptionMonitor();
      _backgroundWarmed.clear();
      _scheduleBackgroundWarm();
    } else {
      _subscriptionTimer?.cancel();
      _backgroundWarmTimer?.cancel();
    }
  }

  void _onShellSettingsChanged() {
    if (!mounted) return;
    setState(() {
      // 当前页签被隐藏了（用户刚把它关掉）：落到第一个仍可达的页签上。
      // 不这么做的话页面会停在一个已经不在导航栏里的页签上——用户看得见内容，
      // 却在底部找不到自己在哪里。桌面端 Rail 不过滤可见性（见 [_reachableTabs]），
      // 因此桌面端不会因为「隐藏」把用户从当前页面赶走。
      final reachable = _reachableTabs;
      if (reachable.isNotEmpty &&
          !reachable.any((tab) => tab.id == _activeId)) {
        _activeId = reachable.first.id;
      }
    });
  }

  void _select(String id) {
    if (id == _activeId) return;
    AppPreferences.instance.selectionFeedback();
    // **先预热再切**（真机反馈：切板块要等、进页面才开始发请求）。这里趁手指刚
    // 点下去、页面还没构建的那一小段，把板块运行时（阅读库 + 源引擎）与首页
    // 第一页提前拉起来；页面构建后能直接吃这口热饭。
    // 预热失败不影响任何事（页面照旧自己取），见 [SectionPreloader]。
    unawaited(_warmUp(id));
    setState(() {
      _activeId = id;
      _scrollCollapsed = false;
    });
  }

  Future<void> _warmUp(String id) async {
    final section = sectionFromId(id);
    if (section == null) return;
    if (section == Section.cat) {
      if (LumeSources.runtimeAvailableFor(Section.cat)) {
        await CatPreloader.warm(CatService.instance);
      }
      return;
    }
    if (!LumeSources.runtimeAvailableFor(section)) return;
    await SectionPreloader.warm(
      section,
      manager: LumeSources.manager(section),
      openLibrary: () => ReadingLibrary.open(section).then((_) {}),
    );
  }

  void _scheduleBackgroundWarm() {
    _backgroundWarmTimer?.cancel();
    if (!mounted ||
        !_foreground ||
        !_visibleTabs.any((t) {
          final section = sectionFromId(t.id);
          return section != null && LumeSources.runtimeAvailableFor(section);
        })) {
      return;
    }
    _backgroundWarmTimer = Timer(
      const Duration(seconds: 3),
      () => unawaited(_warmNext()),
    );
  }

  Future<void> _warmNext() async {
    if (!mounted || !_foreground || _backgroundWarming) return;
    if (!_controller.visible || ModalRoute.of(context)?.isCurrent == false) {
      _scheduleBackgroundWarm();
      return;
    }
    final target = _visibleTabs
        .where(
          (t) =>
              t.id != _activeId &&
              sectionFromId(t.id) != null &&
              !_backgroundWarmed.contains(t.id),
        )
        .firstOrNull;
    if (target == null) return;
    _backgroundWarming = true;
    _backgroundWarmed.add(target.id);
    try {
      await _warmUp(target.id);
    } finally {
      _backgroundWarming = false;
      if (mounted) _scheduleBackgroundWarm();
    }
  }

  @override
  Widget build(BuildContext context) {
    final rail = widget.desktopRail ?? _isDesktopPlatform;
    // 依赖主题：切亮暗 / 换主题色时壳层整体重建（Dock 的磨砂底色、页签图标颜色
    // 都是静态色名，不重建就会留在旧主题里）。
    Theme.of(context);
    // 悬浮 Dock（含悬浮留白）占掉的底部高度：交给页面当**滚动尾部内边距**用
    // （见 [ShellDockScope.dockInset]），不再注入 MediaQuery——注入等于给每个页面
    // 固定留一大块底部空白，没滚到底时也空着（用户口径：改成动态边距）。
    final dockInset = rail
        ? 0.0
        : dockBottomOffset(context) +
              _dockHeight +
              dockContentInset(context) +
              _dockSpacing;
    return ShellDockScope(
      controller: _controller,
      dockInset: dockInset,
      child: rail ? _buildRail() : _buildDock(),
    );
  }

  // ------------------------------------------------------------------ 移动端

  /// 恢复入口收起时下滑的距离（逻辑像素）。
  ///
  /// 必须把它**悬浮在 Dock 之上的那段**（底栏高 + 上下留白，约 96）与**自身高度**
  /// 一起算进去：只滑「自身高度」会让按钮停在屏幕里，等于没藏。
  /// 用绝对像素而不是 `AnimatedSlide` 的「自身尺寸倍数」：那个倍数会随图标内边距
  /// 变化而漂移，是条看不见的耦合。这里多给一点余量，滑出屏幕即可。
  static double get _entryHideTravel =>
      _dockHeight + _dockMargin + _dockBottomMargin + _dockSpacing + 64;

  /// 「设置页被隐藏」时的恢复入口。
  ///
  /// 这是硬约束不是装饰：设置页是「底部导航栏管理」自己的入口。把它藏起来之后，
  /// 用户再也进不去管理页把别的页签打开——「至少保留 1 个页签」拦不住这种锁死
  /// （另外 4 个板块都还在，但没有任何一个能进设置）。
  ///
  /// 放在**左下角**：右下角是页面 FAB 的地盘（源总管理 / 漫画仓库页的「+」），
  /// 放右下会重叠（实测两个矩形相交）。
  ///
  /// **跟随 Dock 显隐**（[visible]）：这个入口是导航壳的一部分，底栏藏起来时
  /// 它也得藏。最典型的是视频播放中——壳层为「沉浸观看」把 Dock 收起，此时
  /// 左下角恰好是**亮度手势区**，一个浮在那里的齿轮按钮既挡画面又抢手势。
  Widget _buildSettingsEntry({required bool visible}) {
    return Positioned(
      left: 0,
      right: 0,
      // 落在 Dock 上方一档。
      bottom:
          dockBottomOffset(context) +
          _dockHeight +
          dockContentInset(context) +
          _dockSpacing,
      // 与胶囊左沿对齐：留白同样按**布局宽度**算（见 [dockMarginFor]）。
      child: LayoutBuilder(
        builder: (context, constraints) => Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.only(
              left:
                  dockMarginFor(constraints.maxWidth) +
                  MediaQuery.viewPaddingOf(context).left,
            ),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(
                begin: 0,
                end: visible ? 0 : _entryHideTravel,
              ),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              builder: (context, dy, child) =>
                  Transform.translate(offset: Offset(0, dy), child: child),
              child: IgnorePointer(
                ignoring: !visible,
                child: Tooltip(
                  message: '设置（底部导航栏里已隐藏）',
                  child: Material(
                    key: AppShell.settingsEntryKey,
                    color: LumeTheme.surface,
                    shape: const CircleBorder(),
                    elevation: 3,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _select(ShellTab.settingsId),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(
                          Icons.settings_outlined,
                          size: 22,
                          color: LumeTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDock() {
    final tabs = _visibleTabs;
    final settingsHidden = !_shellSettings.settingsVisible;
    // 胶囊里内容避让手势条的那一档（外框贴屏幕底边，内容往上缩）。
    final contentInset = dockContentInset(context);
    return Scaffold(
      extendBody: true,
      body: Stack(
        children: <Widget>[
          NotificationListener<UserScrollNotification>(
            onNotification: (notification) {
              if (notification.depth != 0 ||
                  notification.metrics.axis != Axis.vertical ||
                  notification.direction == ScrollDirection.idle) {
                return false;
              }
              final collapsed =
                  notification.direction == ScrollDirection.reverse;
              if (_scrollCollapsed != collapsed) {
                setState(() => _scrollCollapsed = collapsed);
              }
              return false;
            },
            child: _buildPage(),
          ),
          if (settingsHidden)
            // 与底栏同一个显隐来源：Dock 收起（播放中 / 全屏页压栈）时，
            // 恢复入口一并收起。
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => _buildSettingsEntry(
                visible:
                    _controller.visible &&
                    MediaQuery.viewInsetsOf(context).bottom == 0,
              ),
            ),
        ],
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          // 从左侧滑出/收回，而不是点一下突然闪现。
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(-0.25, 0),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          child:
              _scrollCollapsed &&
                  _controller.visible &&
                  MediaQuery.viewInsetsOf(context).bottom == 0
              ? Padding(
                  padding: EdgeInsets.only(
                    left: 8,
                    bottom: dockBottomOffset(context),
                  ),
                  child: Align(
                    heightFactor: 1,
                    alignment: Alignment.centerLeft,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) => _handleDrag = 0,
                      onHorizontalDragUpdate: (details) =>
                          _handleDrag += details.delta.dx,
                      onHorizontalDragEnd: (details) {
                        final velocity = details.primaryVelocity ?? 0;
                        if (_handleDrag > 24 || velocity > 160) {
                          setState(() => _scrollCollapsed = false);
                        }
                        _handleDrag = 0;
                      },
                      child: DockHandleButton(
                        key: AppShell.dockKey,
                        style: _shellSettings.handleStyle,
                        opacity: .86,
                        onPressed: () =>
                            setState(() => _scrollCollapsed = false),
                      ),
                    ),
                  ),
                )
              : _DockBar(
                  key: AppShell.dockKey,
                  tabs: tabs,
                  activeId: _activeId,
                  onSelect: _select,
                  visible:
                      _controller.visible &&
                      MediaQuery.viewInsetsOf(context).bottom == 0,
                  appearance: _dockAppearance,
                  contentInset: contentInset,
                  bottomMargin: dockBottomOffset(context),
                ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 桌面端

  Widget _buildRail() {
    // 桌面端：左侧栏**始终显示全部页签**（桌面端标准布局），顺序跟随用户配置——
    // 顺序是用户的肌肉记忆，两个端保持一致更不容易点错。
    //
    // 刻意不按可见性过滤：Rail 上没有移动端那个左下角恢复入口，过滤之后
    // 「隐藏设置」会把桌面用户彻底锁死（见 [_orderedTabs]）。
    final tabs = _orderedTabs;
    final activeIndex = tabs.indexWhere((tab) => tab.id == _activeId);
    return Scaffold(
      body: Row(
        children: <Widget>[
          NavigationRail(
            key: AppShell.railKey,
            selectedIndex: activeIndex < 0 ? 0 : activeIndex,
            onDestinationSelected: (index) => _select(tabs[index].id),
            labelType: NavigationRailLabelType.all,
            backgroundColor: LumeTheme.surface,
            indicatorColor: const Color(0x1A7C5CFF),
            destinations: <NavigationRailDestination>[
              for (final tab in tabs)
                NavigationRailDestination(
                  icon: Icon(tab.icon),
                  selectedIcon: Icon(tab.selectedIcon),
                  label: Text(tab.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _buildPage()),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------- 页面

  /// 当前页签的页面：只建当前这一个，切页签即热替换（旧页签资源随之释放）。
  ///
  /// Key 用页签**标识 + 主题身份**：
  /// - 页签标识——同一页签在顺序变化时不该被重建（换了 key 会让板块的阅读库、
  ///   滚动位置一起丢），而切到另一个页签必须重建（资源释放的既有口径）；
  /// - 主题身份——切亮暗 / 换主题色时**整页重建**，静态色名（`LumeTheme.*`）
  ///   才会重新取值。少了它，切主题后页面里只读静态色名的部件会留在旧配色上
  ///   （真机现象：设置页里两张**内容为 const 的分组卡**在深色下仍是白底、
  ///   文字却是深色主题的浅色，糊成一片）。代价：切主题会重建当前页签，
  ///   页内滚动位置等局部状态归零——这是静态色名架构下的取舍。
  Widget _buildPage() => KeyedSubtree(
    key: ValueKey<String>('$_activeId·${LumeTheme.themeId}'),
    child: ModuleGlassScope(
      module: GlassModule.fromId(_activeId),
      child:
          widget.pageBuilder?.call(_activeId) ?? _pageOf(_activeId).builder(),
    ),
  );
}

/// 一个页签：标识 + 展示文案 + 两个图标（未选中 / 选中）+ 页面构造。
class _ShellTab {
  const _ShellTab({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
  });

  /// 稳定标识（与 [ShellTab.id] 同源）：配置、选中、key 都按它走。
  final String id;

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function() builder;
}

/// 底部悬浮 Dock：浅色毛玻璃胶囊，各项等宽，选中项品牌紫 + 高亮底座。
///
/// 选中底座用缩放 + 透明度过渡（250ms，easeOutBack），不是直接增删组件——
/// 切换页签时底座会像水滴一样轻微弹一下，而不是硬闪一块色。
///
/// 它悬在页面内容之上（`extendBody`），因此底下的列表与封面会从胶囊里透出来——
/// 全 App 玻璃感最明显的一处。
///
/// 项数可变（用户可隐藏页签，最少 1 项最多 5 项），各项等宽由 `Expanded` 平分。
class _DockBar extends StatelessWidget {
  const _DockBar({
    super.key,
    required this.tabs,
    required this.activeId,
    required this.onSelect,
    required this.visible,
    required this.appearance,
    required this.contentInset,
    required this.bottomMargin,
  });

  final List<_ShellTab> tabs;
  final String activeId;
  final ValueChanged<String> onSelect;
  final bool visible;

  /// 尺寸 / 玻璃边缘 / 投影 / 动效（设置页实时改）。
  final DockAppearance appearance;

  /// 胶囊**内部**给系统手势条让出的高度：外框照样画到底，只是里面的
  /// 图标与文字往上缩这一段（用户口径 6）。
  final double contentInset;

  /// 胶囊外框离屏幕底边的距离：0 = 外框直接画到屏幕底边（用户口径 6）。
  final double bottomMargin;

  /// 胶囊总高（外框）= 内容条 + 手势条避让。
  double get capsuleHeight => appearance.height + contentInset;

  /// 胶囊投影：默认极淡（约 5%），只交代「浮起」，不压成一块板。
  BoxShadow get _dockShadow => BoxShadow(
    color: Colors.black.withValues(alpha: appearance.shadowOpacity),
    blurRadius: 20,
    offset: const Offset(0, 6),
  );

  /// 深色主题下把边框强度按比例柔化：白色 1px 在暗底上比亮底醒目得多，
  /// 默认 50% 直接照搬会变成一圈硬描边（预览里 22% 左右才像玻璃反光）。
  double get _borderAlpha {
    final dark = LumeTheme.palette.brightness == Brightness.dark;
    return dark ? appearance.borderOpacity * 0.44 : appearance.borderOpacity;
  }

  @override
  Widget build(BuildContext context) {
    // 左右留白按**布局宽度**算（见 [_AppShellState.dockMarginFor]）：收窄 + 居中。
    return ListenableBuilder(
      listenable: FloatingModules.instance,
      builder: (context, _) {
        final style = FloatingModules.instance.style(FloatingModule.dock);
        final dark = LumeTheme.palette.brightness == Brightness.dark;
        // 上下内边距跟着高度走：48pt 时收到 3，64pt 时放到 10；图标槽 22 +
        // 间距 4 + 文字 14.4 这一组内容高度不变，因此任何档位都不会挤爆。
        final verticalPadding = ((appearance.height - 42) / 2).clamp(2.0, 10.0);
        return Transform.translate(
          offset: Offset(style.x, style.y),
          child: IgnorePointer(
            ignoring: !visible,
            child: ExcludeSemantics(
              excluding: !visible,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final margin = _AppShellState.dockMarginFor(
                    constraints.maxWidth,
                  );
                  final safe = MediaQuery.viewPaddingOf(context);
                  // 隐藏时整块（含内边距）平移到屏幕下沿之外，不占视觉、不响应点击。
                  return AnimatedSlide(
                    offset: visible ? Offset.zero : const Offset(0, 1.2),
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    // **不套 SafeArea**（用户口径 6）：胶囊外框直接画到屏幕底边，
                    // 给手势条让路的是**里面的内容**——见下面的 [contentInset]。
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        margin + safe.left,
                        0,
                        margin + safe.right,
                        bottomMargin,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          // 圆角椭圆（胶囊）：半径取容器高度的一半，容器越薄越像胶囊。
                          borderRadius: BorderRadius.circular(
                            capsuleHeight / 2,
                          ),
                          boxShadow: <BoxShadow>[_dockShadow],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            capsuleHeight / 2,
                          ),
                          child: BackdropFilter(
                            // 参考图口径：模糊 10–15（默认 12），背景色块被糊开
                            // 但仍能看出颜色走向，才有「透过去」的玻璃感。
                            filter: ImageFilter.blur(
                              sigmaX: style.blur,
                              sigmaY: style.blur,
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                // 浅色：纯白半透明（默认 65%），不是实心塑料白；
                                // 深色：沿用深玻璃，否则深色主题会被一条白条割开。
                                color: (dark ? LumeTheme.glass : Colors.white)
                                    .withValues(alpha: style.opacity),
                                borderRadius: BorderRadius.circular(
                                  capsuleHeight / 2,
                                ),
                                // 玻璃边缘的极细反光（1px），强度由设置页控制。
                                border: Border.all(
                                  color: Colors.white.withValues(
                                    alpha: _borderAlpha,
                                  ),
                                ),
                              ),
                              child: SizedBox(
                                height: capsuleHeight,
                                child: Padding(
                                  // 内容往上缩：底部这一段只留给手势条（这一段也不响应点击——
                                  // 手指从屏幕底边往上划是系统手势，不该先打到胶囊里的按钮）。
                                  padding: EdgeInsets.only(
                                    bottom: contentInset,
                                  ),
                                  // 胶囊收窄之后，首尾两项离圆角留一档内边距：五项之间的净间距
                                  // 跟着一起收紧（用户口径：内部 tab 间距同步收紧）。
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal:
                                          _AppShellState._dockInnerPadding,
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: <Widget>[
                                        for (final tab in tabs)
                                          Expanded(
                                            child: _DockItem(
                                              tab: tab,
                                              selected: tab.id == activeId,
                                              onTap: () => onSelect(tab.id),
                                              verticalPadding: verticalPadding,
                                              animateSelection:
                                                  appearance.animateSelection,
                                              animationDuration: Duration(
                                                milliseconds:
                                                    appearance.animationMs,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.verticalPadding,
    required this.animateSelection,
    required this.animationDuration,
  });

  final _ShellTab tab;
  final bool selected;
  final VoidCallback onTap;

  /// 上下内边距：由 Dock 高度反推（48–64 档位里保持内容高度不变）。
  final double verticalPadding;

  /// 设置页的「点击弹跳动效」开关；关闭时所有过渡时长归零（立即切换）。
  final bool animateSelection;

  /// 选中底座 / 图标 / 文字过渡时长（设置页可调，150–400ms）。
  final Duration animationDuration;

  /// 实际生效的时长：关掉动效时直接跳到终态。
  Duration get _selectionDuration =>
      animateSelection ? animationDuration : Duration.zero;

  static const Curve _selectionInCurve = Curves.easeOutBack;
  static const Curve _selectionOutCurve = Curves.easeInCubic;

  /// 图标槽固定高度（选中底座 20 图标 + 上下各 1 = 22）。
  ///
  /// 选中 / 未选中都占同一格，切换时文字不会被底座的增删顶得跳一下。
  static const double _iconSlot = 22;

  @override
  Widget build(BuildContext context) {
    final color = selected ? LumeTheme.accent : LumeTheme.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      // 高度由设置页给；上下内边距按高度反推，图标槽 22 + 间距 4 + 文字 14.4
      // 始终在剩余空间里垂直居中。
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: verticalPadding),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            SizedBox(
              height: _iconSlot,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  // 底座常驻树上，未选中时缩放 + 透明收掉：切换页签时才有
                  // 「从旧状态过渡到新状态」可看。直接按 selected 增删组件，
                  // 表现就是背景色硬闪一下。
                  AnimatedOpacity(
                    opacity: selected ? 1 : 0,
                    duration: _selectionDuration,
                    curve: selected ? Curves.easeOut : Curves.easeIn,
                    child: AnimatedScale(
                      scale: selected ? 1 : 0.72,
                      duration: _selectionDuration,
                      curve: selected ? _selectionInCurve : _selectionOutCurve,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: LumeTheme.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        // 底座本身不画图标（图标是下面的兄弟节点），只留出
                        // 与旧版一致的 40×22 底色块，图标才能带着颜色一起动。
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 1,
                          ),
                          child: SizedBox(width: 20, height: 20),
                        ),
                      ),
                    ),
                  ),
                  // 图标：颜色随选中态平滑过渡，实心 / 线框之间做一次轻量交叉淡入。
                  TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: color),
                    duration: _selectionDuration,
                    curve: Curves.easeInOut,
                    builder: (context, animatedColor, _) => AnimatedSwitcher(
                      duration: _selectionDuration,
                      switchInCurve: Curves.easeOutBack,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) => ScaleTransition(
                        scale: Tween<double>(
                          begin: .8,
                          end: 1,
                        ).animate(animation),
                        child: FadeTransition(opacity: animation, child: child),
                      ),
                      child: Icon(
                        selected ? tab.selectedIcon : tab.icon,
                        key: ValueKey<bool>(selected),
                        size: 20,
                        color: animatedColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: color),
              duration: _selectionDuration,
              curve: Curves.easeInOut,
              builder: (context, animatedColor, _) => Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: LumeTypography.captionSize,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: animatedColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
