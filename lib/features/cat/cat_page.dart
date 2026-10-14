import '../../core/source/home_browse_mode.dart';
import '../../shared/widgets/home_browse_navigation.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/cat/cat_service.dart';
import '../../core/cat/cat_data_source.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/theme/floating_modules.dart';
import '../../shared/widgets/glass_card.dart';
import '../reading/poster_card.dart';
import '../reading/section_image.dart';
import '../reading/browse_choice_access.dart';
import '../comic/comic_detail_page.dart';
import '../novel/novel_detail_page.dart';
import '../shell/shell_dock.dart';
import 'cat_subscription_page.dart';
import 'cat_detail_page.dart';
import 'cat_web_page.dart';
import 'cat_preloader.dart';

class CatPage extends StatefulWidget {
  const CatPage({super.key});
  @override
  State<CatPage> createState() => _CatPageState();
}

class _CatPageState extends State<CatPage> with WidgetsBindingObserver {
  final service = CatService.instance;
  final scroll = ScrollController();
  ReadingLibrary? library;
  SectionImagePipeline? pipeline;
  CatDataSource? source;
  List<SourceCategory> categories = [];
  List<SourceFilterGroup> groups = [];
  List<SourceItem> items = [];
  Map<String, String> filters = {};
  String? category, error;
  String query = '';
  String? browseMode;
  bool loading = true, more = false, loadingMore = false;
  int page = 1, sequence = 0;
  StreamSubscription<Map<String, dynamic>>? messages;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    service.addListener(changed);
    scroll.addListener(loadMore);
    messages = service.messages.stream.listen(hostMessage);
    unawaited(boot());
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    service.removeListener(changed);
    messages?.cancel();
    scroll.dispose();
    pipeline?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        service.resume().catchError((Object error) {
          toast('猫源恢复失败，请刷新站点');
        }),
      );
    }
  }

  Future<void> boot() async {
    try {
      await service.boot();
      library = await ReadingLibrary.open(Section.cat);
      if (!mounted) return;
      pipeline = SectionImagePipeline(
        cacheDir: library!.imageCacheDir,
        memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
        maxConcurrent: SectionImagePipeline.coverConcurrency,
      );
      await service.checkUpdates();
      await restoreSite();
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = '$failure';
          loading = false;
        });
      }
    }
  }

  Future<void> restoreSite() async {
    if (service.needsSiteSelection) {
      if (mounted) {
        setState(() {
          source = null;
          loading = false;
          error = service.recoveryMessage;
        });
      }
      return;
    }
    final warm = await CatPreloader.take(service);
    if (!mounted) return;
    if (warm != null) {
      setState(() {
        source = warm.source;
        categories = warm.categories;
        groups = warm.groups;
        items = warm.list.items;
        more = warm.list.hasMore;
        page = 1;
        loading = false;
      });
      _preloadCovers(items);
      return;
    }
    final records = service.subscriptions.where((s) => s.enabled).toList();
    if (records.isEmpty) {
      if (mounted) {
        setState(() {
          source = null;
          loading = false;
        });
      }
      return;
    }
    final cached = records
        .expand((s) => s.sites)
        .where((site) => site.id == service.selectedSiteId)
        .firstOrNull;
    final record = cached == null
        ? records.first
        : records.firstWhere((r) => r.id == cached.subscriptionId);
    await service.activate(record);
    final selected =
        record.sites
            .where((site) => site.id == service.selectedSiteId)
            .firstOrNull ??
        record.sites
            .where(
              (site) => !RegExp(
                'config|setting|website|version|calendar|about|配置|我的网盘|日历|日期|更新日志|免责声明|公告|^\\d{4}-\\d{2}-\\d{2}',
                caseSensitive: false,
              ).hasMatch(site.key + site.name),
            )
            .firstOrNull ??
        record.sites.firstOrNull;
    if (!mounted) return;
    if (selected == null) {
      setState(() {
        loading = false;
        error = '订阅包没有返回站点，请打开源配置中心检查';
      });
      return;
    }
    await selectSite(selected);
  }

  Future<void> selectSite(CatSite site) async {
    if (!mounted) return;
    setState(() {
      source = CatDataSource(service, site);
      categories = [];
      groups = [];
      filters = {};
      category = null;
      browseMode = null;
      query = '';
    });
    await service.select(site);
    await refresh();
  }

  Future<void> refresh() async {
    CatPreloader.discard();
    final current = source;
    if (current == null) return;
    final token = ++sequence;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await current.homeData(force: true);
      final nextCategories = await current.categories();
      final nextGroups = await current.filtersFor(categoryId: category);
      final results = query.isEmpty && category == null && filters.isEmpty
          ? await current.homeList()
          : await current.list(
              categoryId: category,
              keyword: query,
              filters: filters,
            );
      if (!mounted || token != sequence) return;
      setState(() {
        categories = nextCategories;
        groups = nextGroups;
        items = results.items;
        more = results.hasMore;
        page = 1;
        loading = false;
      });
      _preloadCovers(results.items);
      if (scroll.hasClients && scroll.offset > 0) scroll.jumpTo(0);
    } catch (failure) {
      if (mounted && token == sequence) {
        setState(() {
          loading = false;
          error = '$failure';
        });
      }
    }
  }

  void _preloadCovers(List<SourceItem> entries) {
    final images = pipeline;
    if (images == null) return;
    final covers = entries
        .where((e) => e.cover?.isNotEmpty == true)
        .take(12)
        .toList();
    for (final item in covers) {
      images.configureImageHeaders({item.cover!: item.coverHeaders});
    }
    images.preload(covers.map((e) => e.cover!), targetWidth: 360);
  }

  void loadMore() {
    if (!scroll.hasClients ||
        scroll.position.extentAfter > 400 ||
        !more ||
        loading ||
        loadingMore) {
      return;
    }
    unawaited(nextPage());
  }

  Future<void> nextPage() async {
    final current = source;
    if (current == null) return;
    final token = sequence;
    setState(() => loadingMore = true);
    try {
      final result = await current.list(
        categoryId: category,
        keyword: query,
        filters: filters,
        page: page + 1,
      );
      if (!mounted || token != sequence) return;
      setState(() {
        final ids = items.map((item) => item.id).toSet();
        items.addAll(result.items.where((item) => ids.add(item.id)));
        page++;
        more = result.hasMore;
      });
    } catch (failure) {
      if (mounted) toast('$failure');
    } finally {
      if (mounted) setState(() => loadingMore = false);
    }
  }

  void toast(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> hostMessage(Map<String, dynamic> message) async {
    if (!mounted) return;
    if (message['action'] == 'openInternalWebview') {
      final uri = Uri.tryParse(catText(message['url'] ?? message['address']));
      if (uri != null && ['http', 'https'].contains(uri.scheme)) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => CatWebPage(url: uri)),
        );
      }
    } else {
      final text = catText(
        message['message'] ?? message['text'] ?? message['content'],
      );
      if (text.isNotEmpty) toast(text);
    }
  }

  Future<void> subscriptions() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const CatSubscriptionPage()),
    );
    if (!mounted) return;
    try {
      await restoreSite();
    } catch (failure) {
      setState(() {
        loading = false;
        error = '$failure';
      });
    }
  }

  void selectBrowseMode(String mode) {
    final target = homeBrowseTarget(mode, categories, groups);
    if (target == null) {
      toast('当前站点未提供$mode分类或排序');
      return;
    }
    setState(() {
      browseMode = mode;
      if (target.category != null) {
        category = target.category;
        filters = {};
      } else {
        filters = Map.of(filters)..[target.group!] = target.option!;
      }
      query = '';
    });
    unawaited(refresh());
  }

  Future<void> sitePicker() async {
    final selected = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: service,
        builder: (context, _) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: ListView(
              children: [
                ListTile(
                  title: const Text('选择站点'),
                  trailing: SegmentedButton<int>(
                    segments: [
                      for (final count in [1, 2, 3])
                        ButtonSegment(value: count, label: Text('$count列')),
                    ],
                    selected: {service.siteColumns},
                    showSelectedIcon: false,
                    onSelectionChanged: (values) =>
                        unawaited(service.setSiteColumns(values.first)),
                  ),
                ),
                for (final record in service.subscriptions.where(
                  (s) => s.enabled,
                )) ...[
                  ListTile(
                    title: Text(record.name),
                    subtitle: const Text('加载或刷新包内站点'),
                    trailing: const Icon(Icons.refresh),
                    onTap: () => Navigator.pop(context, record),
                  ),
                  GridView.count(
                    crossAxisCount: service.siteColumns,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    mainAxisExtent: 62,
                    children: [
                      for (final site in record.sites)
                        ListTile(
                          dense: true,
                          title: Text(
                            site.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          selected:
                              site.id ==
                              (source?.site.id ?? service.selectedSiteId),
                          selectedTileColor: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: .1),
                          onTap: () => Navigator.pop(context, site),
                        ),
                    ],
                  ),
                ],
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('猫源配置中心'),
                  onTap: () => Navigator.pop(context, 'subscriptions'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    try {
      if (selected is CatSite) await selectSite(selected);
      if (selected is CatSubscription) {
        await service.activate(selected);
        if (mounted) await sitePicker();
      }
      if (selected == 'subscriptions') await subscriptions();
      if (!mounted) return;
    } catch (failure) {
      toast('$failure');
    }
  }

  Future<void> search() async {
    final input = TextEditingController(text: query);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('搜索 · ${source?.name ?? '当前站点'}'),
        content: TextField(
          controller: input,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('清空'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    input.dispose();
    if (value != null && mounted) {
      setState(() => query = value);
      await refresh();
    }
  }

  Map<String, dynamic> record(SourceItem item) => {
    'id': item.id,
    'title': item.title,
    'cover': item.cover,
    'headers': item.coverHeaders,
    'subtitle': item.subtitle,
  };
  Future<void> openItem(SourceItem item, {CatSite? site}) async {
    final current = source;
    if (site == null && current != null && current.isFolder(item.id)) {
      setState(() {
        category = current.rawItemId(item.id);
        filters = {};
        query = '';
      });
      await refresh();
      return;
    }
    final selected = site ?? source?.site;
    final lib = library;
    if (selected == null || lib == null) return;
    try {
      await service.remember(selected, record(item));
      if (!mounted) return;
      final manager = CatSourceManager(service, selected);
      final target = ReadingTarget(
        sourceId: selected.id,
        itemId: item.id,
        title: item.title,
        cover: item.cover,
        subtitle: item.subtitle,
      );
      final Widget detail = selected.kind == 'comic'
          ? ComicDetailPage(
              library: lib,
              manager: manager,
              target: target,
              runtimeAvailable: true,
            )
          : selected.kind == 'novel'
          ? NovelDetailPage(library: lib, manager: manager, target: target)
          : CatDetailPage(
              source: CatDataSource(service, selected),
              item: item,
              library: lib,
            );
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => detail),
      );
    } catch (failure) {
      toast('$failure');
    }
  }

  Future<void> collection(bool favorites) async {
    final records = favorites ? service.favoriteItems : service.history;
    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: records.isEmpty
              ? Center(child: Text(favorites ? '暂无收藏' : '暂无历史'))
              : ListView(
                  children: [
                    ListTile(title: Text(favorites ? '猫源收藏' : '猫源历史')),
                    for (final entry in records)
                      ListTile(
                        title: Text(catText(entry['title'])),
                        onTap: () => Navigator.pop(context, entry),
                      ),
                  ],
                ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    final site = service.subscriptions
        .expand((s) => s.sites)
        .where((site) => site.id == chosen['site'])
        .firstOrNull;
    if (site == null) {
      toast('这个站点的订阅已被移除');
      return;
    }
    await openItem(
      SourceItem(
        id: catText(chosen['id']),
        title: catText(chosen['title']),
        cover: chosen['cover'] as String?,
        coverHeaders: catMap(chosen['headers'])
            .map((key, value) => MapEntry(key, catText(value))),
      ),
      site: site,
    );
  }

  Widget row(List<Widget> chips) => SizedBox(
    height: 34,
    child: ListView(scrollDirection: Axis.horizontal, children: chips),
  );
  Widget chip(String text, bool selected, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        backgroundColor: selected
            ? LumeTheme.accent.withValues(alpha: .12)
            : Colors.transparent,
        foregroundColor: selected ? LumeTheme.accent : LumeTheme.textPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: const Size(0, 30),
      ),
      child: Text(text),
    ),
  );
  Widget header() => GlassPanel(
    module: FloatingModule.home,
    radius: 28,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 36,
          child: IconButtonTheme(
            data: IconButtonThemeData(
              style: IconButton.styleFrom(
                minimumSize: const Size(40, 40),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 8),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: service.busy ? null : sitePicker,
                          borderRadius: BorderRadius.circular(12),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '猫源',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Icon(Icons.expand_more, size: 16),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        HomeBrowseNavigation(
                          selected: browseMode,
                          onSelect: selectBrowseMode,
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '历史',
                  onPressed: () => collection(false),
                  icon: const Icon(Icons.history),
                ),
                IconButton(
                  tooltip: '收藏',
                  onPressed: () => collection(true),
                  icon: const Icon(Icons.bookmark_outline),
                ),
                Tooltip(
                  message: '订阅',
                  child: IconButton(
                    onPressed: subscriptions,
                    icon: const Icon(Icons.rss_feed),
                  ),
                ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: service.busy ? null : sitePicker,
                child: Tooltip(
                  message: '切换站点（记住上次选择）',
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          source?.name ??
                              (service.needsSiteSelection
                                  ? '选择站点'
                                  : CatPreloader.selectedSite(service)?.name ??
                                        '选择站点'),
                          textAlign: TextAlign.left,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.expand_more),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '搜索',
              onPressed: source == null ? null : search,
              icon: const Icon(Icons.search),
            ),
          ],
        ),
        if (categories.isNotEmpty)
          BrowseChoiceAccess(
            choices: categories,
            selectedId: category,
            onSelected: (id) {
              setState(() {
                browseMode = null;
                category = id;
                filters = {};
                query = '';
              });
              unawaited(refresh());
            },
            child: row([
              chip('全部', category == null, () {
                setState(() {
                  browseMode = null;
                  category = null;
                  filters = {};
                  query = '';
                });
                unawaited(refresh());
              }),
              for (final entry in categories)
                chip(entry.title, category == entry.id, () {
                  setState(() {
                    browseMode = null;
                    category = entry.id;
                    filters = {};
                    query = '';
                  });
                  unawaited(refresh());
                }),
            ]),
          ),
        for (final group in groups)
          row([
            if (!group.options.any((option) => option.title == '全部'))
              chip('全部', !filters.containsKey(group.id), () {
                setState(() {
                  browseMode = null;
                  filters.remove(group.id);
                });
                unawaited(refresh());
              }),
            for (final option in group.options)
              chip(
                option.title,
                (filters[group.id] ??
                        (group.options
                            .where((o) => o.title == '全部')
                            .firstOrNull
                            ?.id)) ==
                    option.id,
                () {
                  setState(() {
                    browseMode = null;
                    filters[group.id] = option.id;
                  });
                  unawaited(refresh());
                },
              ),
          ]),
        if (query.isNotEmpty) Text('搜索：$query'),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: LumeTheme.base,
    body: SafeArea(
      top: false,
      bottom: false,
      child: RefreshIndicator(
        onRefresh: refresh,
        child: CustomScrollView(
          controller: scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                16,
                trimmedTopInset(MediaQuery.paddingOf(context).top),
                16,
                12,
              ),
              sliver: SliverToBoxAdapter(child: header()),
            ),
            if (service.busy)
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    const LinearProgressIndicator(),
                    Text(service.status),
                  ],
                ),
              ),
            if (loading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (error != null)
              SliverToBoxAdapter(
                child: GlassCard(
                  child: Column(
                    children: [
                      Text(error!),
                      TextButton(
                        onPressed: source == null ? boot : refresh,
                        child: const Text('重试'),
                      ),
                      TextButton(
                        onPressed: subscriptions,
                        child: const Text('管理订阅'),
                      ),
                    ],
                  ),
                ),
              )
            else if (source == null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    children: [
                      const Text('添加猫源订阅后，选择包内站点即可浏览。'),
                      FilledButton.icon(
                        onPressed: subscriptions,
                        icon: const Icon(Icons.rss_feed),
                        label: const Text('添加订阅'),
                      ),
                    ],
                  ),
                ),
              )
            else if (items.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: Text('暂无内容，请选择分类或其他站点')),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: .62,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final item = items[index];
                    return PosterCard(
                      footnoteBelow: true,
                      onTap: () => openItem(item),
                      footnote: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: LumeTheme.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: pipeline == null
                          ? const SizedBox()
                          : SectionImage(
                              pipeline: pipeline!,
                              url: item.cover ?? '',
                              headers: item.coverHeaders,
                              targetWidth: 300,
                              fit: BoxFit.cover,
                            ),
                    );
                  }, childCount: items.length),
                ),
              ),
            if (loadingMore)
              const SliverToBoxAdapter(
                child: Center(child: CircularProgressIndicator()),
              ),
            SliverToBoxAdapter(
              child: SizedBox(height: ShellDockScope.bottomInset(context) + 24),
            ),
          ],
        ),
      ),
    ),
  );
}
