import '../../shared/widgets/source_category_columns.dart';
import '../../shared/widgets/drawer_geometry.dart';
import '../../core/source/source_subscription_sync.dart';
import '../../shared/widgets/source_update_badge.dart';
import '../../shared/widgets/source_drag_tile.dart';
import '../../shared/widgets/source_icon.dart';
import '../../core/source/source_content_rating.dart';
import '../../shared/widgets/source_rating_badge.dart';
import '../../core/source/source_order.dart';
import '../../core/source/source_content_visibility.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/reading/reading_library.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_picker_groups.dart';
import '../../core/source/source_preferences.dart';
import '../../core/theme/lume_theme.dart';
import 'source_action_dialogs.dart';
import 'source_preferences_page.dart';

enum SourceQuickAction { pin, preferences, browse, test, update }

Future<String?> showSourcePicker({
  required BuildContext context,
  required Section section,
  required List<SourceDescriptor> sources,
  required String? currentId,
  SourceManager? manager,
  VoidCallback? onChanged,
}) => showLumeBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (_) => SourcePickerSheet(
    section: section,
    sources: sources,
    currentId: currentId,
    manager: manager,
    onChanged: onChanged,
  ),
);

class SourcePickerSheet extends StatefulWidget {
  const SourcePickerSheet({
    super.key,
    required this.section,
    required this.sources,
    required this.currentId,
    this.manager,
    this.onChanged,
    this.initialColumns,
  });
  final Section section;
  final List<SourceDescriptor> sources;
  final String? currentId;
  final SourceManager? manager;
  final VoidCallback? onChanged;

  /// 预览/测试用：强制初始单双列；为空时读板块设置。
  final bool? initialColumns;
  @override
  State<SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<SourcePickerSheet> {
  late final SourceManager manager =
      widget.manager ?? LumeSources.manager(widget.section);
  late List<SourceDescriptor> sources = List.of(widget.sources);
  late bool columns =
      widget.initialColumns ??
      // 小说 / 漫画 / 视频固定两列；猫源按设置切换，默认单列。
      (widget.section != Section.cat ||
          switch (ReadingLibrary.find(widget.section)
              ?.setting('source.picker.columns')) {
            'true' => true,
            _ => false,
          });
  String query = '';
  final busy = <String>{};
  final results = <String, SourceTestResult>{};

  @override
  void initState() {
    super.initState();
    SourceSubscriptionSync.revision(widget.section)
        .addListener(_subscriptionChanged);
    SourceContentVisibility.instance.addListener(_onVisibility);
  }

  void _subscriptionChanged() {
    if (mounted) reload();
  }

  void _onVisibility() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SourceSubscriptionSync.revision(widget.section)
        .removeListener(_subscriptionChanged);
    SourceContentVisibility.instance.removeListener(_onVisibility);
    super.dispose();
  }

  Future<void> reload() async {
    final next = await manager.list();
    if (mounted) setState(() => sources = next);
  }

  void toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> network(SourceDescriptor source) async {
    final result = await showDialog<SourceSettingsResult>(
      context: context,
      builder: (_) => SourceNetworkDialog(source: source),
    );
    if (result == null || !mounted) return;
    final profile = result.network;
    await manager.setNetwork(
      source.id,
      userAgent: profile.userAgent,
      cookie: profile.cookie,
      proxy: profile.proxy,
      bridge: profile.bridge,
      allowBadCertificate: profile.allowBadCertificate,
    );
    // 换网址 / 账号登入：只落库，不释放运行时——下一次调用前宿主会把新快照
    // 注入脚本（见 SourceRegistry.scriptConfigFor）。
    await manager.setSiteConfig(source.id, result.site);
    await manager.setEnabled(source.id, source.enabled);
    widget.onChanged?.call();
    await reload();
  }

  Future<void> openSettings(SourceDescriptor source) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => SourcePreferencesPage(
          section: widget.section,
          sourceId: source.id,
          name: source.name,
          siteUrl: source.siteUrl,
          onNetwork: () => network(source),
        ),
      ),
    );
    if (saved == true) widget.onChanged?.call();
    if (mounted) await reload();
  }

  Future<void> deleteSource(SourceDescriptor source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除源'),
        content: Text('确定删除「${source.name}」？其脚本与运行时将一并移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: LumeTheme.danger),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || busy.contains(source.id)) return;
    setState(() => busy.add(source.id));
    try {
      await manager.remove(source.id);
      widget.onChanged?.call();
      await reload();
    } catch (error) {
      toast('删除失败：$error');
    } finally {
      if (mounted) setState(() => busy.remove(source.id));
    }
  }

  Future<void> action(SourceDescriptor source) async {
    if (busy.contains(source.id)) return;
    final prefs = SourcePreferences.read(widget.section, source.id);
    final selected = await showDialog<SourceQuickAction>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .28),
      builder: (dialogContext) => Dialog(
        constraints: const BoxConstraints(maxWidth: 320),
        backgroundColor: Colors.transparent,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Material(
              color: LumeTheme.surface.withValues(alpha: .94),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                        child: Text(
                          source.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      for (final entry in [
                        (
                          SourceQuickAction.pin,
                          Icons.push_pin_outlined,
                          prefs.pinned ? '取消置顶' : '置顶此源',
                        ),
                        (SourceQuickAction.preferences, Icons.tune, '源设置'),
                        (SourceQuickAction.browse, Icons.open_in_new, '浏览'),
                        (SourceQuickAction.test, Icons.network_check, '测试连通性'),
                        (SourceQuickAction.update, Icons.refresh, '更新订阅源'),
                      ])
                        ListTile(
                          leading: Icon(entry.$2, color: LumeTheme.accent),
                          title: Text(entry.$3),
                          enabled:
                              entry.$1 != SourceQuickAction.update ||
                              source.subscribed,
                          onTap: () => Navigator.pop(dialogContext, entry.$1),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == SourceQuickAction.browse) {
      Navigator.pop(context, source.id);
      return;
    }
    setState(() => busy.add(source.id));
    try {
      switch (selected) {
        case SourceQuickAction.pin:
          await prefs
              .copyWith(pinned: !prefs.pinned)
              .save(widget.section, source.id);
          widget.onChanged?.call();
        case SourceQuickAction.preferences:
          await openSettings(source);
        case SourceQuickAction.test:
          final result = await manager.testConnectivity(source.id);
          if (!mounted) return;
          setState(() {
            results[source.id] = result;
            busy.remove(source.id);
          });
          await showDialog<void>(
            context: context,
            builder: (_) =>
                SourceTestResultDialog(sourceName: source.name, result: result),
          );
        case SourceQuickAction.update:
          final result = await manager.updateFromSubscription(source.id);
          if (result.status == SourceUpdateStatus.updated) {
            widget.onChanged?.call();
          }
          toast(switch (result.status) {
            SourceUpdateStatus.updated =>
              '「${source.name}」已更新到最新脚本${result.message.isEmpty ? '' : '（${result.message}）'}',
            SourceUpdateStatus.unchanged => '「${source.name}」已是最新',
            SourceUpdateStatus.skipped => '跳过：${result.message}',
            SourceUpdateStatus.failed => '更新失败：${result.message}',
          });
        case SourceQuickAction.browse:
          break;
      }
      if (mounted) await reload();
    } catch (error) {
      toast('操作失败：$error');
    } finally {
      if (mounted) setState(() => busy.remove(source.id));
    }
  }

  Widget sourceTile(SourceDescriptor source) {
    final prefs = SourcePreferences.read(widget.section, source.id);
    final selected = source.id == widget.currentId;
    final adult = SourceContentRating.isAdult(source.id, source.name);
    // 猫源走极简形态：只有名称，长按出菜单；其它板块保留图标与三点菜单。
    final isCat = widget.section == Section.cat;

    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = dark ? LumeTheme.surfaceAlt : const Color(0xFFF7F8FA);
    final radius = BorderRadius.circular(8);
    return SizedBox(
      height: 64,
      child: Material(
        elevation: 0,
        shadowColor: LumeTheme.cardShadow.first.color,
        color: selected
            ? Color.alphaBlend(
                LumeTheme.accent.withValues(alpha: .08),
                cardColor,
              )
            : cardColor,
        borderRadius: radius,
        child: InkWell(
          key: ValueKey('picker-source-${source.id}'),
          borderRadius: radius,
          onTap: busy.contains(source.id)
              ? null
              : () => Navigator.pop(context, source.id),
          child: Padding(
            padding: EdgeInsets.only(
              left: isCat ? 16 : 12,
              right: isCat ? 16 : 8,
            ),
            child: isCat
                ? Center(
                    child: Text(
                      source.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: LumeTheme.textPrimary,
                        height: 1.2,
                      ),
                    ),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: busy.contains(source.id)
                            ? const Center(
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : SourceIcon(
                                key: ValueKey('picker-icon-${source.id}'),
                                name: source.name,
                                siteUrl: source.siteUrl,
                                iconUrl: prefs.iconUrl.trim().isEmpty
                                    ? source.iconUrl
                                    : prefs.iconUrl,
                                size: 36,
                                radius: 8,
                                section: widget.section,
                                sourceId: source.id,
                              ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    source.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                      color: LumeTheme.textPrimary,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: SourceUpdateBadge(
                                    section: widget.section,
                                    sourceId: source.id,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    results[source.id]?.status.label ??
                                        source.version,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: LumeTheme.muted,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                                if (adult)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 4),
                                    child: SourceRatingBadge(compact: true),
                                  ),
                                if (prefs.pinned)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: Icon(
                                      Icons.push_pin,
                                      size: 11,
                                      color: LumeTheme.accent,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // 右侧菜单：卡片最右，距卡片边缘 8px。
                      IconButton(
                        key: ValueKey('picker-more-${source.id}'),
                        tooltip: '源操作',
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        constraints: const BoxConstraints.tightFor(
                          width: 24,
                          height: 40,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: () => action(source),
                        icon: const Icon(Icons.more_vert, size: 18),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = sources
        .where(
          (source) =>
              source.enabled &&
              SourceContentVisibility.instance.allows(widget.section, source) &&
              (source.name.toLowerCase().contains(query) ||
                  source.id.toLowerCase().contains(query) ||
                  source.group.toLowerCase().contains(query)),
        )
        .toList();
    final order = sources.map((s) => s.id).toList();
    visible.sort((a, b) {
      final pinA = SourcePreferences.read(widget.section, a.id).pinned;
      final pinB = SourcePreferences.read(widget.section, b.id).pinned;
      return pinA != pinB
          ? (pinA ? -1 : 1)
          : SourceOrder.compare(widget.section, a.id, b.id, order);
    });
    Future<void> move(
      List<SourceDescriptor> entries,
      String from,
      String to,
    ) async {
      final all = List<SourceDescriptor>.of(
        sources,
      )..sort((a, b) => SourceOrder.compare(widget.section, a.id, b.id, order));
      await SourceOrder.move(
        widget.section,
        all.map((s) => s.id).toList(),
        entries.map((s) => s.id).toList(),
        entries.indexWhere((s) => s.id == from),
        entries.indexWhere((s) => s.id == to),
      );
      if (mounted) setState(() {});
    }

    // 猫源卡片：左滑露出设置 / 删除；长按拖拽仍由外层 SourceDragTile 负责。
    Widget catCard(SourceDescriptor source) => _CatSwipeTile(
      onSettings: () => openSettings(source),
      onDelete: () => deleteSource(source),
      child: sourceTile(source),
    );

    Widget list(List<SourceDescriptor> entries) {
      // 所有板块统一用长按拖拽排序；猫源的设置/删除走左滑，不抢长按。
      Widget tile(BuildContext context, int i) => SourceDragTile(
        key: ValueKey('picker-drag-${entries[i].id}'),
        id: entries[i].id,
        name: entries[i].name,
        accepts: (id) => entries.any((s) => s.id == id),
        onMove: (from, to) => move(entries, from, to),
        child: widget.section == Section.cat
            ? catCard(entries[i])
            : sourceTile(entries[i]),
      );
      if (entries.isEmpty) {
        return Center(child: Text(query.isEmpty ? '暂无源' : '没有匹配的源'));
      }
      // 猫源双列：两列等宽卡片，列间 10px；用“每行两张”的列表保住
      // 长按拖拽的手势路径（与单列列表同一种滚动结构）。
      if (widget.section == Section.cat && columns) {
        Widget slot(int index) {
          if (index >= entries.length) return const SizedBox.shrink();
          final source = entries[index];
          return SourceDragTile(
            key: ValueKey('picker-drag-${source.id}'),
            id: source.id,
            name: source.name,
            accepts: (id) => entries.any((entry) => entry.id == id),
            onMove: (from, to) => move(entries, from, to),
            child: catCard(source),
          );
        }

        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: (entries.length + 1) ~/ 2,
          itemBuilder: (context, row) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              height: 64,
              child: Row(
                children: [
                  Expanded(child: slot(row * 2)),
                  const SizedBox(width: 10),
                  Expanded(child: slot(row * 2 + 1)),
                ],
              ),
            ),
          ),
        );
      }
      return ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: tile,
      );
    }

    final grouped = {
      for (final group in SourcePickerGroups.forSection(widget.section))
        group.$1: <SourceDescriptor>[],
    };
    for (final source in visible) {
      grouped[SourcePickerGroups.groupFor(widget.section, source)]!.add(source);
    }
    final groupDefinitions = SourcePickerGroups.forSection(widget.section);
    final singleList = visible.isEmpty
        ? Center(child: Text(query.isEmpty ? '暂无源' : '没有匹配的源'))
        : ListView(
            key: const ValueKey('picker-grouped-list'),
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              for (final group in groupDefinitions)
                if (grouped[group.$1]!.isNotEmpty) ...[
                  Semantics(
                    header: true,
                    child: Padding(
                      key: ValueKey('picker-group-${group.$1}'),
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                      child: Text(
                        group.$2,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                  ),
                  list(grouped[group.$1]!),
                  const SizedBox(height: 8),
                ],
            ],
          );

    final groupedList = columns && widget.section != Section.cat
        ? SourceCategoryColumns(
            key: ValueKey('picker-columns-${widget.section.id}'),
            sections: [
              for (final group in groupDefinitions)
                SourceColumnSection(
                  id: group.$1,
                  title: group.$2,
                  children: [
                    for (final source in grouped[group.$1]!)
                      SourceDragTile(
                        key: ValueKey('picker-drag-${source.id}'),
                        id: source.id,
                        name: source.name,
                        accepts: (id) =>
                            grouped[group.$1]!.any((entry) => entry.id == id),
                        onMove: (from, to) =>
                            move(grouped[group.$1]!, from, to),
                        child: sourceTile(source),
                      ),
                  ],
                ),
            ],
          )
        : singleList;

    final content = SafeArea(
      top: false,
      child: SizedBox(
        height: DrawerGeometry.height(context),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        onChanged: (value) =>
                            setState(() => query = value.trim().toLowerCase()),
                        decoration: const InputDecoration(
                          hintText: '搜索源',
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                    ),
                    if (widget.section == Section.cat)
                      IconButton(
                        tooltip: columns ? '切换为单列' : '切换为双列',
                        icon: Icon(
                          columns
                              ? Icons.view_agenda_outlined
                              : Icons.view_column_outlined,
                        ),
                        onPressed: () async {
                          setState(() => columns = !columns);
                          final library = await ReadingLibrary.open(
                            widget.section,
                          );
                          library.setSetting(
                            'source.picker.columns',
                            '$columns',
                          );
                        },
                      ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Text(
                widget.section == Section.cat
                    ? '点击选择源，长按拖动排序，左滑打开设置/删除'
                    : '长按源条目拖动排序，点击更多打开操作菜单',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.captionSize,
                  color: LumeTheme.muted,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(child: groupedList),
            ],
          ),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Material(
        color: LumeTheme.surface,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: content,
        ),
      ),
    );
  }
}

/// 猫源卡片：左滑露出「设置 / 删除」，把菜单从长按手势里彻底让出来。
///
/// 手势分工：
/// - 水平拖动 → 滑动卡片（本组件）；
/// - 长按不动 → 外层 [SourceDragTile] 的拖拽排序；
/// - 点击 → 卡片自身的 InkWell 选中源。
class _CatSwipeTile extends StatefulWidget {
  const _CatSwipeTile({
    required this.child,
    required this.onSettings,
    required this.onDelete,
  });

  final Widget child;
  final VoidCallback onSettings;
  final VoidCallback onDelete;

  @override
  State<_CatSwipeTile> createState() => _CatSwipeTileState();
}

class _CatSwipeTileState extends State<_CatSwipeTile>
    with SingleTickerProviderStateMixin {
  static const double _reveal = 112;
  static final BorderRadius _radius = BorderRadius.circular(8);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..addListener(_tick);
  double _dx = 0;
  double _from = 0;
  double _to = 0;

  void _tick() {
    setState(() => _dx = _from + (_to - _from) * _controller.value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _settle(double target) {
    _from = _dx;
    _to = target;
    _controller.forward(from: 0);
  }

  void _dragUpdate(DragUpdateDetails details) {
    if (_controller.isAnimating) _controller.stop();
    setState(() => _dx = (_dx + details.delta.dx).clamp(-_reveal, 0.0));
  }

  void _dragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final open = velocity < -260 || (velocity <= 260 && _dx < -_reveal / 2);
    _settle(open ? -_reveal : 0);
  }

  void _run(VoidCallback action) {
    _settle(0);
    action();
  }

  Widget _action(String label, Color color, VoidCallback onTap) => Expanded(
    child: Material(
      color: color.withValues(alpha: .12),
      child: InkWell(
        onTap: () => _run(onTap),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final accent = LumeTheme.accent;
    final danger = LumeTheme.danger;
    return SizedBox(
      height: 64,
      child: ClipRRect(
        borderRadius: _radius,
        child: Stack(
          children: [
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: _reveal,
                  child: Row(
                    children: [
                      _action('设置', accent, widget.onSettings),
                      _action('删除', danger, widget.onDelete),
                    ],
                  ),
                ),
              ),
            ),
            Transform.translate(
              offset: Offset(_dx, 0),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: _dragUpdate,
                onHorizontalDragEnd: _dragEnd,
                child: widget.child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
