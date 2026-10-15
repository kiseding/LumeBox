import 'package:flutter/material.dart';

import '../../core/net/network_settings.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';

class SourceTestResultDialog extends StatelessWidget {
  const SourceTestResultDialog({
    super.key,
    required this.sourceName,
    required this.result,
  });

  /// 图源显示名（只用于展示，不认识图源内部状态）。
  final String sourceName;

  /// 引擎给出的测试结论（三态 + 说明 + 耗时）。
  final SourceTestResult result;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('连通性测试'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _InfoRow(label: '源', value: sourceName),
          _InfoRow(
            label: '状态',
            value: result.status.label,
            valueColor: result.status == SourceTestStatus.ok
                ? LumeTheme.success
                : LumeTheme.danger,
          ),
          _InfoRow(label: '耗时', value: _elapsedText(result.elapsed)),
          _InfoRow(label: '日志', value: _logText(result)),
        ],
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  /// 耗时文本：毫秒 → 「0.8s」；失败可能拿不到耗时，如实给「—」不编造。
  static String _elapsedText(Duration? elapsed) {
    if (elapsed == null) return '—';
    return '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }

  /// 简短日志：引擎给的说明优先（空结果 / 失败原因）；成功时给一句摘要。
  static String _logText(SourceTestResult result) {
    final message = result.message.trim();
    if (message.isNotEmpty) return message;
    final items = result.itemCount ?? 0;
    final categories = result.categoryCount ?? 0;
    return '首屏返回 $items 条${categories > 0 ? ' · $categories 个分类' : ''}';
  }
}

/// 弹窗里的一行「标签 + 值」：标签定宽，值自动换行。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;

  /// 值的颜色（默认白色；状态行用它表达三态）。
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: LumeTheme.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: valueColor ?? LumeTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SourceNetworkDialog extends StatefulWidget {
  const SourceNetworkDialog({super.key, required this.source});

  final SourceDescriptor source;

  @override
  State<SourceNetworkDialog> createState() => _SourceNetworkDialogState();
}

class _SourceNetworkDialogState extends State<SourceNetworkDialog> {
  late final TextEditingController _ua = TextEditingController(
    text: widget.source.network.userAgent,
  );
  late final TextEditingController _cookie = TextEditingController(
    text: widget.source.network.cookie,
  );
  late final TextEditingController _proxy = TextEditingController(
    text: widget.source.network.proxy,
  );
  late final TextEditingController _bridge = TextEditingController(
    text: widget.source.network.bridge,
  );

  /// 「忽略证书错误」：按源开放，默认关闭（值从该源当前配置读，不会自己变开）。
  late bool _allowBadCertificate = widget.source.network.allowBadCertificate;

  @override
  void dispose() {
    _ua.dispose();
    _cookie.dispose();
    _proxy.dispose();
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('网络配置 · ${widget.source.name}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '留空即继承「设置 → 网络设置」里的全局值。这里的配置只作用于本源，'
                'Cookie 不与其他源共享。',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _ua,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'User-Agent',
                  hintText: '留空 = 用全局 UA',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _cookie,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Cookie',
                  hintText: '留空 = 不带 Cookie',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _proxy,
                decoration: const InputDecoration(
                  labelText: '代理',
                  hintText: 'http://127.0.0.1:7890；留空 = 用全局代理',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              // 「桥接服务地址」（用户口径 2.2）：个别站点（OKooK-CDN +
              // reCAPTCHA v3 那类）的放行绑浏览器会话与 IP 信誉，导不出可复用
              // Cookie、普通代理也没用——只能把请求转给一个「已过验证的无头
              // 浏览器桥」（Playwright / Puppeteer）。脚本读 LumeSource.bridge。
              TextField(
                controller: _bridge,
                decoration: const InputDecoration(
                  labelText: '桥接服务地址',
                  hintText: 'http://192.168.1.5:8787；留空 = 不用桥接',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              // 「忽略证书错误」（用户口径）：站点证书过期时系统会直接拒连
              // （CERTIFICATE_VERIFY_FAILED），这是唯一出路。**按源开放、默认关**，
              // 并把风险写在旁边——不能让它看起来像个普通开关。
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _allowBadCertificate,
                onChanged: (value) =>
                    setState(() => _allowBadCertificate = value == true),
                title: const Text('忽略证书错误'),
                subtitle: const Text(
                  '站点证书过期 / 链不完整时才需要开。开启后该源的请求不再校验证书，'
                  '存在被中间人冒充的风险；证书修好后请立刻关闭。',
                ),
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(NetworkProfile.none),
          child: const Text('清除覆盖'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            NetworkProfile(
              userAgent: _ua.text,
              cookie: _cookie.text,
              proxy: _proxy.text,
              bridge: _bridge.text,
              allowBadCertificate: _allowBadCertificate,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
