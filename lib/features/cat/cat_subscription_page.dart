import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/cat/cat_service.dart';
import '../../shared/widgets/glass_card.dart';
import 'cat_web_page.dart';

const catSubscriptionPresets = <String, String>{
  '牛二': 'https://9280.kstore.vip/cat/index.js.md5',
  '豆儿': 'https://catpaw.douer.me/index.js.md5',
  'lmentor': 'https://ghfast.top/https://raw.githubusercontent.com/Darklessing/catvod/refs/heads/main/lmentor/index.js.md5',
  '神秘猫源': 'https://ghfast.top/https://raw.githubusercontent.com/Darklessing/catvod/refs/heads/main/smdl/index.js.md5',
  '兔佬猫源': 'https://raw.githubusercontent.com/xiaobaitulele/xptv/refs/heads/main/jstv/index.js.md5',
  'Y佬猫源': 'https://raw.githubusercontent.com/Yswag/xptv-extensions/refs/heads/jstv/index.js.md5',
  '泥潭源': 'https://ghfast.top/https://raw.githubusercontent.com/nitan-tv/nitan/refs/heads/main/js/index.js.md5',
  '18+': 'https://raw.githubusercontent.com/fangkuia/XPTV/refs/heads/main/dist/index.js.md5',
};

class CatSubscriptionPage extends StatefulWidget {
  const CatSubscriptionPage({super.key});
  @override
  State<CatSubscriptionPage> createState() => _CatSubscriptionPageState();
}

class _CatSubscriptionPageState extends State<CatSubscriptionPage> {
  final service = CatService.instance;
  String? error;
  bool working = false;
  Future<void> run(Future<void> Function() operation) async {
    if (working) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      await operation();
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> add({String name = '', String url = ''}) async {
    final label = TextEditingController(text: name);
    final address = TextEditingController(text: url);
    final username = TextEditingController();
    final password = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加猫源订阅'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: label,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: address,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'index.js.md5 订阅链接',
                ),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('订阅认证（可选）'),
                children: [
                  TextField(
                    controller: username,
                    decoration: const InputDecoration(labelText: '用户名'),
                  ),
                  TextField(
                    controller: password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '密码'),
                  ),
                ],
              ),
              const Text('保存后自动检查更新，无需再次粘贴链接。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存并导入'),
          ),
        ],
      ),
    );
    final savedName = label.text;
    var savedUrl = address.text.trim();
    if (username.text.isNotEmpty) {
      final parsed = Uri.tryParse(savedUrl);
      if (parsed != null) {
        savedUrl = parsed
            .replace(
              userInfo:
                  '${Uri.encodeComponent(username.text)}:${Uri.encodeComponent(password.text)}',
            )
            .toString();
      }
    }
    label.dispose();
    address.dispose();
    username.dispose();
    password.dispose();
    if (accepted == true && mounted) {
      await run(() async {
        final record = await service.add(savedName, savedUrl);
        if (record.enabled) await service.refreshSites(record);
      });
    }
  }

  Future<void> configure(CatSubscription record) => run(() async {
    if (!record.enabled) {
      record.enabled = true;
      await service.save();
    }
    if (record.hash.isEmpty) await service.update(record);
    final url = await service.configurationUrl(record);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => CatWebPage(url: url)),
    );
    await service.refreshSites(record);
  });

  Future<void> more(CatSubscription record, String action) => run(() async {
    if (action == 'update') {
      await service.update(record);
      if (record.enabled) await service.refreshSites(record);
    }
    if (action == 'auth') await add(name: record.name, url: record.url);
    if (action == 'automatic') {
      record.automatic = !record.automatic;
      await service.save();
    }
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: record.url));
    }
    if (action == 'remove') await service.remove(record);
    if (action == 'info' && mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(record.name),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('订阅地址'),
                SelectableText(record.url),
                const SizedBox(height: 12),
                Text(
                  record.error.isEmpty
                      ? '订阅正常，${record.automatic ? '自动更新已开启' : '自动更新已关闭'}'
                      : record.error,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      );
    }
  });

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '猫源配置中心',
    actions: [
      IconButton(
        tooltip: '添加订阅',
        icon: const Icon(Icons.add),
        onPressed: working ? null : () => add(),
      ),
    ],
    child: ListenableBuilder(
      listenable: service,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('订阅地址会保留并自动更新，网盘登录和站点设置在对应订阅内完成。'),
          if (working || service.busy) ...[
            const LinearProgressIndicator(),
            Text(service.status),
          ],
          if (error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
          for (final record in service.subscriptions)
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      record.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${record.hash.isEmpty
                          ? '未下载'
                          : record.sites.isEmpty
                          ? '站点尚未读取'
                          : '${record.sites.length} 个站点'} · ${record.enabled ? '已启用' : '已停用'}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: record.enabled,
                          onChanged: working || service.busy
                              ? null
                              : (value) => run(() async {
                                  record.enabled = value;
                                  await service.save();
                                  if (value) {
                                    if (record.hash.isEmpty) {
                                      await service.update(record);
                                    }
                                    await service.refreshSites(record);
                                  }
                                }),
                        ),
                        PopupMenuButton<String>(
                          tooltip: '更多',
                          enabled: !working && !service.busy,
                          onSelected: (action) => more(record, action),
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'update',
                              child: Text('立即更新'),
                            ),
                            CheckedPopupMenuItem(
                              value: 'automatic',
                              checked: record.automatic,
                              child: const Text('自动更新'),
                            ),
                            const PopupMenuItem(
                              value: 'auth',
                              child: Text('编辑地址 / 授权'),
                            ),
                            const PopupMenuItem(
                              value: 'info',
                              child: Text('订阅信息'),
                            ),
                            const PopupMenuItem(
                              value: 'copy',
                              child: Text('复制订阅链接'),
                            ),
                            const PopupMenuItem(
                              value: 'remove',
                              child: Text('移除订阅'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (record.error.isNotEmpty)
                    Text(
                      record.error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  TextButton.icon(
                    onPressed: working || service.busy
                        ? null
                        : () => configure(record),
                    icon: const Icon(Icons.cloud_outlined),
                    label: Text(record.enabled ? '网盘登录 · 站点配置' : '启用并打开配置'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          ExpansionTile(
            title: const Text('添加常用订阅'),
            initiallyExpanded: service.subscriptions.isEmpty,
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final preset in catSubscriptionPresets.entries)
                    ActionChip(
                      label: Text(preset.key),
                      onPressed: working
                          ? null
                          : () => add(name: preset.key, url: preset.value),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
