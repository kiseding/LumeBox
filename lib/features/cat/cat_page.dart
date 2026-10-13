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
import '../comic/comic_detail_page.dart';
import '../novel/novel_detail_page.dart';
import '../shell/shell_dock.dart';
import 'cat_subscription_page.dart';
import 'cat_detail_page.dart';
import 'cat_web_page.dart';

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
                'config|setting|website|配置|我的网盘|日历|日期|^\\d{4}-\\d{2}-\\d{2}',
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
      query = '';
    });
    await service.select(site);
    await refresh();
  }

  Future<void> refresh() async {
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

  Future<void> sitePicker() async {
    final selected = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: ListView(
            children: [
              const ListTile(title: Text('选择站点')),
              for (final record in service.subscriptions.where(
                (s) => s.enabled,
              )) ...[
                ListTile(
                  title: Text(record.name),
                  subtitle: const Text('加载或刷新包内站点'),
                  trailing: const Icon(Icons.refresh),
                  onTap: () => Navigator.pop(context, record),
                ),
                for (final site in record.sites)
                  ListTile(
                    dense: true,
                    title: Text(site.name),
                    subtitle: Text(
                      {
                            'video': '视频',
                            'comic': '漫画',
                            'novel': '小说',
                            'live': '直播',
                          }[site.kind] ??
                          site.kind,
                    ),
                    selected: site.id == source?.site.id,
                    onTap: () => Navigator.pop(context, site),
                  ),
              ],
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('当前订阅的配置与网盘账号'),
                onTap: () => Navigator.pop(context, 'config'),
              ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('管理订阅'),
                onTap: () => Navigator.pop(context, 'subscriptions'),
              ),
            ],
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
      if (selected == 'config') {
        await openConfiguration();
      }
    } catch (failure) {
      toast('$failure');
    }
  }

  Future<void> openConfiguration() async {
    final site = source?.site;
    if (site == null) {
      await subscriptions();
      return;
    }
    try {
      final record = service.subscriptions.firstWhere(
        (s) => s.id == site.subscriptionId,
      );
      final url = await service.configurationUrl(record);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => CatWebPage(url: url)),
      );
      await service.refreshSites(record);
      if (mounted) await refresh();
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
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '猫源',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
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
            IconButton(
              tooltip: '订阅',
              onPressed: subscriptions,
              icon: const Icon(Icons.rss_feed),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: service.busy ? null : sitePicker,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        source?.name ?? '选择站点',
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
            IconButton(
              tooltip: '搜索',
              onPressed: source == null ? null : search,
              icon: const Icon(Icons.search),
            ),
            IconButton(
              tooltip: '网盘登录 / 配置中心',
              onPressed: service.busy ? null : openConfiguration,
              icon: const Icon(Icons.cloud_outlined),
            ),
          ],
        ),
        if (categories.isNotEmpty)
          row([
            chip('全部', category == null, () {
              setState(() {
                category = null;
                filters = {};
                query = '';
              });
              unawaited(refresh());
            }),
            for (final entry in categories)
              chip(entry.title, category == entry.id, () {
                setState(() {
                  category = entry.id;
                  filters = {};
                  query = '';
                });
                unawaited(refresh());
              }),
          ]),
        for (final group in groups)
          row([
            if (!group.options.any((option) => option.title == '全部'))
              chip('全部', !filters.containsKey(group.id), () {
                setState(() => filters.remove(group.id));
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
                  setState(() => filters[group.id] = option.id);
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
      bottom: false,
      child: RefreshIndicator(
        onRefresh: refresh,
        child: CustomScrollView(
          controller: scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
