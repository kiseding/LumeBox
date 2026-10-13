import 'package:flutter/material.dart';

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
              const SizedBox(height: 12),
              TextField(
                controller: username,
                decoration: const InputDecoration(labelText: '用户名（需要认证时填写）'),
              ),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可选）'),
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
        await service.add(savedName, savedUrl);
      });
    }
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '猫源订阅',
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
          const Text('订阅包内的站点在首页选择。开启自动更新后，每次打开会检查到期订阅；下载或校验失败时保留旧包。'),
          if (working || service.busy) ...[
            const LinearProgressIndicator(),
            Text(service.status),
          ],
          if (error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
          for (final record in service.subscriptions)
            GlassCard(
              child: Column(
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(record.name),
                    subtitle: Text(
                      '${record.sites.length} 个站点 · ${record.checked == 0 ? '未更新' : DateTime.fromMillisecondsSinceEpoch(record.checked).toString().substring(0, 16)}\n${record.url}',
                    ),
                    trailing: Switch(
                      value: record.enabled,
                      onChanged: working
                          ? null
                          : (enabled) => run(() async {
                              record.enabled = enabled;
                              await service.save();
                            }),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动拉取更新'),
                    value: record.automatic,
                    onChanged: working
                        ? null
                        : (automatic) => run(() async {
                            record.automatic = automatic;
                            await service.save();
                          }),
                  ),
                  if (record.error.isNotEmpty) Text(record.error),
                  Wrap(
                    children: [
                      TextButton.icon(
                        onPressed: working
                            ? null
                            : () => run(() => service.update(record)),
                        icon: const Icon(Icons.refresh),
                        label: const Text('立即更新'),
                      ),
                      TextButton.icon(
                        onPressed: working
                            ? null
                            : () => run(() async {
                                final url = await service.configurationUrl(
                                  record,
                                );
                                if (!context.mounted) return;
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => CatWebPage(url: url),
                                  ),
                                );
                                await service.refreshSites(record);
                              }),
                        icon: const Icon(Icons.cloud_outlined),
                        label: const Text('网盘登录 / 配置'),
                      ),
                      TextButton(
                        onPressed: working
                            ? null
                            : () => run(() => service.remove(record)),
                        child: const Text('移除订阅'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          const Text('常用订阅'),
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
    ),
  );
}
