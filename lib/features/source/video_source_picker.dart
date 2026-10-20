import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/cat/cat_service.dart';
import '../../core/reading/reading_library.dart';
import '../../core/session/privacy_settings.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_content_visibility.dart';
import '../../core/source/source_order.dart';
import '../../core/source/source_preferences.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/web/web_home_sources.dart';
import '../../shared/widgets/drawer_geometry.dart';
import '../../shared/widgets/lume_icon.dart';
import '../../shared/widgets/source_card_metrics.dart';
import '../../shared/widgets/source_drag_tile.dart';
import '../../shared/widgets/source_icon.dart';
import '../cat/cat_subscription_page.dart';
import 'source_import_dialog.dart';
import 'source_preferences_page.dart';
import 'source_section_page.dart';
import 'source_subscription_page.dart';

enum VideoSourceType {
  all('全部'),
  ordinary('普通'),
  cat('猫源'),
  python('PY'),
  module('模块'),
  web('网页');

  const VideoSourceType(this.label);
  final String label;
}

class VideoSourceChoice {
  const VideoSourceChoice.ordinary(this.sourceId) : site = null, webHome = null;
  const VideoSourceChoice.cat(this.site) : sourceId = null, webHome = null;
  const VideoSourceChoice.web(WebHomeSource this.webHome)
    : sourceId = null,
      site = null;
  final String? sourceId;
  final CatSite? site;
  final WebHomeSource? webHome;
}

Future<VideoSourceChoice?> showVideoSourcePicker({
  required BuildContext context,
  required SourceManager manager,
  String? currentCatId,
  String? currentWebId,
  bool showingCat = false,
}) => showLumeBottomSheet<VideoSourceChoice>(
  context: context,
  backgroundColor: Colors.transparent,
  builder: (_) => VideoSourcePicker(
    manager: manager,
    currentCatId: currentCatId,
    currentWebId: currentWebId,
    showingCat: showingCat,
  ),
);

/// Type tabs belong only to the drawer. Subscriptions are headings, not another
/// home-page selector. IDs and playback continue to use their original stores.
class VideoSourcePicker extends StatefulWidget {
  const VideoSourcePicker({
    super.key,
    required this.manager,
    this.currentCatId,
    this.currentWebId,
    this.showingCat = false,
    this.service,
  });
  final SourceManager manager;
  final String? currentCatId;
  final String? currentWebId;
  final bool showingCat;
  final CatService? service;

  @override
  State<VideoSourcePicker> createState() => _VideoSourcePickerState();
}

class _VideoSourcePickerState extends State<VideoSourcePicker> {
  late final service = widget.service ?? CatService.instance;
  VideoSourceType type = VideoSourceType.all;
  String query = '';
  List<SourceDescriptor> sources = [];
  String? currentId, error;
  bool loading = true;
  final busy = <String>{};
  WebHomeStore? _webStore;
  List<WebHomeSource> webHomes = const [];

  @override
  void initState() {
    super.initState();
    service.addListener(changed);
    SourceContentVisibility.instance.addListener(changed);
    PrivacySettings.instance.addListener(changed);
    unawaited(load());
  }

  void changed() {
    if (mounted) {
      setState(() {
        webHomes = _webStore?.items ?? webHomes;
      });
    }
  }

  @override
  void dispose() {
    service.removeListener(changed);
    SourceContentVisibility.instance.removeListener(changed);
    PrivacySettings.instance.removeListener(changed);
    _webStore?.removeListener(changed);
    super.dispose();
  }

  Future<void> load() async {
    try {
      await ReadingLibrary.open(Section.video);
      await ReadingLibrary.open(Section.cat);
      await service.boot();
      final webStore = await WebHomeStore.open();
      final rows = await widget.manager.list();
      final current = await widget.manager.current();
      if (!mounted) return;
      if (!identical(webStore, _webStore)) {
        _webStore?.removeListener(changed);
        webStore.addListener(changed);
        _webStore = webStore;
      }
      setState(() {
        sources = rows;
        currentId = current?.id;
        webHomes = webStore.items;
        loading = false;
        error = null;
      });
    } catch (failure) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$failure';
        });
      }
    }
  }

  bool matches(String text) => text.toLowerCase().contains(query);

  Future<void> edit(
    Section section,
    String id,
    String name,
    String url, {
    bool widgetParameters = false,
  }) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourcePreferencesPage(
          section: section,
          sourceId: id,
          name: name,
          siteUrl: url,
          showWidgetParameters: widgetParameters,
        ),
      ),
    );
    if (mounted) await load();
  }

  Future<void> add() async {
    final target = await showModalBottomSheet<VideoSourceType>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                '添加视频源',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            for (final row in [
              (VideoSourceType.ordinary, Icons.code, '普通视频源', '导入 JS 文件或订阅链接'),
              (VideoSourceType.cat, Icons.pets_outlined, '猫源订阅', '管理订阅包与包内站点'),
              (
                VideoSourceType.python,
                Icons.terminal,
                'Python 源',
                '导入 Spider 脚本、ZIP 源包或订阅链接',
              ),
              (
                VideoSourceType.module,
                Icons.extension_outlined,
                '模块源',
                '导入 ESM / CommonJS、ZIP 源包或远程 Spider',
              ),
              (VideoSourceType.web, Icons.language, '网页主页', '添加、编辑网页主页'),
            ])
              ListTile(
                leading: LumeIcon(
                  row.$2,
                  slot: 'video_source_picker.add',
                  variant: true,
                ),
                title: Text(row.$3),
                subtitle: Text(row.$4),
                onTap: () => Navigator.pop(context, row.$1),
              ),
          ],
        ),
      ),
    );
    if (!mounted || target == null) return;
    if ([
      VideoSourceType.ordinary,
      VideoSourceType.python,
      VideoSourceType.module,
    ].contains(target)) {
      await runSourceImport(
        context,
        section: Section.video,
        manager: widget.manager,
      );
      if (mounted) setState(() => type = target);
    } else if (target == VideoSourceType.cat) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => const CatSubscriptionPage()),
      );
    } else if (target == VideoSourceType.web) {
      await _addWebHome();
      return;
    } else {
      setState(() => type = target);
      return;
    }
    if (mounted) await load();
  }

  Future<void> _addWebHome() async {
    final store = await WebHomeStore.open();
    if (!mounted) return;
    final source = await _webHomeDialog(store: store);
    if (source == null) return;
    store.upsert(source);
    if (!mounted) return;
    setState(() => type = VideoSourceType.web);
    await load();
  }

  Future<void> _editWebHome(WebHomeSource source) async {
    final store = await WebHomeStore.open();
    if (!mounted) return;
    final updated = await _webHomeDialog(store: store, existing: source);
    if (updated != null) store.upsert(updated);
    if (mounted) await load();
  }

  Future<WebHomeSource?> _webHomeDialog({
    required WebHomeStore store,
    WebHomeSource? existing,
  }) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final urlController = TextEditingController(text: existing?.url ?? '');
    String? error;
    final result = await showDialog<WebHomeSource>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(existing == null ? '添加网页主页' : '编辑网页主页'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：影视主页',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '主页地址',
                  hintText: 'https://example.com',
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () {
                  store.remove(existing.id);
                  Navigator.pop(dialogContext);
                },
                child: const Text('删除'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                var url = urlController.text.trim();
                if (!url.contains('://')) url = 'https://$url';
                if (name.isEmpty) {
                  setDialogState(() => error = '请填写名称');
                  return;
                }
                if (!isValidWebHomeUrl(url)) {
                  setDialogState(() => error = '请输入有效的 http(s) 地址');
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  WebHomeSource(
                    id: existing?.id ?? store.nextId(),
                    name: name,
                    url: url,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    urlController.dispose();
    return result;
  }

  Future<void> refresh(CatSubscription record) async {
    if (busy.contains(record.id)) return;
    setState(() => busy.add(record.id));
    try {
      await service.refreshSites(record);
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('刷新失败：$failure')));
      }
    } finally {
      if (mounted) setState(() => busy.remove(record.id));
    }
  }

  Widget card({
    required String id,
    required String name,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    required VoidCallback onMore,
    SourceDescriptor? descriptor,
  }) {
    final accent = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: name,
      // Long press belongs to SourceDragTile; Tooltip's recognizer otherwise
      // wins the gesture arena before the parent can begin dragging.
      triggerMode: TooltipTriggerMode.manual,
      child: Semantics(
        selected: selected,
        child: Container(
          height: 68,
          decoration: BoxDecoration(
            color: selected
                ? Color.alphaBlend(
                    accent.withValues(alpha: .08),
                    LumeTheme.surface,
                  )
                : LumeTheme.surface,
            borderRadius: SourceCardMetrics.borderRadius,
            border: Border.all(
              color: selected ? accent : SourceCardMetrics.unselectedBorder,
            ),
            boxShadow: SourceCardMetrics.shadow,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: SourceCardMetrics.borderRadius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('video-picker-source-$id'),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.only(left: 10, right: 2),
                child: Row(
                  children: [
                    if (descriptor != null) ...[
                      SourceIcon(
                        name: name,
                        siteUrl: descriptor.siteUrl,
                        iconUrl: descriptor.iconUrl,
                        size: 28,
                        radius: 7,
                        section: Section.video,
                        sourceId: descriptor.id,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                              color: LumeTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.15,
                              color: selected ? accent : LumeTheme.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '$name的设置',
                      onPressed: onMore,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 44,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const LumeIcon(
                        Icons.more_vert,
                        size: 18,
                        slot: 'video_source_picker.more',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget grid(List<Widget> cards) => LayoutBuilder(
    builder: (context, constraints) {
      final single = constraints.maxWidth < 300;
      return Column(
        children: [
          for (var i = 0; i < cards.length; i += single ? 1 : 2)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: cards[i]),
                  if (!single) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: i + 1 < cards.length
                          ? cards[i + 1]
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
        ],
      );
    },
  );

  Widget heading(String title, int count, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        Text('$count', style: TextStyle(fontSize: 12, color: LumeTheme.muted)),
        ?trailing,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ordinary = sources
        .where(
          (s) =>
              s.enabled &&
              (type == VideoSourceType.all ||
                  type == VideoSourceType.ordinary &&
                      s.runtimeKind == 'javascript' ||
                  type == VideoSourceType.python && s.runtimeKind == 'python' ||
                  type == VideoSourceType.module &&
                      s.runtimeKind == 'module') &&
              SourceContentVisibility.instance.allows(Section.video, s) &&
              matches('${s.name} ${s.id} ${s.group}'),
        )
        .toList();
    final originalOrder = sources.map((s) => s.id).toList();
    ordinary.sort((a, b) {
      final pa = SourcePreferences.read(Section.video, a.id).pinned;
      final pb = SourcePreferences.read(Section.video, b.id).pinned;
      return pa != pb
          ? (pa ? -1 : 1)
          : SourceOrder.compare(Section.video, a.id, b.id, originalOrder);
    });
    final records = service.subscriptions.where((s) => s.enabled).toList();
    final groups = <(CatSubscription, List<CatSite>)>[];
    for (final record in records) {
      final sites = record.sites
          .where(
            (s) =>
                PrivacySettings.instance.allowsSource(s.id, s.name) &&
                matches('${record.name} ${s.name} ${s.key}'),
          )
          .toList();
      final order = record.sites.map((s) => s.id).toList();
      sites.sort((a, b) => SourceOrder.compare(Section.cat, a.id, b.id, order));
      if (sites.isNotEmpty || (record.sites.isEmpty && matches(record.name))) {
        groups.add((record, sites));
      }
    }
    final filteredWeb = webHomes
        .where((home) => matches('${home.name} ${home.url}'))
        .toList();
    final showOrdinary = [
      VideoSourceType.all,
      VideoSourceType.ordinary,
      VideoSourceType.python,
      VideoSourceType.module,
    ].contains(type);
    final showCat = type == VideoSourceType.all || type == VideoSourceType.cat;
    final showWeb = type == VideoSourceType.all || type == VideoSourceType.web;
    final empty =
        (!showOrdinary || ordinary.isEmpty) &&
        (!showCat || groups.isEmpty) &&
        (!showWeb || filteredWeb.isEmpty);
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Material(
        color: LumeTheme.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SizedBox(
              height: DrawerGeometry.height(context),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 8, 0),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '选择视频源',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '添加视频源',
                          onPressed: add,
                          icon: const LumeIcon(
                            Icons.add,
                            slot: 'video_source_picker.add_button',
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(context),
                          icon: const LumeIcon(
                            Icons.close,
                            slot: 'video_source_picker.close',
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: TextField(
                      onChanged: (value) =>
                          setState(() => query = value.trim().toLowerCase()),
                      decoration: const InputDecoration(
                        hintText: '搜索源名称或订阅包',
                        prefixIcon: LumeIcon(
                          Icons.search,
                          slot: 'video_source_picker.search',
                        ),
                      ),
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (final item in VideoSourceType.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              key: ValueKey('video-source-type-${item.name}'),
                              label: Text(item.label),
                              selected: type == item,
                              showCheckmark: false,
                              onSelected: (_) => setState(() => type = item),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => SourceSectionPage(
                                section: Section.video,
                                manager: widget.manager,
                              ),
                            ),
                          );
                          if (mounted) await load();
                        },
                        child: const Text('源管理'),
                      ),
                      TextButton(
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => SourceSubscriptionPage(
                                section: Section.video,
                                manager: widget.manager,
                              ),
                            ),
                          );
                          if (mounted) await load();
                        },
                        child: const Text('源订阅'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context)
                          .copyWith(scrollbars: false),
                      child: loading
                          ? const Center(child: CircularProgressIndicator())
                          : error != null
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('源列表加载失败'),
                                  TextButton(
                                    onPressed: load,
                                    child: const Text('重试'),
                                  ),
                                ],
                              ),
                            )
                          : ListView(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                              children: [
                                if (empty)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 48,
                                    ),
                                    child: Column(
                                      children: [
                                        Text(
                                          query.isEmpty ? '还没有可用的源' : '没有匹配的源',
                                        ),
                                        if (query.isEmpty)
                                          TextButton(
                                            onPressed: add,
                                            child: const Text('添加源'),
                                          ),
                                      ],
                                    ),
                                  ),
                                if (showOrdinary && ordinary.isNotEmpty) ...[
                                  heading(
                                    type == VideoSourceType.python
                                        ? 'Python 源'
                                        : type == VideoSourceType.module
                                        ? '模块源'
                                        : type == VideoSourceType.ordinary
                                        ? '普通视频源'
                                        : '视频源',
                                    ordinary.length,
                                  ),
                                  grid([
                                    for (final s in ordinary)
                                      SourceDragTile(
                                        key: ValueKey(
                                          'video-picker-drag-${s.id}',
                                        ),
                                        id: s.id,
                                        name: s.name,
                                        accepts: (id) =>
                                            ordinary.any((s) => s.id == id),
                                        onMove: (from, to) async {
                                          final ids = ordinary
                                              .map((s) => s.id)
                                              .toList();
                                          await SourceOrder.move(
                                            Section.video,
                                            originalOrder,
                                            ids,
                                            ids.indexOf(from),
                                            ids.indexOf(to),
                                          );
                                          changed();
                                        },
                                        child: card(
                                          id: s.id,
                                          name: s.name,
                                          subtitle:
                                              !widget.showingCat &&
                                                  currentId == s.id
                                              ? '当前使用'
                                              : '${s.runtimeKind == 'python'
                                                    ? 'PY'
                                                    : s.runtimeKind == 'module'
                                                    ? '模块'
                                                    : 'JS'} · ${s.version}',
                                          descriptor: s,
                                          selected:
                                              !widget.showingCat &&
                                              currentId == s.id,
                                          onTap: () => Navigator.pop(
                                            context,
                                            VideoSourceChoice.ordinary(s.id),
                                          ),
                                          onMore: () => edit(
                                            Section.video,
                                            s.id,
                                            s.name,
                                            s.siteUrl,
                                            widgetParameters:
                                                s.runtimeKind == 'module',
                                          ),
                                        ),
                                      ),
                                  ]),
                                ],
                                if (showCat)
                                  for (final (record, sites) in groups) ...[
                                    heading(
                                      record.name,
                                      sites.length,
                                      trailing: IconButton(
                                        tooltip: '刷新${record.name}站点',
                                        onPressed: busy.contains(record.id)
                                            ? null
                                            : () => refresh(record),
                                        icon: busy.contains(record.id)
                                            ? const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const LumeIcon(
                                                Icons.refresh,
                                                size: 20,
                                                slot: 'video_source_picker.refresh',
                                              ),
                                      ),
                                    ),
                                    if (sites.isEmpty)
                                      TextButton(
                                        onPressed: busy.contains(record.id)
                                            ? null
                                            : () => refresh(record),
                                        child: const Text('加载包内站点'),
                                      ),
                                    grid([
                                      for (final s in sites)
                                        SourceDragTile(
                                          key: ValueKey(
                                            'video-picker-drag-${s.id}',
                                          ),
                                          id: s.id,
                                          name: s.name,
                                          accepts: (id) =>
                                              sites.any((s) => s.id == id),
                                          onMove: (from, to) async {
                                            final ids = sites
                                                .map((s) => s.id)
                                                .toList();
                                            await SourceOrder.move(
                                              Section.cat,
                                              record.sites
                                                  .map((s) => s.id)
                                                  .toList(),
                                              ids,
                                              ids.indexOf(from),
                                              ids.indexOf(to),
                                            );
                                            changed();
                                          },
                                          child: card(
                                            id: s.id,
                                            name: s.name,
                                            subtitle:
                                                widget.currentCatId == s.id
                                                ? '当前使用'
                                                : '猫源',
                                            selected:
                                                widget.currentCatId == s.id,
                                            onTap: () => Navigator.pop(
                                              context,
                                              VideoSourceChoice.cat(s),
                                            ),
                                            onMore: () => edit(
                                              Section.cat,
                                              s.id,
                                              s.name,
                                              s.siteUrl,
                                            ),
                                          ),
                                        ),
                                    ]),
                                  ],
                                if (showWeb) ...[
                                  heading(
                                    '网页主页',
                                    filteredWeb.length,
                                    trailing: IconButton(
                                      tooltip: '添加网页主页',
                                      onPressed: _addWebHome,
                                      icon: const LumeIcon(
                                        Icons.add,
                                        size: 20,
                                        slot: 'video_source_picker.add_web',
                                      ),
                                    ),
                                  ),
                                  if (filteredWeb.isEmpty)
                                    TextButton.icon(
                                      onPressed: _addWebHome,
                                      icon: const LumeIcon(
                                        Icons.language,
                                        size: 20,
                                        slot: 'video_source_picker.web_empty',
                                      ),
                                      label: const Text('添加网页主页地址'),
                                    )
                                  else
                                    grid([
                                      for (final home in filteredWeb)
                                        SourceDragTile(
                                          key: ValueKey(
                                            'web-picker-drag-${home.id}',
                                          ),
                                          id: home.id,
                                          name: home.name,
                                          accepts: (id) => filteredWeb.any(
                                            (row) => row.id == id,
                                          ),
                                          onMove: (from, to) async {
                                            final store = _webStore;
                                            if (store == null) return;
                                            store.moveVisible(
                                              filteredWeb
                                                  .map((row) => row.id)
                                                  .toList(),
                                              from,
                                              to,
                                            );
                                          },
                                          child: card(
                                            id: home.id,
                                            name: home.name,
                                            subtitle:
                                                widget.currentWebId == home.id
                                                ? '当前使用'
                                                : home.url,
                                            selected:
                                                widget.currentWebId == home.id,
                                            onTap: () => Navigator.pop(
                                              context,
                                              VideoSourceChoice.web(home),
                                            ),
                                            onMore: () => _editWebHome(home),
                                          ),
                                        ),
                                    ]),
                                ],
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
