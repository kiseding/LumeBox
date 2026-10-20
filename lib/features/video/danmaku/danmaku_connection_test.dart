import 'package:flutter/material.dart';

import 'dandanplay_client.dart';

class DanmakuConnectionTest extends StatefulWidget {
  const DanmakuConnectionTest({super.key, required this.credentials});
  final DandanplayCredentials Function() credentials;

  @override
  State<DanmakuConnectionTest> createState() => _DanmakuConnectionTestState();
}

class _DanmakuConnectionTestState extends State<DanmakuConnectionTest> {
  bool _testing = false;
  String? _result;
  bool _failed = false;
  DandanplayClient? _client;

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  Future<void> _test() async {
    final credentials = widget.credentials();
    final client = DandanplayClient(credentials: credentials);
    _client = client;
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      await client.checkConnection();
      if (!mounted) return;
      setState(() {
        _failed = false;
        _result = credentials.official
            ? '连接成功，应用凭证已通过验证。播放时还需匹配作品和集数。'
            : '连接成功，可以搜索弹幕。播放时还需匹配作品和集数。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _result = DandanplayClient.describeError(error);
      });
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      OutlinedButton(
        onPressed: _testing ? null : _test,
        child: Text(_testing ? '测试中…' : '测试连接'),
      ),
      if (_result != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            _result!,
            style: TextStyle(
              color: _failed ? Theme.of(context).colorScheme.error : null,
            ),
          ),
        ),
    ],
  );
}
