import 'package:lume_box/core/theme/lume_typography.dart';
import 'package:flutter/material.dart';

import 'dandanplay_client.dart';
import 'danmaku_connection_test.dart';
import 'danmaku_presets.dart';

/// Accepts a full service prefix, including deployment tokens in its path.
class DanmakuServiceSheet extends StatefulWidget {
  const DanmakuServiceSheet({super.key, required this.initial});
  final DandanplayCredentials initial;
  @override
  State<DanmakuServiceSheet> createState() => _DanmakuServiceSheetState();
}

class _DanmakuServiceSheetState extends State<DanmakuServiceSheet> {
  late final _url = TextEditingController(text: widget.initial.baseUrl);
  late final _id = TextEditingController(text: widget.initial.appId);
  late final _secret = TextEditingController(text: widget.initial.appSecret);
  final _urlFocus = FocusNode();
  final _drafts = <String, DandanplayCredentials>{};
  String? _error;
  bool _saving = false;
  bool _switching = false;

  Future<void> _selectService(String? value) async {
    if (value == null) return;
    _drafts[_url.text.trim()] = DandanplayCredentials(
      _id.text,
      _secret.text,
      baseUrl: _url.text.trim(),
    );
    FocusScope.of(context).unfocus();
    setState(() {
      _switching = true;
      _error = null;
    });
    try {
      final data = await DanmakuSourcesStore.read();
      if (!mounted) return;
      final base = value == 'custom' ? '' : value;
      final saved = DanmakuSourcesStore.profiles(data)
          .where((source) => source['url'] == base)
          .firstOrNull;
      final config =
          _drafts[base] ??
          DandanplayCredentials(
            saved?['appId'] ??
                (data['baseUrl'] == base ? data['appId'] : null) ??
                '',
            saved?['appSecret'] ??
                (data['baseUrl'] == base ? data['appSecret'] : null) ??
                '',
            baseUrl: base,
          );
      setState(() {
        _url.text = base;
        _id.text = config.appId;
        _secret.text = config.appSecret;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = DandanplayClient.describeError(error));
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  void dispose() {
    _urlFocus.dispose();
    _url.dispose();
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final uri = Uri.tryParse(_url.text.trim());
    if (_url.text != DandanplayCredentials.builtinBase &&
        (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment)) {
      setState(() => _error = '请填写完整服务地址，保留路径前缀，不附查询参数或用户名密码');
      return;
    }
    final config = DandanplayCredentials(
      _id.text.trim(),
      _secret.text.trim(),
      baseUrl: _url.text.trim().replaceFirst(RegExp(r'/+$'), ''),
    );
    if (config.official && !config.configured) {
      setState(() => _error = '官方服务需要已审核的 AppId / AppSecret；兼容服务无需填写');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await config.save();
      if (mounted) Navigator.pop(context, config);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = DandanplayClient.describeError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    // The panel route owns keyboard and safe-area avoidance.
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '弹幕服务',
            style: TextStyle(
              fontSize: LumeTypography.pageTitleSize,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          const Text('源弹幕与公共服务弹幕同时加载。服务地址可使用兼容弹弹play的 danmu_api 部署，路径前缀会保留。'),
          const SizedBox(height: 12),
          if (_url.text == DandanplayCredentials.builtinBase)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('内置本机服务：无需填写地址，手机联网获取弹幕'),
            )
          else
            TextField(
              controller: _url,
              focusNode: _urlFocus,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '服务地址',
                hintText: 'https://你的域名/路径前缀',
              ),
              autocorrect: false,
            ),
          DropdownButtonFormField<String>(
            key: ValueKey(_url.text),
            initialValue: DanmakuPresets.urls.contains(_url.text)
                ? _url.text
                : _url.text == DandanplayCredentials.builtinBase
                ? _url.text
                : _url.text == DandanplayCredentials.officialBase
                ? _url.text
                : 'custom',
            isExpanded: true,
            decoration: const InputDecoration(labelText: '切换弹幕服务'),
            items: [
              const DropdownMenuItem(
                value: DandanplayCredentials.builtinBase,
                child: Text('内置本机服务（无需地址）'),
              ),
              for (var i = 0; i < DanmakuPresets.urls.length; i++)
                DropdownMenuItem(
                  value: DanmakuPresets.urls[i],
                  child: Text(
                    '弹${i + 1} · ${Uri.parse(DanmakuPresets.urls[i]).host}',
                  ),
                ),
              const DropdownMenuItem(
                value: DandanplayCredentials.officialBase,
                child: Text('弹弹play 官方（需应用凭据）'),
              ),
              const DropdownMenuItem(
                value: 'custom',
                child: Text('自定义 danmu 地址'),
              ),
            ],
            onChanged: _saving || _switching ? null : _selectService,
          ),
          const SizedBox(height: 12),
          if (DandanplayCredentials.isOfficial(
            Uri.tryParse(_url.text.trim()),
          )) ...[
            TextField(
              controller: _id,
              decoration: const InputDecoration(labelText: 'AppId'),
            ),
            TextField(
              controller: _secret,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'AppSecret'),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '自动复用播放器设置中已保存的应用凭证。AppId / AppSecret 是开放平台应用凭证，不是账号 UID。',
              ),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _error!,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Colors.red,
                ),
              ),
            ),
          DanmakuConnectionTest(
            credentials: () => DandanplayCredentials(
              _id.text.trim(),
              _secret.text.trim(),
              baseUrl: _url.text.trim(),
            ),
          ),
          FilledButton(
            onPressed: _saving || _switching ? null : _save,
            child: Text(_saving ? '保存中…' : '保存并重新加载弹幕'),
          ),
        ],
      ),
    ),
  );
}
