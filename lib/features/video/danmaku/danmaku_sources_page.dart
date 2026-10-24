import '../../../shared/widgets/native_glass_surfaces.dart';
import 'builtin_danmaku_service.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'dandanplay_client.dart';
import 'danmaku_connection_test.dart';

export 'danmaku_credentials.dart' show DanmakuSourcesStore;

class DanmakuSourcesPage extends StatefulWidget {
  const DanmakuSourcesPage({super.key});
  @override
  State<DanmakuSourcesPage> createState() => _DanmakuSourcesPageState();
}

class _DanmakuSourcesPageState extends State<DanmakuSourcesPage> {
  List<Map<String, String>> _sources = [];
  String _active = '';
  String? _error;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    BuiltinDanmakuService.registerLicense();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await DanmakuSourcesStore.read();
      _sources = DanmakuSourcesStore.profiles(data);
      _active = data['activeId'] ?? '';
      // Preserve an already configured legacy endpoint as an editable profile.
      if (!data.containsKey('profilesJson') &&
          _sources.isEmpty &&
          (data['baseUrl'] ?? '').isNotEmpty) {
        _active = data['baseUrl'] == DandanplayCredentials.builtinBase
            ? 'builtin-local'
            : 'legacy';
        _sources = [
          {
            'id': _active,
            'name': '现有弹幕服务',
            'type': data['baseUrl'] == DandanplayCredentials.builtinBase
                ? 'builtin'
                : DandanplayCredentials.isOfficial(
                    Uri.tryParse(data['baseUrl']!),
                  )
                ? 'official'
                : 'logvar',
            'url': data['baseUrl']!,
            'appId': data['appId'] ?? '',
            'appSecret': data['appSecret'] ?? '',
          },
        ];
      }
    } catch (_) {
      _error = '弹幕源存储暂不可用，请在移动端重新打开。';
    }
    _sources = [
      {
        'id': 'builtin-local',
        'type': 'builtin',
        'name': '内置本机服务',
        'url': DandanplayCredentials.builtinBase,
      },
      ..._sources.where((s) => s['type'] != 'builtin'),
    ];
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _persist() async {
    try {
      await DanmakuSourcesStore.save(_sources, _active);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('保存失败，未能写入本机安全存储')));
      }
      rethrow;
    }
  }

  Future<void> _showBuiltin() => showGlassModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '内置本机服务',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            '无需填写地址。选择此服务后，手机直接联网查询各平台弹幕。首次启动可能稍慢，空闲两分钟自动停止，下次查询自动启动。连接成功不代表当前剧集一定有弹幕。',
          ),
          DanmakuConnectionTest(
            credentials: () => const DandanplayCredentials(
              '',
              '',
              baseUrl: DandanplayCredentials.builtinBase,
            ),
          ),
          TextButton(
            onPressed: () async {
              await BuiltinDanmakuService.instance.stop();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('停止本机服务'),
          ),
          TextButton(
            onPressed: () => showLicensePage(context: context),
            child: const Text('开源许可与组件说明'),
          ),
          const Text(
            '基于 YYDS678/danmu_api（AGPL-3.0），源码与手机适配补丁见 LumeBox 仓库 assets/local_danmaku。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
  );

  Future<void> _chooseType() async {
    final type = await showGlassModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                '添加弹幕源',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final choice in const {
              'logvar': '自定义 danmu 服务（兼容弹弹play）',
              'official': '弹弹play 开放平台',
              'plugin': '本机弹幕插件（JS）',
            }.entries)
              ListTile(
                title: Text(choice.value),
                onTap: () => Navigator.pop(context, choice.key),
              ),
          ],
        ),
      ),
    );
    if (!mounted || type == null) return;
    if (type == 'plugin') {
      await showGlassModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        builder: (context) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            Platform.isIOS
                ? '本机弹幕插件目前仅支持安卓。iPhone 可以使用兼容弹幕服务器与开放平台。'
                : '本机弹幕文件可以在播放页导入。第三方 JS 插件需要匹配其接口格式，不能把任意脚本当成弹幕源运行。',
          ),
        ),
      );
      return;
    }
    await _edit(type: type);
  }

  Future<void> _edit({String? type, Map<String, String>? existing}) async {
    final kind = type ?? existing?['type'] ?? 'logvar';
    final name = TextEditingController(text: existing?['name'] ?? '');
    final url = TextEditingController(
      text:
          existing?['url'] ??
          (kind == 'official' ? DandanplayCredentials.officialBase : ''),
    );
    final id = TextEditingController(text: existing?['appId'] ?? '');
    final secret = TextEditingController(text: existing?['appSecret'] ?? '');
    String? error;
    bool saving = false;
    ModalBottomSheetRoute<Map<String, String>>? route;
    try {
      route = ModalBottomSheetRoute<Map<String, String>>(
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        barrierLabel: MaterialLocalizations.of(context)
            .modalBarrierDismissLabel,
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: Navigator.of(context).context,
        ),
        builder: (context) => StatefulBuilder(
          builder: (context, refresh) => Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          kind == 'official' ? '弹弹play 开放平台' : '添加弹幕服务器',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const LumeIcon(
                          CupertinoIcons.xmark_circle_fill,
                          slot: 'danmaku_sources_page.1',
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '名称（可不填）'),
                  ),
                  if (kind != 'official')
                    TextField(
                      controller: url,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: '服务地址（保留路径前缀）',
                      ),
                      autocorrect: false,
                    ),
                  if (kind == 'official') ...[
                    TextField(
                      controller: id,
                      decoration: const InputDecoration(labelText: 'AppId'),
                      autocorrect: false,
                    ),
                    TextField(
                      controller: secret,
                      decoration: const InputDecoration(labelText: 'AppSecret'),
                      obscureText: true,
                      autocorrect: false,
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      kind == 'official'
                          ? '开放平台需要申请并审核通过的 AppId / AppSecret。凭据仅保存在本机安全存储中。'
                          : '使用兼容弹弹play /api/v2 接口的服务。若访问 token 位于地址路径中，请完整保留。',
                    ),
                  ),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  DanmakuConnectionTest(
                    credentials: () => DandanplayCredentials(
                      id.text.trim(),
                      secret.text.trim(),
                      baseUrl: url.text.trim(),
                    ),
                  ),
                  FilledButton(
                    onPressed: saving
                        ? null
                        : () async {
                            final uri = Uri.tryParse(url.text.trim());
                            if (uri == null ||
                                !['http', 'https'].contains(uri.scheme) ||
                                uri.host.isEmpty ||
                                uri.hasQuery ||
                                uri.hasFragment ||
                                uri.userInfo.isNotEmpty) {
                              refresh(
                                () => error = '请输入有效服务地址，保留路径，不附查询参数或用户名密码',
                              );
                              return;
                            }
                            if (kind == 'official' &&
                                (id.text.trim().isEmpty ||
                                    secret.text.trim().isEmpty)) {
                              refresh(() => error = '请填写 AppId 与 AppSecret');
                              return;
                            }
                            refresh(() => saving = true);
                            Navigator.pop(context, {
                              'id':
                                  existing?['id'] ??
                                  'source-${DateTime.now().microsecondsSinceEpoch}',
                              'type': kind,
                              'name': name.text.trim().isEmpty
                                  ? (kind == 'official'
                                        ? '弹弹play 开放平台'
                                        : uri.host)
                                  : name.text.trim(),
                              'url': url.text.trim().replaceFirst(
                                RegExp(r'/+$'),
                                '',
                              ),
                              'appId': id.text.trim(),
                              'appSecret': secret.text.trim(),
                            });
                          },
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final result = await Navigator.of(context).push(route);
      if (result == null || !mounted) return;
      final previous = List<Map<String, String>>.of(_sources);
      final previousActive = _active;
      setState(() {
        _sources = [
          for (final s in _sources)
            if (s['id'] != result['id']) s,
          result,
        ];
        _active = result['id']!;
      });
      try {
        await _persist();
      } catch (_) {
        if (mounted) {
          setState(() {
            _sources = previous;
            _active = previousActive;
          });
        }
      }
    } finally {
      // Navigator's pop result arrives before the sheet's exit animation ends.
      // Its TextFields still use these controllers until the overlay is removed.
      await route?.completed;
      name.dispose();
      url.dispose();
      id.dispose();
      secret.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF171719)
        : const Color(0xFFF0F2ED),
    appBar: AppBar(
      title: const Text('弹幕源'),
      backgroundColor: Colors.transparent,
      actions: [
        IconButton(
          tooltip: '添加弹幕源',
          onPressed: _chooseType,
          icon: const LumeIcon(
            CupertinoIcons.add,
            slot: 'danmaku_sources_page.2',
          ),
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(child: Text(_error!))
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final source in _sources)
                Card(
                  child: ListTile(
                    title: Text(source['name'] ?? ''),
                    subtitle: Text(
                      source['type'] == 'builtin'
                          ? '无需服务器地址 · 手机联网获取弹幕'
                          : source['type'] == 'official'
                          ? '弹弹play 开放平台'
                          : 'LogVar / 弹弹play兼容服务',
                    ),
                    leading: IconButton(
                      tooltip: source['type'] == 'builtin'
                          ? '使用内置本机服务'
                          : '设为当前弹幕源',
                      icon: LumeIcon(
                        _active == source['id']
                            ? CupertinoIcons.check_mark_circled_solid
                            : CupertinoIcons.circle,
                        slot: 'danmaku_sources_page.4',
                        variant: true,
                      ),
                      onPressed: () async {
                        final old = _active;
                        setState(() => _active = source['id']!);
                        try {
                          await _persist();
                        } catch (_) {
                          if (mounted) setState(() => _active = old);
                        }
                      },
                    ),
                    onTap: source['type'] == 'builtin'
                        ? _showBuiltin
                        : () => _edit(existing: source),
                    trailing: source['type'] == 'builtin'
                        ? IconButton(
                            tooltip: '测试内置服务',
                            onPressed: _showBuiltin,
                            icon: const Icon(Icons.settings_outlined),
                          )
                        : IconButton(
                            tooltip: '删除弹幕源',
                            icon: const LumeIcon(
                              CupertinoIcons.trash,
                              slot: 'danmaku_sources_page.5',
                            ),
                            onPressed: () async {
                              final old = List<Map<String, String>>.of(
                                _sources,
                              );
                              final oldActive = _active;
                              setState(() {
                                _sources.remove(source);
                                if (_active == source['id']) {
                                  _active = _sources.firstOrNull?['id'] ?? '';
                                }
                              });
                              try {
                                await _persist();
                              } catch (_) {
                                if (mounted) {
                                  setState(() {
                                    _sources = old;
                                    _active = oldActive;
                                  });
                                }
                              }
                            },
                          ),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('勾选的服务供两种播放器使用。保存后自动重新加载当前视频的弹幕。'),
              ),
            ],
          ),
  );
}
